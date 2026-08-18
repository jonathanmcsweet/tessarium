(* The effectful side of the in-app basemap download.

   Every decision -- may a download start, is this box valid, what does
   progress look like -- is [Basemap_job]'s and is tested there; the merge
   arithmetic is [Pmtiles.Merge]'s, tested in the pmtiles suite. This module
   owns what cannot be pure: the fiber, the socket, the .part file, and the
   mutex around the one shared job cell.

   Downloads MERGE into the archive on disk rather than replacing it, so the
   world overview survives every city added on top of it, and a tile already
   held is never fetched again.

   The tile source and assets URL are the server's configuration, never the
   client's. A request body names a region of the world; it does not name a
   place on the internet to fetch from. *)

type t = {
  mutex : Eio.Mutex.t;
  mutable job : Basemap_job.t;
  (* Counts starts. In the status JSON so a poller can tell "this download
     finished" from "some earlier download had finished": a fast job can run
     idle-to-done entirely between two polls, and without an identity the
     second poll is indistinguishable from stale news. *)
  mutable generation : int;
  mutable cancel_requested : bool;
  (* One browse fetch at a time, separately from the job: browsing writes
     cache.pmtiles, never map.pmtiles, so it may run beside a download --
     but not beside itself. *)
  mutable browsing : bool;
}

(* What the request handler sees: closures, so the handler can be tested
   with pure fakes and never needs the switch, the network or the clock. *)
type ops = {
  estimate : Basemap_job.request list -> (Yojson.Safe.t, string) result;
  start :
    name:string option -> Basemap_job.request list -> (unit, string) result;
  cancel : unit -> bool;
  status : unit -> Yojson.Safe.t;
  ledger : unit -> (Yojson.Safe.t, string) result;
  update : id:string -> (unit, string) result;
  remove : id:string -> (unit, string) result;
  browse : Basemap_job.request -> (int, string) result;
}

let create () =
  {
    mutex = Eio.Mutex.create ();
    job = Basemap_job.Idle;
    generation = 0;
    cancel_requested = false;
    browsing = false;
  }

let set t job = Eio.Mutex.use_rw ~protect:true t.mutex (fun () -> t.job <- job)

let status t =
  let generation, job =
    Eio.Mutex.use_ro t.mutex (fun () -> (t.generation, t.job))
  in
  `Assoc
    [ ("generation", `Int generation); ("job", Basemap_job.to_json job) ]

(* Cancellation is a flag the download polls, not a fiber kill. Killing the
   fiber mid-write leaves a half-written .part with nothing responsible for
   it; polling means the download itself walks to its own exit. *)
exception Cancelled_by_user

let check_cancel t =
  if Eio.Mutex.use_ro t.mutex (fun () -> t.cancel_requested) then
    raise Cancelled_by_user

let cancel t =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      if Basemap_job.is_running t.job then begin
        t.cancel_requested <- true;
        true
      end
      else false)

let claim t =
  (* Claiming the job and checking it are one critical section; two requests
     arriving together must not both see a resting state. *)
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      if Basemap_job.can_start t.job then begin
        t.job <- Basemap_job.Planning;
        t.generation <- t.generation + 1;
        t.cancel_requested <- false;
        true
      end
      else false)

(* Exceptions out of Eio and cohttp arrive as their printed form; Failure
   carries the messages this codebase writes for humans. *)
let friendly = function Failure m -> m | e -> Printexc.to_string e

(* ------------------------------------------------------------------ plan *)

(* How much planning one request may cost. An explicit ask that plans within
   [full] tile ids gets its full depth in one piece -- whole-France street
   level is ~2.3 million ids and qualifies, as does every US state. A box
   beyond that is SPLIT into at most [max_parts] pieces that each fit --
   Brazil (~18M ids) becomes three or four, downloaded one at a time -- and
   only a box too big even for that (Canada's box, Russia's) falls back to a
   quick [quick]-id regional plan with the UI saying to pick a province.
   Splitting is also what makes giants resumable: each piece merges and
   renames atomically, so an interruption keeps every finished piece and a
   re-request skips them. *)
type budget = { full : int; quick : int; max_parts : int; compact : int }

let default_budget =
  {
    full = 6_000_000;
    quick = 131_072;
    max_parts = 8;
    (* When the browse cache outgrows this many bytes of tile data it is
       folded into the main archive: past ~48 MB the per-browse rewrite of
       the cache costs more than one fold of the big file amortises. *)
    compact = 48_000_000;
  }

(* Million-id loops must share the scheduler: yield every so often, and a
   download also polls its cancel flag, so even the planning phase of a
   country-sized job stops when asked. *)
let breathe ?cancel () =
  let n = ref 0 in
  fun () ->
    incr n;
    if !n land 4095 = 0 then begin
      Eio.Fiber.yield ();
      match cancel with Some t -> check_cancel t | None -> ()
    end

(* The resolved URL is part of the return: the ledger records which archive
   a region was actually fetched from, and "latest" is not an answer. *)
let open_source ~sw ~fs ~net ~source =
  let source = Pmtiles_source.resolve ~sw ~net source in
  let src = Pmtiles_source.open_url ~sw ~fs ~net source in
  let archive = Pmtiles.Archive.open_ src in
  (source, src, archive)

(* One box a download will actually plan and fetch, with the region it came
   from: a small region is one segment, a giant is several. *)
type segment = {
  req : Basemap_job.request;
  depth : int;
  box : float * float * float * float;
  clip : Pmtiles.Clip.t option;
      (** the region's polygon; planning stops at the border, not the box *)
}

(* The units of work, in fetch order, plus the granted depth per region in
   request order. Single-box regions ride together in one merge -- that is
   what lets overlapping picks dedup against each other -- and every giant
   part is its own unit, planned and written alone so memory stays at the
   single-part envelope however large the region. Seams between parts may
   share an edge row of tiles; the second part's merge sees them on disk
   and skips them, so an estimate double-counts at most a sliver. *)
let units_of ?cancel ~budget ~header reqs =
  let min_zoom = header.Pmtiles.Header.min_zoom in
  let split =
    List.map
      (fun (req : Basemap_job.request) ->
        let requested = min req.max_zoom header.Pmtiles.Header.max_zoom in
        let clip = Option.map Pmtiles.Clip.of_rings req.polygon in
        let parts, depth, _clamped =
          Pmtiles.Tile_id.download_parts ?clip
            ~on_count:(breathe ?cancel ())
            ~min_zoom ~requested
            ~min_lon:req.min_lon ~min_lat:req.min_lat ~max_lon:req.max_lon
            ~max_lat:req.max_lat ~full_limit:budget.full
            ~quick_limit:budget.quick ~max_parts:budget.max_parts ()
        in
        (req, depth, clip, parts))
      reqs
  in
  let singles, giants =
    List.partition (fun (_, _, _, parts) -> List.length parts = 1) split
  in
  let batch =
    match singles with
    | [] -> []
    | l ->
        [
          `Batch
            (List.map
               (fun ((req : Basemap_job.request), depth, clip, parts) ->
                 { req; depth; clip; box = List.hd parts })
               l);
        ]
  in
  let parts =
    List.concat_map
      (fun (req, depth, clip, boxes) ->
        List.map (fun box -> `Part { req; depth; clip; box }) boxes)
      giants
  in
  (batch @ parts, List.map (fun (_, depth, _, _) -> depth) split)

let plan_box ?cancel ~archive ~min_zoom (seg : segment) =
  let a, b, c, d = seg.box in
  Pmtiles.Extract.plan
    ~on_tile:(breathe ?cancel ())
    ?clip:seg.clip archive ~min_zoom ~max_zoom:seg.depth ~min_lon:a ~min_lat:b
    ~max_lon:c ~max_lat:d

let segments_of = function `Batch segs -> segs | `Part seg -> [ seg ]

(* The archive already on disk, if any -- the merge's base. *)
let open_archive ~sw ~fs ~basemap_dir name =
  let path = Eio.Path.(fs / basemap_dir / name) in
  match Eio.Path.kind ~follow:true path with
  | `Regular_file ->
      Some
        (Pmtiles.Archive.open_
           (Pmtiles_source.file_source (Eio.Path.open_in ~sw path)))
  | _ -> None

let open_base ~sw ~fs ~basemap_dir = open_archive ~sw ~fs ~basemap_dir "map.pmtiles"

(* The browse cache: anonymous tiles picked up while panning online. Its own
   file so a browse never rewrites the big archive; folded into it when it
   outgrows the budget's compaction threshold. *)
let open_cache ~sw ~fs ~basemap_dir =
  open_archive ~sw ~fs ~basemap_dir "cache.pmtiles"

(* The archive's ledger, read before anything rewrites the archive. An
   unreadable ledger stops the operation cold rather than being overwritten:
   silently forgetting what a gigabyte archive holds is the one failure this
   feature must never have. *)
let base_ledger = function
  | None -> ("{}", [])
  | Some b -> (
      let meta = Pmtiles.Archive.metadata b in
      match Ledger.of_metadata meta with
      | Ok l -> (meta, l)
      | Error m -> failwith m)

(* A scripted request without a name still gets a legible ledger row. *)
let default_name (reqs : Basemap_job.request list) =
  match reqs with
  | [] -> "?"
  | r :: _ ->
      Printf.sprintf "%.2f, %.2f - %.2f, %.2f" r.min_lon r.min_lat r.max_lon
        r.max_lat

let guard_compression ~h base =
  match base with
  | Some b
    when b.Pmtiles.Archive.header.Pmtiles.Header.tile_compression
         <> h.Pmtiles.Header.tile_compression ->
      failwith
        "the basemap on disk and the tile source disagree on compression; \
         delete the basemap directory and download again"
  | _ -> ()

(* The estimate is what the user will actually pay for over the network:
   tiles the base already holds are excluded, so re-asking for an area you
   have says zero rather than re-quoting the full price. [covered] separates
   "you have all of this" from "the source has nothing here". Units are
   planned one at a time and discarded, so a giant estimate costs the time
   of its planning but only one part's memory. *)
let estimate ~fs ~net ~source ~basemap_dir ~budget
    (reqs : Basemap_job.request list) =
  match
    Eio.Switch.run @@ fun sw ->
    let _resolved, _src, archive = open_source ~sw ~fs ~net ~source in
    let h = archive.Pmtiles.Archive.header in
    let base = open_base ~sw ~fs ~basemap_dir in
    guard_compression ~h base;
    let units, depths = units_of ~budget ~header:h reqs in
    let fetch = ref 0 and fresh = ref 0 and any_tiles = ref false in
    List.iter
      (fun unit ->
        let plans =
          List.map
            (plan_box ~archive ~min_zoom:h.Pmtiles.Header.min_zoom)
            (segments_of unit)
        in
        if
          List.exists
            (fun (f : Pmtiles.Extract.plan) ->
              Array.length f.Pmtiles.Extract.tiles > 0)
            plans
        then any_tiles := true;
        let mp = Pmtiles.Merge.plan ~on_entry:(breathe ()) ~base plans in
        fetch := !fetch + mp.Pmtiles.Merge.fetch_bytes;
        fresh := !fresh + mp.Pmtiles.Merge.fresh_tiles)
      units;
    (!fetch, !fresh, !any_tiles && !fresh = 0, depths)
  with
  | fetch_bytes, tiles, covered, depths ->
      Ok
        (`Assoc
           [
             ("total_bytes", `Int fetch_bytes);
             ("tiles", `Int tiles);
             ("covered", `Bool covered);
             (* Depth granted per region, in request order. Less than the
                region asked for means "too big, stopping at regional
                detail" -- the UI names which ones. *)
             ("max_zooms", `List (List.map (fun z -> `Int z) depths));
           ])
  | exception e -> Error (friendly e)

(* ----------------------------------------------------------------- assets *)

let dir_exists path =
  match Eio.Path.kind ~follow:true path with `Directory -> true | _ -> false

let ensure_dir path = if not (dir_exists path) then Eio.Path.mkdir ~perm:0o755 path

let write_entry dir segments contents =
  let rec go parent = function
    | [] -> ()
    | [ name ] ->
        Eio.Path.save ~create:(`Or_truncate 0o644) Eio.Path.(parent / name)
          contents
    | seg :: rest ->
        let child = Eio.Path.(parent / seg) in
        ensure_dir child;
        go child rest
  in
  go dir segments

(* The tarball's top-level directory is the repository name plus a commit-ish
   ("basemaps-assets-main/..."); only the fonts and sprites under it matter,
   and they land under the basemap dir without that wrapper. *)
let fetch_assets t ~sw ~net ~assets ~dir =
  if not (dir_exists Eio.Path.(dir / "fonts") && dir_exists Eio.Path.(dir / "sprites"))
  then begin
    set t Basemap_job.Assets;
    let body = Pmtiles_source.get_body ~sw ~net assets in
    check_cancel t;
    let entries = Untar.list (Gzip.decompress body) in
    List.iter
      (fun (path, contents) ->
        match String.split_on_char '/' path with
        | _wrapper :: (("fonts" | "sprites") :: _ as rest) ->
            write_entry dir rest contents
        | _ -> ())
      entries
  end

(* ---------------------------------------------------------------- download *)

let union_boxes boxes =
  List.fold_left
    (fun (a, b, c, d) (a', b', c', d') ->
      (Float.min a a', Float.min b b', Float.max c c', Float.max d d'))
    (180., 90., -180., -90.)
    boxes

(* Copies the archive byte-for-byte under .part + rename, changing only its
   metadata. One full pass of disk IO, zero network. This is the ledger's
   fallback path: a record that must land when no tile write is carrying it. *)
let copy_with_metadata t ~fs ~basemap_dir ~metadata ~on_progress
    (b : Pmtiles.Archive.t) =
  let dir = Eio.Path.(fs / basemap_dir) in
  let part_path = Eio.Path.(dir / "map.pmtiles.part") in
  let keep_all ~z:_ ~x:_ ~y:_ = false in
  let plan, _ =
    Pmtiles.Merge.prune ~on_entry:(breathe ~cancel:t ()) ~base:b ~drop:keep_all
      ()
  in
  let bh = b.Pmtiles.Archive.header in
  let total = plan.Pmtiles.Merge.total_bytes in
  let e7f v = float_of_int v /. 1e7 in
  Eio.Path.with_open_out ~create:(`Or_truncate 0o644) part_path (fun out ->
      let written = ref 0 in
      let append str = Eio.Flow.copy_string str out in
      let copy ~origin:_ ~offset ~length =
        check_cancel t;
        Eio.Flow.copy_string
          (b.Pmtiles.Archive.src.Pmtiles.Archive.read ~offset ~length)
          out;
        written := !written + length;
        on_progress (min !written total) total
      in
      ignore
        (Pmtiles.Merge.write ~metadata plan bh
           ~min_zoom:bh.Pmtiles.Header.min_zoom
           ~max_zoom:bh.Pmtiles.Header.max_zoom
           ~min_lon:(e7f bh.Pmtiles.Header.min_lon_e7)
           ~min_lat:(e7f bh.Pmtiles.Header.min_lat_e7)
           ~max_lon:(e7f bh.Pmtiles.Header.max_lon_e7)
           ~max_lat:(e7f bh.Pmtiles.Header.max_lat_e7)
           ~append ~copy));
  Eio.Path.rename part_path Eio.Path.(dir / "map.pmtiles")

(* A completed download owns its region: any browse-cache tiles it covers
   are dropped, because the tile endpoint consults the cache FIRST and a
   stale browsed copy must never shadow bytes an explicit download or
   update just fetched. Waits out an in-flight browse -- none can start
   while the job runs, so the wait is bounded by the one already going. *)
let prune_cache t ~fs ~basemap_dir ~regions =
  while Eio.Mutex.use_ro t.mutex (fun () -> t.browsing) do
    Eio.Fiber.yield ()
  done;
  Eio.Switch.run @@ fun sw ->
  match open_cache ~sw ~fs ~basemap_dir with
  | None -> ()
  | Some cache ->
      let owner =
        Ledger.make ~name:"-" ~regions ~completed:0 ~source:"-" ~bytes:0
      in
      let drop = Ledger.drops ~removed:owner ~kept:[] in
      let pruned, dropped =
        Pmtiles.Merge.prune ~on_entry:(breathe ~cancel:t ()) ~base:cache ~drop
          ()
      in
      if dropped = 0 then ()
      else if Array.length pruned.Pmtiles.Merge.tiles = 0 then
        Eio.Path.unlink Eio.Path.(fs / basemap_dir / "cache.pmtiles")
      else begin
        let part = Eio.Path.(fs / basemap_dir / "cache.pmtiles.part") in
        let ch = cache.Pmtiles.Archive.header in
        let e7f v = float_of_int v /. 1e7 in
        Eio.Path.with_open_out ~create:(`Or_truncate 0o644) part (fun out ->
            let append str = Eio.Flow.copy_string str out in
            let copy ~origin:_ ~offset ~length =
              Eio.Flow.copy_string
                (cache.Pmtiles.Archive.src.Pmtiles.Archive.read ~offset
                   ~length)
                out
            in
            ignore
              (Pmtiles.Merge.write pruned ch
                 ~min_zoom:ch.Pmtiles.Header.min_zoom
                 ~max_zoom:ch.Pmtiles.Header.max_zoom
                 ~min_lon:(e7f ch.Pmtiles.Header.min_lon_e7)
                 ~min_lat:(e7f ch.Pmtiles.Header.min_lat_e7)
                 ~max_lon:(e7f ch.Pmtiles.Header.max_lon_e7)
                 ~max_lat:(e7f ch.Pmtiles.Header.max_lat_e7)
                 ~append ~copy));
        Eio.Path.rename part Eio.Path.(fs / basemap_dir / "cache.pmtiles")
      end

(* Units run in order, each merged into the archive and renamed atomically
   before the next begins. That sequencing IS the resume story: cancel or a
   crash mid-unit loses only the current .part, every finished unit is
   already the archive on disk, and a re-request finds its tiles held and
   skips it after the planning cost alone. The price is that each unit
   rewrites the archive it grows -- recorded on the roadmap, not hidden. *)
let run_download t ~fs ~net ~source ~assets ~basemap_dir ~budget ~name ~now
    ~refresh ~replaces (reqs : Basemap_job.request list) =
  let dir = Eio.Path.(fs / basemap_dir) in
  let part_path = Eio.Path.(dir / "map.pmtiles.part") in
  let discard_part () = try Eio.Path.unlink part_path with _ -> () in
  match
    Eio.Switch.run @@ fun sw ->
    let resolved, src, archive = open_source ~sw ~fs ~net ~source in
    let h = archive.Pmtiles.Archive.header in
    let min_zoom = h.Pmtiles.Header.min_zoom in
    let units, depths = units_of ~cancel:t ~budget ~header:h reqs in
    let parts_total = List.length units in
    ensure_dir dir;
    let name = match name with Some n -> n | None -> default_name reqs in
    (* The ledger records what was GRANTED, not what was asked: a clamped
       giant never fetched below its granted depth, and Remove undoes only
       what actually happened. Identity is fixed here, before anything
       runs; the completion time and byte count are filled in when they
       are true. *)
    let recorded =
      List.map2
        (fun (r : Basemap_job.request) depth ->
          { r with Basemap_job.max_zoom = min r.Basemap_job.max_zoom depth })
        reqs depths
    in
    let entry ~completed ~bytes =
      Ledger.make ~name ~regions:recorded ~completed ~source:resolved ~bytes
    in
    let entry_id = Ledger.id (entry ~completed:0 ~bytes:0) in
    (* An update replaces the entry it came from even if a changed budget
       granted a different depth this time -- two records claiming the same
       place would leave one of them describing tiles the other owns. *)
    let record led e =
      let led =
        match replaces with
        | Some old_id when old_id <> entry_id -> (
            match Ledger.remove led ~id:old_id with
            | Some (_, rest) -> rest
            | None -> led)
        | _ -> led
      in
      Ledger.record led e
    in
    let written_total = ref 0 in
    let fetched_total = ref 0 in
    let wrote_any = ref false in
    let found_tiles = ref false in
    let entry_written = ref false in
    List.iteri
      (fun i unit ->
        check_cancel t;
        (* Honest between parts: the next piece really is being planned. *)
        set t Basemap_job.Planning;
        let part = i + 1 in
        (* A switch per unit so each part's base handle closes when its
           part ends. The rename happens while it is open -- POSIX keeps
           the old inode alive for the open reader, and every base read of
           this part completes before the rename. *)
        Eio.Switch.run @@ fun usw ->
        let base = open_base ~sw:usw ~fs ~basemap_dir in
        guard_compression ~h base;
        let base_meta, base_led = base_ledger base in
        let plans =
          List.map (plan_box ~cancel:t ~archive ~min_zoom) (segments_of unit)
        in
        if
          List.exists
            (fun (f : Pmtiles.Extract.plan) ->
              Array.length f.Pmtiles.Extract.tiles > 0)
            plans
        then found_tiles := true;
        let mp =
          Pmtiles.Merge.plan ~on_entry:(breathe ~cancel:t ()) ~refresh ~base
            plans
        in
        (* Nothing new in this unit -- the resume case -- writes nothing. *)
        if mp.Pmtiles.Merge.fresh_tiles > 0 || mp.Pmtiles.Merge.refreshed_tiles > 0
        then begin
          check_cancel t;
          let total = mp.Pmtiles.Merge.total_bytes in
          set t
            (Basemap_job.progress ~done_bytes:0 ~total_bytes:total ~part
               ~parts:parts_total);
          (* The merged header describes the union: the base's box and zooms
             grown by this unit's, so mid-sequence archives stay honest
             about what they hold. *)
          let e7f v = float_of_int v /. 1e7 in
          let u_min_lon, u_min_lat, u_max_lon, u_max_lat =
            union_boxes (List.map (fun (s : segment) -> s.box) (segments_of unit))
          in
          let u_depth =
            List.fold_left
              (fun acc (s : segment) -> max acc s.depth)
              min_zoom (segments_of unit)
          in
          let min_zoom', max_zoom', min_lon, min_lat, max_lon, max_lat =
            match base with
            | None ->
                (min_zoom, u_depth, u_min_lon, u_min_lat, u_max_lon, u_max_lat)
            | Some b ->
                let bh = b.Pmtiles.Archive.header in
                ( min min_zoom bh.Pmtiles.Header.min_zoom,
                  max u_depth bh.Pmtiles.Header.max_zoom,
                  Float.min u_min_lon (e7f bh.Pmtiles.Header.min_lon_e7),
                  Float.min u_min_lat (e7f bh.Pmtiles.Header.min_lat_e7),
                  Float.max u_max_lon (e7f bh.Pmtiles.Header.max_lon_e7),
                  Float.max u_max_lat (e7f bh.Pmtiles.Header.max_lat_e7) )
          in
          (* Written under a .part name and renamed only once complete, so
             the file the map reads is never mid-write and a failure leaves
             the previous archive untouched. *)
          Eio.Path.with_open_out ~create:(`Or_truncate 0o644) part_path
            (fun out ->
              let written = ref 0 in
              let append str = Eio.Flow.copy_string str out in
              let copy ~origin ~offset ~length =
                check_cancel t;
                let bytes =
                  match origin with
                  | Pmtiles.Merge.Base -> (
                      match base with
                      | Some b ->
                          b.Pmtiles.Archive.src.Pmtiles.Archive.read ~offset
                            ~length
                      | None -> assert false (* no Base blobs without a base *))
                  | Pmtiles.Merge.Fresh ->
                      src.Pmtiles.Archive.read ~offset ~length
                in
                Eio.Flow.copy_string bytes out;
                written := !written + length;
                set t
                  (Basemap_job.progress ~done_bytes:!written ~total_bytes:total
                     ~part ~parts:parts_total)
              in
              (* The last part that writes also publishes the ledger entry, in
                 the same rename that publishes its tiles: the record and the
                 tiles it describes are never separated by a crash window.
                 [bytes] is what the network delivered -- the number the
                 estimate quoted -- not the archive bytes copied merging. *)
              let metadata =
                if part < parts_total then base_meta
                else begin
                  let e =
                    entry ~completed:(now ())
                      ~bytes:
                        (!fetched_total + mp.Pmtiles.Merge.fetch_bytes)
                  in
                  match
                    Ledger.to_metadata (record base_led e) ~previous:base_meta
                  with
                  | Ok m ->
                      entry_written := true;
                      m
                  | Error m -> failwith m
                end
              in
              ignore
                (Pmtiles.Merge.write ~metadata mp h ~min_zoom:min_zoom'
                   ~max_zoom:max_zoom' ~min_lon ~min_lat ~max_lon ~max_lat
                   ~append ~copy));
          Eio.Path.rename part_path Eio.Path.(dir / "map.pmtiles");
          wrote_any := true;
          written_total := !written_total + total;
          fetched_total := !fetched_total + mp.Pmtiles.Merge.fetch_bytes
        end)
      units;
    if not !found_tiles then failwith "the source has no tiles in that area";
    (* The entry may still be unpublished: the final part was skipped as
       already held, or nothing was fetched at all. A repeat of a recorded
       download stays a no-op and says so; anything else gets the entry via
       one metadata-only rewrite -- including an archive from before the
       ledger existed, which is adopted with completion time zero, meaning
       "age unknown, treat as stale". *)
    if not !entry_written then begin
      Eio.Switch.run @@ fun usw ->
      let base = open_base ~sw:usw ~fs ~basemap_dir in
      let base_meta, base_led = base_ledger base in
      let already = Ledger.find base_led ~id:entry_id <> None in
      if (not !wrote_any) && already then
        failwith "you already have the maps for that area";
      match base with
      | None -> ()  (* nothing written and nothing on disk: no record *)
      | Some b ->
          let completed = if !wrote_any then now () else 0 in
          let e = entry ~completed ~bytes:!fetched_total in
          let metadata =
            match
              Ledger.to_metadata (record base_led e) ~previous:base_meta
            with
            | Ok m -> m
            | Error m -> failwith m
          in
          copy_with_metadata t ~fs ~basemap_dir ~metadata
            ~on_progress:(fun _ _ -> ())
            b
    end;
    prune_cache t ~fs ~basemap_dir ~regions:recorded;
    fetch_assets t ~sw ~net ~assets ~dir;
    (!written_total, parts_total)
  with
  | total_bytes, parts ->
      set t (Basemap_job.Done { total_bytes; parts })
  | exception Cancelled_by_user ->
      discard_part ();
      set t Basemap_job.Cancelled
  | exception e ->
      discard_part ();
      set t (Basemap_job.Failed (friendly e))

(* ----------------------------------------------------------------- remove *)

(* Rewrites the archive without one ledger entry's tiles, entry and tiles
   leaving in the same atomic rename. Never touches the network. When the
   last tile goes, the archive file goes with it -- an empty archive and a
   missing one should be the same state, and the missing one is the honest
   spelling. *)
let run_remove t ~fs ~basemap_dir ~id =
  let dir = Eio.Path.(fs / basemap_dir) in
  let part_path = Eio.Path.(dir / "map.pmtiles.part") in
  let discard_part () = try Eio.Path.unlink part_path with _ -> () in
  match
    Eio.Switch.run @@ fun sw ->
    match open_base ~sw ~fs ~basemap_dir with
    | None -> failwith "there is no downloaded map to remove from"
    | Some b -> (
        let base_meta, led = base_ledger (Some b) in
        match Ledger.remove led ~id with
        | None -> failwith "no such downloaded map"
        | Some (gone, kept) ->
            let drop = Ledger.drops ~removed:gone ~kept in
            let pruned, dropped_tiles =
              Pmtiles.Merge.prune ~on_entry:(breathe ~cancel:t ()) ~base:b
                ~drop ()
            in
            let bh = b.Pmtiles.Archive.header in
            (* The whole file: header, directories and metadata free along
               with the tile data. *)
            let before =
              bh.Pmtiles.Header.data_offset + bh.Pmtiles.Header.data_length
            in
            if Array.length pruned.Pmtiles.Merge.tiles = 0 then begin
              Eio.Path.unlink Eio.Path.(dir / "map.pmtiles");
              before
            end
            else if dropped_tiles = 0 then begin
              (* Everything the entry covered is shared with what stays. The
                 record still goes; the tiles were never only its own. *)
              let metadata =
                match Ledger.to_metadata kept ~previous:base_meta with
                | Ok m -> m
                | Error m -> failwith m
              in
              copy_with_metadata t ~fs ~basemap_dir ~metadata
                ~on_progress:(fun done_bytes total_bytes ->
                  set t (Basemap_job.Removing { done_bytes; total_bytes }))
                b;
              0
            end
            else begin
              let metadata =
                match Ledger.to_metadata kept ~previous:base_meta with
                | Ok m -> m
                | Error m -> failwith m
              in
              let total = pruned.Pmtiles.Merge.total_bytes in
              set t (Basemap_job.Removing { done_bytes = 0; total_bytes = total });
              let new_header = ref None in
              let e7f v = float_of_int v /. 1e7 in
              Eio.Path.with_open_out ~create:(`Or_truncate 0o644) part_path
                (fun out ->
                  let written = ref 0 in
                  let append str = Eio.Flow.copy_string str out in
                  let copy ~origin:_ ~offset ~length =
                    check_cancel t;
                    Eio.Flow.copy_string
                      (b.Pmtiles.Archive.src.Pmtiles.Archive.read ~offset
                         ~length)
                      out;
                    written := !written + length;
                    set t
                      (Basemap_job.Removing
                         {
                           done_bytes = min !written total;
                           total_bytes = total;
                         })
                  in
                  new_header :=
                    Some
                      (Pmtiles.Merge.write ~metadata pruned bh
                         ~min_zoom:bh.Pmtiles.Header.min_zoom
                         ~max_zoom:bh.Pmtiles.Header.max_zoom
                         ~min_lon:(e7f bh.Pmtiles.Header.min_lon_e7)
                         ~min_lat:(e7f bh.Pmtiles.Header.min_lat_e7)
                         ~max_lon:(e7f bh.Pmtiles.Header.max_lon_e7)
                         ~max_lat:(e7f bh.Pmtiles.Header.max_lat_e7)
                         ~append ~copy));
              Eio.Path.rename part_path Eio.Path.(dir / "map.pmtiles");
              let after =
                match !new_header with
                | Some (nh : Pmtiles.Header.t) ->
                    nh.Pmtiles.Header.data_offset
                    + nh.Pmtiles.Header.data_length
                | None -> before
              in
              max 0 (before - after)
            end)
  with
  | freed_bytes -> set t (Basemap_job.Removed { freed_bytes })
  | exception Cancelled_by_user ->
      discard_part ();
      set t Basemap_job.Cancelled
  | exception e ->
      discard_part ();
      set t (Basemap_job.Failed (friendly e))

(* ----------------------------------------------------------------- browse *)

(* An archive's whole contents restated as an extract plan, blobs at their
   absolute offsets -- what compaction feeds the merge as "fresh". *)
let plan_of_archive (a : Pmtiles.Archive.t) : Pmtiles.Extract.plan =
  let arr = Pmtiles.Merge.expand_base ~on_entry:(fun () -> ()) a in
  {
    Pmtiles.Extract.blobs =
      Array.map (fun (_, offset, length) -> (offset, length)) arr;
    tiles = Array.mapi (fun i (id, _, _) -> (id, i)) arr;
  }

(* Folds the browse cache into the main archive: one merge whose "fresh"
   side is read from the cache file instead of the network, published under
   the same rename discipline as a download, ledger carried forward
   untouched -- browsed tiles stay anonymous. Claims the job (one
   map.pmtiles writer at a time); the caller skips folding when a download
   is running and tries again after a later browse. *)
let run_compact t ~fs ~basemap_dir =
  let dir = Eio.Path.(fs / basemap_dir) in
  let part_path = Eio.Path.(dir / "map.pmtiles.part") in
  let discard_part () = try Eio.Path.unlink part_path with _ -> () in
  match
    Eio.Switch.run @@ fun sw ->
    match open_cache ~sw ~fs ~basemap_dir with
    | None -> ()
    | Some cache ->
        let base = open_base ~sw ~fs ~basemap_dir in
        let base_meta, _ = base_ledger base in
        let fresh = plan_of_archive cache in
        let mp =
          Pmtiles.Merge.plan ~on_entry:(breathe ~cancel:t ()) ~base [ fresh ]
        in
        let total = mp.Pmtiles.Merge.total_bytes in
        set t (Basemap_job.Compacting { done_bytes = 0; total_bytes = total });
        let ch = cache.Pmtiles.Archive.header in
        let e7f v = float_of_int v /. 1e7 in
        let min_zoom', max_zoom', min_lon, min_lat, max_lon, max_lat =
          match base with
          | None ->
              ( ch.Pmtiles.Header.min_zoom,
                ch.Pmtiles.Header.max_zoom,
                e7f ch.Pmtiles.Header.min_lon_e7,
                e7f ch.Pmtiles.Header.min_lat_e7,
                e7f ch.Pmtiles.Header.max_lon_e7,
                e7f ch.Pmtiles.Header.max_lat_e7 )
          | Some b ->
              let bh = b.Pmtiles.Archive.header in
              ( min ch.Pmtiles.Header.min_zoom bh.Pmtiles.Header.min_zoom,
                max ch.Pmtiles.Header.max_zoom bh.Pmtiles.Header.max_zoom,
                Float.min
                  (e7f ch.Pmtiles.Header.min_lon_e7)
                  (e7f bh.Pmtiles.Header.min_lon_e7),
                Float.min
                  (e7f ch.Pmtiles.Header.min_lat_e7)
                  (e7f bh.Pmtiles.Header.min_lat_e7),
                Float.max
                  (e7f ch.Pmtiles.Header.max_lon_e7)
                  (e7f bh.Pmtiles.Header.max_lon_e7),
                Float.max
                  (e7f ch.Pmtiles.Header.max_lat_e7)
                  (e7f bh.Pmtiles.Header.max_lat_e7) )
        in
        Eio.Path.with_open_out ~create:(`Or_truncate 0o644) part_path
          (fun out ->
            let written = ref 0 in
            let append str = Eio.Flow.copy_string str out in
            let copy ~origin ~offset ~length =
              check_cancel t;
              let bytes =
                match origin with
                | Pmtiles.Merge.Base -> (
                    match base with
                    | Some b ->
                        b.Pmtiles.Archive.src.Pmtiles.Archive.read ~offset
                          ~length
                    | None -> assert false)
                | Pmtiles.Merge.Fresh ->
                    cache.Pmtiles.Archive.src.Pmtiles.Archive.read ~offset
                      ~length
              in
              Eio.Flow.copy_string bytes out;
              written := !written + length;
              set t
                (Basemap_job.Compacting
                   { done_bytes = min !written total; total_bytes = total })
            in
            ignore
              (Pmtiles.Merge.write ~metadata:base_meta mp ch
                 ~min_zoom:min_zoom' ~max_zoom:max_zoom' ~min_lon ~min_lat
                 ~max_lon ~max_lat ~append ~copy));
        Eio.Path.rename part_path Eio.Path.(dir / "map.pmtiles");
        Eio.Path.unlink Eio.Path.(dir / "cache.pmtiles")
  with
  | () -> set t Basemap_job.Idle
  | exception Cancelled_by_user ->
      discard_part ();
      set t Basemap_job.Cancelled
  | exception e ->
      discard_part ();
      set t (Basemap_job.Failed (friendly e))

(* One viewport's missing tiles, fetched into the cache. Opt-in (gated in
   the handler on the browse_cache setting), quiet, and bounded: a request
   naming too many tiles is refused rather than becoming a download in
   disguise -- the card is the place for those. *)
let max_browse_tiles = 1_024

let run_browse t ~sw ~fs ~net ~source ~basemap_dir ~budget
    (req : Basemap_job.request) =
  (* One browse at a time, and none while the archive writer is busy: a
     download prunes its region out of the cache when it completes, and a
     browse landing mid-prune would race the same file. *)
  let claimed =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        if t.browsing || Basemap_job.is_running t.job then false
        else begin
          t.browsing <- true;
          true
        end)
  in
  if not claimed then Error "the map is busy; try again shortly"
  else
    Fun.protect
      ~finally:(fun () ->
        Eio.Mutex.use_rw ~protect:true t.mutex (fun () -> t.browsing <- false))
      (fun () ->
        match
          Eio.Switch.run @@ fun bsw ->
          let _resolved, src, archive = open_source ~sw:bsw ~fs ~net ~source in
          let h = archive.Pmtiles.Archive.header in
          let zoom =
            max h.Pmtiles.Header.min_zoom
              (min req.max_zoom h.Pmtiles.Header.max_zoom)
          in
          let ids =
            Pmtiles.Tile_id.count_ids ~min_zoom:zoom ~max_zoom:zoom
              ~min_lon:req.min_lon ~min_lat:req.min_lat ~max_lon:req.max_lon
              ~max_lat:req.max_lat
          in
          if ids > max_browse_tiles then
            failwith "the view is too wide to cache; zoom in"
          else begin
            let plan =
              Pmtiles.Extract.plan
                ~on_tile:(breathe ())
                archive ~min_zoom:zoom ~max_zoom:zoom ~min_lon:req.min_lon
                ~min_lat:req.min_lat ~max_lon:req.max_lon ~max_lat:req.max_lat
            in
            let main = open_base ~sw:bsw ~fs ~basemap_dir in
            let cache = open_cache ~sw:bsw ~fs ~basemap_dir in
            let held archive id =
              match archive with
              | None -> false
              | Some a -> Pmtiles.Archive.locate a id <> None
            in
            (* Tiles either archive holds are not fetched again; the tile
               endpoint already serves them. *)
            let wanted =
              Array.of_list
                (List.filter
                   (fun (id, _) -> not (held main id || held cache id))
                   (Array.to_list plan.Pmtiles.Extract.tiles))
            in
            if Array.length wanted = 0 then 0
            else begin
              let filtered = { plan with Pmtiles.Extract.tiles = wanted } in
              let mp =
                Pmtiles.Merge.plan ~on_entry:(breathe ()) ~base:cache
                  [ filtered ]
              in
              let part_path =
                Eio.Path.(fs / basemap_dir / "cache.pmtiles.part")
              in
              ensure_dir Eio.Path.(fs / basemap_dir);
              Eio.Path.with_open_out ~create:(`Or_truncate 0o644) part_path
                (fun out ->
                  let append str = Eio.Flow.copy_string str out in
                  let copy ~origin ~offset ~length =
                    let bytes =
                      match origin with
                      | Pmtiles.Merge.Base -> (
                          match cache with
                          | Some c ->
                              c.Pmtiles.Archive.src.Pmtiles.Archive.read
                                ~offset ~length
                          | None -> assert false)
                      | Pmtiles.Merge.Fresh ->
                          src.Pmtiles.Archive.read ~offset ~length
                    in
                    Eio.Flow.copy_string bytes out
                  in
                  let e7f v = float_of_int v /. 1e7 in
                  let u_min_lon, u_min_lat, u_max_lon, u_max_lat =
                    match cache with
                    | None -> (req.min_lon, req.min_lat, req.max_lon, req.max_lat)
                    | Some c ->
                        let chh = c.Pmtiles.Archive.header in
                        ( Float.min req.min_lon (e7f chh.Pmtiles.Header.min_lon_e7),
                          Float.min req.min_lat (e7f chh.Pmtiles.Header.min_lat_e7),
                          Float.max req.max_lon (e7f chh.Pmtiles.Header.max_lon_e7),
                          Float.max req.max_lat (e7f chh.Pmtiles.Header.max_lat_e7) )
                  in
                  let min_zoom' =
                    match cache with
                    | None -> zoom
                    | Some c -> min zoom c.Pmtiles.Archive.header.Pmtiles.Header.min_zoom
                  in
                  let max_zoom' =
                    match cache with
                    | None -> zoom
                    | Some c -> max zoom c.Pmtiles.Archive.header.Pmtiles.Header.max_zoom
                  in
                  ignore
                    (Pmtiles.Merge.write mp h ~min_zoom:min_zoom'
                       ~max_zoom:max_zoom' ~min_lon:u_min_lon
                       ~min_lat:u_min_lat ~max_lon:u_max_lon
                       ~max_lat:u_max_lat ~append ~copy));
              Eio.Path.rename part_path
                Eio.Path.(fs / basemap_dir / "cache.pmtiles");
              mp.Pmtiles.Merge.fresh_tiles
            end
          end
        with
        | fetched ->
            (* Fold the cache into the main archive once it outgrows the
               threshold -- unless a download holds the writer's seat, in
               which case a later browse will try again. *)
            (if fetched > 0 then
               Eio.Switch.run @@ fun csw ->
               match open_cache ~sw:csw ~fs ~basemap_dir with
               | Some c
                 when c.Pmtiles.Archive.header.Pmtiles.Header.data_length
                      > budget.compact ->
                   if claim t then
                     Eio.Fiber.fork ~sw (fun () -> run_compact t ~fs ~basemap_dir)
               | _ -> ());
            Ok fetched
        | exception e -> Error (friendly e))

(* ------------------------------------------------------------- lifecycle *)

let start t ~sw ~fs ~net ~source ~assets ~basemap_dir ~budget ~name ~now reqs =
  if not (claim t) then Error "a download is already running"
  else begin
    Eio.Fiber.fork ~sw (fun () ->
        run_download t ~fs ~net ~source ~assets ~basemap_dir ~budget ~name ~now
          ~refresh:false ~replaces:None reqs);
    Ok ()
  end

(* An update is the recorded download run again with the merge tie inverted:
   every tile in the region is fetched fresh and replaces its stale copy.
   The regions come from the ledger, and the run replaces the entry it came
   from by id -- explicitly, so a budget change that alters the granted
   depth cannot leave two records claiming the same place. *)
let start_update t ~sw ~fs ~net ~source ~assets ~basemap_dir ~budget ~now ~id =
  if not (claim t) then Error "a download is already running"
  else begin
    Eio.Fiber.fork ~sw (fun () ->
        match
          Eio.Switch.run @@ fun usw ->
          let base = open_base ~sw:usw ~fs ~basemap_dir in
          let _meta, led = base_ledger base in
          Ledger.find led ~id
        with
        | None -> set t (Basemap_job.Failed "no such downloaded map")
        | Some e ->
            run_download t ~fs ~net ~source ~assets ~basemap_dir ~budget
              ~name:(Some e.Ledger.name) ~now ~refresh:true ~replaces:(Some id)
              e.Ledger.regions
        | exception e -> set t (Basemap_job.Failed (friendly e)));
    Ok ()
  end

let start_remove t ~sw ~fs ~basemap_dir ~id =
  if not (claim t) then Error "a download is already running"
  else begin
    Eio.Fiber.fork ~sw (fun () -> run_remove t ~fs ~basemap_dir ~id);
    Ok ()
  end

(* What the archive holds, for the UI's downloaded-maps list. Reading it
   opens the archive fresh each time -- a header and a metadata blob, not
   the tiles -- so the list is always what is on disk right now. *)
let ledger_json ~fs ~basemap_dir =
  match
    Eio.Switch.run @@ fun sw ->
    let base = open_base ~sw ~fs ~basemap_dir in
    let _meta, led = base_ledger base in
    `Assoc
      [
        ( "entries",
          `List
            (List.map
               (fun (e : Ledger.entry) ->
                 `Assoc
                   [
                     ("id", `String (Ledger.id e));
                     ("name", `String e.Ledger.name);
                     ("completed", `Int e.Ledger.completed);
                     ("source", `String e.Ledger.source);
                     ("bytes", `Int e.Ledger.bytes);
                     ("regions", `Int (List.length e.Ledger.regions));
                     ( "max_zoom",
                       `Int
                         (List.fold_left
                            (fun acc (r : Basemap_job.request) ->
                              max acc r.max_zoom)
                            0 e.Ledger.regions) );
                   ])
               led) );
      ]
  with
  | json -> Ok json
  | exception e -> Error (friendly e)

let ops t ~sw ~fs ~net ~source ~assets ~basemap_dir ~budget ~now =
  {
    estimate = (fun reqs -> estimate ~fs ~net ~source ~basemap_dir ~budget reqs);
    start =
      (fun ~name reqs ->
        start t ~sw ~fs ~net ~source ~assets ~basemap_dir ~budget ~name ~now
          reqs);
    cancel = (fun () -> cancel t);
    status = (fun () -> status t);
    ledger = (fun () -> ledger_json ~fs ~basemap_dir);
    update =
      (fun ~id ->
        start_update t ~sw ~fs ~net ~source ~assets ~basemap_dir ~budget ~now
          ~id);
    remove = (fun ~id -> start_remove t ~sw ~fs ~basemap_dir ~id);
    browse =
      (fun req -> run_browse t ~sw ~fs ~net ~source ~basemap_dir ~budget req);
  }
