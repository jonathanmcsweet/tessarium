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
  (* Broadcast when [browsing] clears, so a download waiting to prune the
     cache sleeps instead of spinning through the browse's network time. *)
  browse_done : Eio.Condition.t;
  (* "Erase the browse cache when you let go of it." Set when the user turns
     browsing off while a writer holds the file, and honoured by that writer
     on its way out -- so the request answers at once and the erasing still
     happens, rather than the request waiting on someone else's network. *)
  mutable clear_requested : bool;
}

(* The tile archives, in the order a lookup tries them. Named once because
   three readers have to agree: the tile endpoint serves from them, the
   coverage query answers questions ABOUT them, and the downloader writes
   them. A list that drifted apart here would have the map drawing tiles a
   coverage query had just called missing.

   Newest first. [cache_file] is what browsing picked up, [base_file] is
   what was downloaded on purpose, and [world_file] is an optional world
   overview -- a shallow pyramid of the whole planet, dropped in beside the
   others and never written by the downloader. It is last because it is the
   coarsest: anything the other two hold is better.

   It is not special-cased anywhere. Its only job is to make the floor's
   depth measure deeper, and that measurement counts every archive
   together, so an archive that already holds the world needs no such
   file. *)
let cache_file = "cache.pmtiles"
let base_file = "map.pmtiles"
let world_file = "world.pmtiles"

(* What a tile lookup searches, in order. *)
let tile_files = [ cache_file; base_file; world_file ]

(* What "downloaded" means. The world overview is not a download and must
   not be counted as one: it is nobody's region, and the detail source's
   bounds come from these so that the map does not ask about a planet nobody
   fetched. *)
let detail_files = [ cache_file; base_file ]

(* Which archive a download writes, and the only thing that differs between
   the two kinds of download this server runs.

   A region joins the detail archive and is recorded in the ledger there, so
   it can be named, listed, updated and removed. The world overview is not a
   region: it belongs to no place, it is what the map falls back to
   everywhere, and every package now ships one. Putting it in the detail
   archive made it removable by accident -- take away the region whose entry
   happened to carry it and the floor goes with it -- and gave the ledger a
   row for something the user cannot meaningfully remove.

   So it goes to its own file and writes no record. It merges with whatever
   overview is already there, which is what makes deepening the shipped zoom
   4 to zoom 6 cost only the levels in between. *)
type target = Detail | World

let file_of = function Detail -> base_file | World -> world_file

(* How deep the floor is ever allowed to go. The scan below is one lookup
   per tile of a whole zoom level, so the work quadruples with every step:
   zoom 6 is 4096 lookups and zoom 10 would be a million. Six is also as
   deep as a world overview is worth shipping -- past it the file is
   measured in hundreds of megabytes. *)
let max_floor_zoom = 6

(* Whether an archive's data section is actually on disk.

   A truncated file -- a fetch interrupted after the header and directories
   were written -- answers every directory lookup and fails half the reads,
   which is the one shape that can fool the scan below into certifying a
   floor full of holes. Cheap to rule out: the header says where the data
   ends, and the file either reaches that far or it does not.

   Only the floor asks. A truncated archive still serves every tile it
   really has, and taking it away entirely would turn a partial download
   into no map at all; what it may not do is be counted towards a
   completeness claim. *)
let data_is_whole ~size (a : Pmtiles.Archive.t) =
  a.Pmtiles.Archive.header.Pmtiles.Header.data_offset
  + a.Pmtiles.Archive.header.Pmtiles.Header.data_length
  <= size

(* The deepest zoom the archives cover the ENTIRE planet at.

   This is the floor's depth, and it is measured rather than declared
   because the floor's one job is to have no holes. A hole draws as an empty
   tile, an empty tile counts as data, and data replaces the coarse tile
   already on screen -- which is the bug the floor exists to fix, so a floor
   that guessed its own depth wrong would reintroduce it.

   Counted across every archive together: one may hold the world at zoom 4
   and another a country at zoom 12, and the floor stands on the union.
   Stops at the first missing tile of the first incomplete zoom, so the
   usual answers are cheap -- an archive holding one city runs out inside
   zoom 1, two or three lookups in. The full 5461 are only paid by an
   archive that really does hold the whole world, which is the case worth
   being sure about; measured at 3 ms against a 6.4 GB archive, because the
   zoom 0-6 ids sit at the front of the file in one root directory and four
   leaves.

   -1 means not even the single zoom-0 tile is there: no floor at all. *)
let floor_depth archives =
  let held ~z ~x ~y =
    let id = Pmtiles.Tile_id.of_zxy ~z ~x ~y in
    List.exists (fun a -> Pmtiles.Archive.locate a id <> None) archives
  in
  let complete z =
    let n = 1 lsl z in
    let rec scan i = i >= n * n || (held ~z ~x:(i / n) ~y:(i mod n) && scan (i + 1)) in
    scan 0
  in
  let rec deepest z =
    if z > max_floor_zoom || not (complete z) then z - 1 else deepest (z + 1)
  in
  deepest 0

(* Why a coverage query failed, kept apart because the two answers are
   different HTTP statuses: a viewport larger than the cap is the caller
   asking for more than a viewport, and an archive this server cannot read
   is this server's own data gone wrong. Reporting both as one string once
   meant a corrupt archive was blamed on the page that asked. *)
type coverage_error = Too_large of string | Unreadable of string

(* What the request handler sees: closures, so the handler can be tested
   with pure fakes and never needs the switch, the network or the clock. *)
type ops = {
  estimate :
    world:bool -> Basemap_job.request list -> (Yojson.Safe.t, string) result;
  start :
    name:string option ->
    (* One display label per region, in request order, when the client sent
       them. What the picker called each pick, echoed back in the status so
       the progress rows survive a reload -- the ledger keeps only the one
       combined name, which cannot label six bars. *)
    labels:string list option ->
    world:bool ->
    Basemap_job.request list ->
    (unit, string) result;
  cancel : unit -> bool;
  status : unit -> Yojson.Safe.t;
  ledger : unit -> (Yojson.Safe.t, string) result;
  update : id:string -> (unit, string) result;
  remove : id:string -> (unit, string) result;
  (* Writing one recorded region out as a file to carry elsewhere, and
     managing the files that produces. Reads the archive and writes beside
     it, so nothing here can damage the map the user is looking at. *)
  export : id:string -> (unit, string) result;
  exports : unit -> Yojson.Safe.t;
  delete_export : file:string -> (unit, string) result;
  (* The far side of the same trip: what is staged for import, committing
     it, and throwing it away. Receiving the bytes is not here -- it takes a
     socket, and everything in this record is meant to be callable from a
     test with none. *)
  staged : unit -> Yojson.Safe.t;
  import : unit -> (unit, string) result;
  discard_import : unit -> (unit, string) result;
  (* Answers with the tiles fetched AND the zoom actually written: the
     source's depth may be shallower than the view asked for, and a client
     that cannot tell the difference will keep asking for a depth that can
     never arrive. *)
  browse : Basemap_job.request -> (int * int, string) result;
  (* Names from the downloaded region, ranked. Reads the index built when
     the region landed; never the network. *)
  search : query:string -> limit:int -> (Yojson.Safe.t, string) result;
  (* Erases the browse cache. Never blocks and never fails: if a writer
     holds the file, the erasing is handed to it and happens when it lets
     go. Browsing is already off by the time this is called, so nothing new
     can arrive in the meantime. *)
  clear_cache : unit -> unit;
  (* Which of a viewport's tiles this server can actually serve. The
     request's [max_zoom] is the zoom the map is displaying, not a depth to
     download. *)
  coverage : Basemap_job.request -> (Yojson.Safe.t, coverage_error) result;
}

let create () =
  {
    mutex = Eio.Mutex.create ();
    job = Basemap_job.Idle;
    generation = 0;
    cancel_requested = false;
    browsing = false;
    browse_done = Eio.Condition.create ();
    clear_requested = false;
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

(* Clearing the browse seat, deliberately WITHOUT the mutex -- as the wait
   in [prune_cache] reads it without one.

   Nothing is bought by taking it. Every critical section on [t.mutex] is a
   read or an assignment with no suspension point in it, so a fiber never
   finds the mutex held, and a bool write plus a broadcast cannot raise or
   suspend either. The pairing that matters is with the waiter: it observes
   [browsing] and suspends on the condition with nothing in between, which
   is exactly what [await_no_mutex] requires.

   Both halves of that argument assume ONE domain, which is what this
   server runs. Introduce a second and this field -- and the job cell the
   waiter reads beside it -- need real synchronisation again. *)
let release_browsing t =
  t.browsing <- false;
  Eio.Condition.broadcast t.browse_done

let unlink_cache ~fs ~basemap_dir =
  List.iter
    (fun name ->
      try Eio.Path.unlink Eio.Path.(fs / basemap_dir / name) with _ -> ())
    [ cache_file; cache_file ^ ".part" ]

(* Every writer of cache.pmtiles calls this as it finishes. *)
let honor_clear t ~fs ~basemap_dir =
  if t.clear_requested then begin
    t.clear_requested <- false;
    unlink_cache ~fs ~basemap_dir
  end

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
  idx : int;
      (** which request this came from, as a position in the list the client
          sent. Carried rather than recovered by comparing requests: a batch
          may hold two picks with identical boxes -- a country and a city
          inside it clamped to the same depth -- and progress attributed by
          value would credit both to whichever matched first. *)
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
    List.mapi
      (fun idx (req : Basemap_job.request) ->
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
        (req, idx, depth, clip, parts))
      reqs
  in
  let singles, giants =
    List.partition (fun (_, _, _, _, parts) -> List.length parts = 1) split
  in
  let batch =
    match singles with
    | [] -> []
    | l ->
        [
          `Batch
            (List.map
               (fun ((req : Basemap_job.request), idx, depth, clip, parts) ->
                 { req; idx; depth; clip; box = List.hd parts })
               l);
        ]
  in
  let parts =
    List.concat_map
      (fun (req, idx, depth, clip, boxes) ->
        List.map (fun box -> `Part { req; idx; depth; clip; box }) boxes)
      giants
  in
  (batch @ parts, List.map (fun (_, _, depth, _, _) -> depth) split)

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

let open_base ~sw ~fs ~basemap_dir = open_archive ~sw ~fs ~basemap_dir base_file

(* For readers that must survive a bad file rather than fail the request:
   an archive that will not open is skipped with a warning, exactly as the
   tile endpoint skips it. A half-written map.pmtiles must not take the
   browse cache's answers down with it, and a query about tiles has to
   describe the same archives the tile endpoint will actually serve
   from. *)
let open_readable ~sw ~fs ~basemap_dir name =
  match open_archive ~sw ~fs ~basemap_dir name with
  | a -> a
  | exception e ->
      Logs.warn (fun m ->
          m "coverage: %s is unreadable: %s" name (Printexc.to_string e));
      None

let whole_archives ~sw ~fs ~basemap_dir names =
  List.filter_map
    (fun name ->
      let path = Eio.Path.(fs / basemap_dir / name) in
      match open_readable ~sw ~fs ~basemap_dir name with
      | None -> None
      | Some a ->
          let size =
            Optint.Int63.to_int
              (Eio.Path.stat ~follow:true path).Eio.File.Stat.size
          in
          if data_is_whole ~size a then Some a
          else begin
            Logs.warn (fun m ->
                m "%s is shorter than its own header says: not counted \
                   towards the floor" name);
            None
          end)
    names

(* The browse cache: anonymous tiles picked up while panning online. Its own
   file so a browse never rewrites the big archive; folded into it when it
   outgrows the budget's compaction threshold. *)
let open_cache ~sw ~fs ~basemap_dir =
  open_archive ~sw ~fs ~basemap_dir cache_file

(* Reading the archive's own labels into the search index. Runs when the
   archive changes -- a download, an update, a removal -- because that is
   exactly when the names it can offer change, and because a keystroke
   cannot wait the seconds this takes on a country. An archive with no
   tiles has no names, so its index goes rather than lingering. *)
let reindex t ~fs ~basemap_dir =
  Eio.Switch.run @@ fun sw ->
  match open_archive ~sw ~fs ~basemap_dir "map.pmtiles" with
  | None -> Place_index.remove ~fs ~basemap_dir
  | Some archive ->
      let last = ref 0 in
      let entries =
        Place_index.build archive ~on_tile:(fun done_ total ->
            (* Progress, but not thirty thousand mutex takes: the bar moves
               at a human rate either way. *)
            if done_ - !last >= 256 || done_ = total then begin
              last := done_;
              check_cancel t;
              set t
                (Basemap_job.Indexing
                   { done_tiles = done_; total_tiles = total })
            end)
      in
      Place_index.save ~fs ~basemap_dir entries

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
(* Quoted against the archive the download would JOIN, which is why this
   needs to know which kind it is. Diffing a world overview against the
   detail archive would quote the whole planet to someone whose packaged
   zoom 4 already holds most of it, and would then report it uncovered
   forever -- an offer that never goes away however many times it is
   accepted. *)
let estimate ~fs ~net ~source ~basemap_dir ~budget ~world
    (reqs : Basemap_job.request list) =
  match
    Eio.Switch.run @@ fun sw ->
    let _resolved, _src, archive = open_source ~sw ~fs ~net ~source in
    let h = archive.Pmtiles.Archive.header in
    let base =
      open_archive ~sw ~fs ~basemap_dir (file_of (if world then World else Detail))
    in
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
  (* An empty URL means "do not". The import path passes one: a file carried
     here on a stick holds tiles and nothing else, and the machine it lands
     on either already has its glyphs -- every package ships them -- or is
     offline and has no way to get them. Reaching for the network there would
     turn a working import into a failure reported after the tiles were
     already merged, which is the worst of both. *)
  if assets = "" then ()
  else if
    not (dir_exists Eio.Path.(dir / "fonts") && dir_exists Eio.Path.(dir / "sprites"))
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
      let copy ~index:_ ~origin:_ ~offset ~length =
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
  (* Reading [browsing] without the mutex is deliberate: all fibers share
     one domain, and there is no yield point between observing true and
     registering with the condition, so the clearing broadcast cannot slip
     through the gap. The mutex-guarded read had the opposite problem --
     it can suspend, and a wakeup lost there would sleep forever. *)
  while t.browsing do
    Eio.Condition.await_no_mutex t.browse_done
  done;
  Eio.Switch.run @@ fun sw ->
  match open_cache ~sw ~fs ~basemap_dir with
  | None -> ()
  | Some cache ->
      let owner =
        Ledger.make ~name:"-" ~regions ~completed:0 ~source:"-" ~bytes:0
      in
      let drop = Ledger.drops ~removed:owner ~kept:[] in
      (* Deliberately not cancellable: the prune is what keeps a stale
         browsed tile from shadowing bytes a rename already published, and
         it runs on the cancel path itself -- a cancel that aborted it
         would leave the exact incoherence it exists to prevent. Local
         disk work, bounded by the cache size. *)
      let pruned, dropped =
        Pmtiles.Merge.prune ~on_entry:(breathe ()) ~base:cache ~drop ()
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
            let copy ~index:_ ~origin:_ ~offset ~length =
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
(* [origin] overrides what the ledger records as the archive these tiles came
   from. Only an import passes one, and it must: the source it is READING is a
   temporary file in the import directory that is deleted the moment the merge
   ends, so recording that would leave every imported region citing a path
   that does not exist. What belongs in the record is what the exporting
   machine cited -- the planet build the tiles were originally cut from -- and
   the imported file carries it in its own ledger. *)
let run_download t ~fs ~net ~source ?origin ~assets ~basemap_dir ~budget ~name
    ~now ~refresh ~replaces ~target ~labels (reqs : Basemap_job.request list) =
  let dir = Eio.Path.(fs / basemap_dir) in
  let archive_file = file_of target in
  let part_path = Eio.Path.(dir / (archive_file ^ ".part")) in
  let discard_part () = try Eio.Path.unlink part_path with _ -> () in
  (* Every unit renamed into the archive owns its region from that moment,
     even when the run then stops early: cancel and failure must prune the
     browse cache exactly as success does, or the stale browsed copy of a
     tile a rename just published shadows it forever. The whole granted
     region is pruned rather than the finished parts' share -- over-pruning
     costs a re-fetchable cache tile, under-pruning costs correctness. *)
  let published = ref false in
  let prune_regions = ref [] in
  (* Once, whichever exit runs it: the success path prunes inside the switch
     and a later failure -- the assets fetch is the usual one -- must not
     walk the whole cache a second time to drop nothing. *)
  let pruned = ref false in
  let prune_published () =
    if !published && not !pruned then begin
      pruned := true;
      try prune_cache t ~fs ~basemap_dir ~regions:!prune_regions with
      | Eio.Cancel.Cancelled _ as e ->
          (* Eio requires this one to keep travelling; swallowing it leaves
             the fiber running inside a cancelled context. *)
          raise e
      | e ->
          Logs.warn (fun m ->
              m "browse cache prune failed: %s" (Printexc.to_string e))
    end
  in
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
    prune_regions := recorded;
    let recorded_source = Option.value origin ~default:resolved in
    let entry ~completed ~bytes =
      Ledger.make ~name ~regions:recorded ~completed ~source:recorded_source
        ~bytes
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

    (* ------------------------------------------- per-region progress *)

    (* What each picked region has cost, so a download of six countries reads
       as six bars rather than one anonymous total. Indexed by the region's
       position in the request, which is the order the client listed them and
       the order it will draw them in.

       Kept out here rather than per part: a region large enough to be split
       is spread across several units, and its bar must accumulate across
       them rather than restart at each one. *)
    let region_count = List.length reqs in
    let region_labels =
      match labels with
      | Some l when List.length l = region_count -> Array.of_list l
      | _ -> Array.make region_count ""
    in
    let region_done = Array.make region_count 0 in
    let region_total = Array.make region_count 0 in
    (* How many units still have to be planned before a region's total is
       final. Counted up front from the units themselves, so a bar can say
       whether its denominator is settled or still growing. *)
    let region_pending = Array.make region_count 0 in
    List.iter
      (fun unit ->
        List.iter
          (fun (s : segment) ->
            region_pending.(s.idx) <- region_pending.(s.idx) + 1)
          (segments_of unit))
      units;
    let region_rows () =
      List.init region_count (fun k ->
          {
            Basemap_job.label = region_labels.(k);
            done_bytes = region_done.(k);
            total_bytes = region_total.(k);
            planned = region_pending.(k) = 0;
          })
    in
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
        let base = open_archive ~sw:usw ~fs ~basemap_dir archive_file in
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
        (* Which region each fresh blob is being fetched for.

           A blob the merge kept from the base archive is nobody's download --
           it is already on disk and no network pays for it -- so it stays
           unowned and is credited to no row. Where several picks in one
           batch wanted a tile the merge stores once, the earliest in request
           order is credited: those bytes cross the wire once and must be
           counted once, or three overlapping picks would each claim the
           whole overlap and the rows would sum past what was fetched.

           Tile ids first, because a blob can back several tiles -- identical
           content deduplicates -- and it is the tile that belongs to a
           region, not the blob. *)
        let blob_region = Array.make (max 1 (Array.length mp.Pmtiles.Merge.blobs)) (-1) in
        let tile_region = Hashtbl.create 4096 in
        List.iter2
          (fun (seg : segment) (pl : Pmtiles.Extract.plan) ->
            Array.iter
              (fun (id, _) ->
                match Hashtbl.find_opt tile_region id with
                | Some prev when prev <= seg.idx -> ()
                | _ -> Hashtbl.replace tile_region id seg.idx)
              pl.Pmtiles.Extract.tiles)
          (segments_of unit) plans;
        Array.iter
          (fun (id, blob) ->
            if blob_region.(blob) < 0 then
              match (Hashtbl.find_opt tile_region id, mp.Pmtiles.Merge.blobs.(blob)) with
              | Some k, (Pmtiles.Merge.Fresh, _, _) -> blob_region.(blob) <- k
              | _ -> ())
          mp.Pmtiles.Merge.tiles;
        Array.iteri
          (fun blob k ->
            if k >= 0 then begin
              let _, _, length = mp.Pmtiles.Merge.blobs.(blob) in
              region_total.(k) <- region_total.(k) + length
            end)
          blob_region;
        (* Planned, whether or not this unit goes on to write anything: a
           unit that found every tile already on disk still settles the
           totals of the regions it covered. *)
        List.iter
          (fun (s : segment) ->
            region_pending.(s.idx) <- max 0 (region_pending.(s.idx) - 1))
          (segments_of unit);
        (* Nothing new in this unit -- the resume case -- writes nothing. *)
        if mp.Pmtiles.Merge.fresh_tiles > 0 || mp.Pmtiles.Merge.refreshed_tiles > 0
        then begin
          check_cancel t;
          let total = mp.Pmtiles.Merge.total_bytes in
          set t
            (Basemap_job.progress ~done_bytes:0 ~total_bytes:total ~part
               ~parts:parts_total ~regions:(region_rows ()) ());
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
              let copy ~index ~origin ~offset ~length =
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
                (* The blob's own index, not a count of calls: which blob is
                   being copied is [Merge.write]'s to say, and a counter here
                   would be a second copy of that answer to keep in step. *)
                let owner = blob_region.(index) in
                if owner >= 0 then
                  region_done.(owner) <- region_done.(owner) + length;
                set t
                  (Basemap_job.progress ~done_bytes:!written ~total_bytes:total
                     ~part ~parts:parts_total ~regions:(region_rows ()) ())
              in
              (* The last part that writes also publishes the ledger entry, in
                 the same rename that publishes its tiles: the record and the
                 tiles it describes are never separated by a crash window.
                 [bytes] is what the network delivered -- the number the
                 estimate quoted -- not the archive bytes copied merging. *)
              let metadata =
                if part < parts_total || target = World then base_meta
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
          Eio.Path.rename part_path Eio.Path.(dir / archive_file);
          wrote_any := true;
          published := true;
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
    (* The overview keeps no record, so there is nothing to publish and
       nothing to adopt -- but "you already have this" is still the honest
       answer when the merge found every tile already on disk, which is what
       a user gets who asks for the shipped depth again. *)
    if target = World then begin
      if not !wrote_any then failwith "you already have the maps for that area"
    end
    else if not !entry_written then begin
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
    (* Marked only once it has actually happened: a prune that raised left
       the cache untouched (it publishes by rename), so the terminal handler
       should still get its attempt. *)
    pruned := true;
    fetch_assets t ~sw ~net ~assets ~dir;
    (* Last, because it reads the finished archive: the names a region can
       offer are only knowable once its tiles are on disk.

       Its failure -- including a cancel arriving while it runs -- must not
       reach the terminal handlers below. By this point every tile is on
       disk and the ledger entry is published: the download DID happen, and
       reporting it as cancelled because the index was interrupted would be
       a lie the ledger immediately contradicts. A missing index costs
       search, not the map. *)
    (try reindex t ~fs ~basemap_dir with
    | Cancelled_by_user ->
        Logs.info (fun m -> m "search index skipped: cancelled")
    | e ->
        Logs.warn (fun m ->
            m "search index build failed: %s" (Printexc.to_string e)));
    (!written_total, parts_total)
  with
  | total_bytes, parts ->
      honor_clear t ~fs ~basemap_dir;
      set t (Basemap_job.Done { total_bytes; parts })
  | exception Cancelled_by_user ->
      discard_part ();
      prune_published ();
      honor_clear t ~fs ~basemap_dir;
      set t Basemap_job.Cancelled
  | exception e ->
      discard_part ();
      prune_published ();
      honor_clear t ~fs ~basemap_dir;
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
                  let copy ~index:_ ~origin:_ ~offset ~length =
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
  | freed_bytes ->
      (* This job held the writer's seat, so a clear asked for meanwhile is
         this job's to carry out as it leaves -- browsing is off by then,
         and nothing else is coming to do it. *)
      honor_clear t ~fs ~basemap_dir;
      (* The removed region's names must stop being findable, and a search
         hit flying the map to tiles that are gone is worse than no hit. *)
      (try reindex t ~fs ~basemap_dir
       with e ->
         (* Keeping the old index would leave the removed region's names
            findable, and a result flying the map to tiles that are gone is
            worse than no result. Better nothing than stale. *)
         Logs.warn (fun m ->
             m "search index rebuild failed, dropping it: %s"
               (Printexc.to_string e));
         Place_index.remove ~fs ~basemap_dir);
      set t (Basemap_job.Removed { freed_bytes })
  | exception Cancelled_by_user ->
      discard_part ();
      honor_clear t ~fs ~basemap_dir;
      set t Basemap_job.Cancelled
  | exception e ->
      discard_part ();
      honor_clear t ~fs ~basemap_dir;
      set t (Basemap_job.Failed (friendly e))

(* ----------------------------------------------------------------- export *)

(* Writing one recorded region out as a file to carry to another machine.

   This is the removal machinery pointed somewhere harmless. Removal prunes
   the archive down to the tiles an entry does NOT cover and renames the
   result over map.pmtiles; an export prunes down to the tiles it DOES cover
   and writes that beside it. The live archive is opened read-only and never
   renamed, so an export that dies halfway costs a partial file in the export
   directory and nothing the user was using.

   The exported archive carries a ledger of its own holding just that entry.
   That is what makes the trip survivable: the machine importing it reads the
   region, the granted depth, the name and the build it came from out of the
   file itself. Nothing has to be typed in on the far side, and a region
   cannot arrive as an anonymous box that the importer has to guess at. *)

let export_dir_name = "export"

(* A file name from what the user called the region.

   Everything outside a conservative ASCII set becomes a dash. The string
   lands in a filesystem, in a URL path and in a save dialog, and the set
   that is safe and predictable in all three is small -- so a Japanese or
   Arabic region name slugs down to its id rather than travelling as bytes
   that one of those three will mangle. The real name is not lost by this:
   it rides inside the file, in the ledger, and is what the importing
   machine displays. *)
let export_filename ~(entry : Ledger.entry) ~id =
  let buf = Buffer.create 32 in
  let last_dash = ref false in
  String.iter
    (fun c ->
      let keep =
        (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9')
        || c = '_'
      in
      if keep then begin
        Buffer.add_char buf c;
        last_dash := false
      end
      else if not !last_dash then begin
        Buffer.add_char buf '-';
        last_dash := true
      end)
    entry.Ledger.name;
  let slug =
    let raw = Buffer.contents buf in
    let trimmed =
      let n = String.length raw in
      let i = ref 0 and j = ref n in
      while !i < n && raw.[!i] = '-' do incr i done;
      while !j > !i && raw.[!j - 1] = '-' do decr j done;
      String.sub raw !i (!j - !i)
    in
    if trimmed = "" then "map" else trimmed
  in
  (* The id keeps two exports of similarly-named regions apart, and makes an
     export idempotent: the same entry written twice is the same file, not a
     second copy filling the disk. *)
  let short = if String.length id <= 8 then id else String.sub id 0 8 in
  Printf.sprintf "%s-%s.pmtiles" slug short

let export_path ~fs ~basemap_dir name =
  Eio.Path.(fs / basemap_dir / export_dir_name / name)

let run_export t ~fs ~basemap_dir ~id =
  let dir = Eio.Path.(fs / basemap_dir / export_dir_name) in
  match
    Eio.Switch.run @@ fun sw ->
    match open_base ~sw ~fs ~basemap_dir with
    | None -> failwith "there is no downloaded map to export"
    | Some b -> (
        let _base_meta, led = base_ledger (Some b) in
        match Ledger.find led ~id with
        | None -> failwith "no such downloaded map"
        | Some entry ->
            let file = export_filename ~entry ~id in
            let out_path = Eio.Path.(dir / file) in
            let part_path = Eio.Path.(dir / (file ^ ".part")) in
            (* Everything this entry does not cover is dropped, which is the
               whole archive minus one region. *)
            let drop = Ledger.outside ~entry in
            let pruned, _dropped =
              Pmtiles.Merge.prune ~on_entry:(breathe ~cancel:t ()) ~base:b
                ~drop ()
            in
            if Array.length pruned.Pmtiles.Merge.tiles = 0 then
              failwith
                "that map has no tiles of its own to export -- every tile it \
                 covers belongs to another region too";
            (* A ledger of one. The importing machine reads this and knows
               what it was handed; [previous] is "{}" rather than the live
               archive's metadata because none of the OTHER entries' records
               may travel in a file that holds none of their tiles. *)
            let metadata =
              match Ledger.to_metadata [ entry ] ~previous:"{}" with
              | Ok m -> m
              | Error m -> failwith m
            in
            Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 dir;
            let total = pruned.Pmtiles.Merge.total_bytes in
            set t (Basemap_job.Exporting { done_bytes = 0; total_bytes = total });
            let bh = b.Pmtiles.Archive.header in
            let e7f v = float_of_int v /. 1e7 in
            (* The exported header describes the REGION, not the archive it
               came out of: an importer reads these bounds to decide what it
               is being offered, and the live archive's box is every region
               the user ever downloaded. *)
            let r_min_lon, r_min_lat, r_max_lon, r_max_lat =
              union_boxes
                (List.map
                   (fun (r : Basemap_job.request) ->
                     (r.min_lon, r.min_lat, r.max_lon, r.max_lat))
                   entry.Ledger.regions)
            in
            let r_depth =
              List.fold_left
                (fun acc (r : Basemap_job.request) -> max acc r.max_zoom)
                bh.Pmtiles.Header.min_zoom entry.Ledger.regions
            in
            let written = ref 0 in
            let new_header = ref None in
            Eio.Path.with_open_out ~create:(`Or_truncate 0o644) part_path
              (fun out ->
                let append str = Eio.Flow.copy_string str out in
                let copy ~index:_ ~origin:_ ~offset ~length =
                  check_cancel t;
                  Eio.Flow.copy_string
                    (b.Pmtiles.Archive.src.Pmtiles.Archive.read ~offset ~length)
                    out;
                  written := !written + length;
                  set t
                    (Basemap_job.Exporting
                       { done_bytes = min !written total; total_bytes = total })
                in
                new_header :=
                  Some
                    (Pmtiles.Merge.write ~metadata pruned bh
                       ~min_zoom:bh.Pmtiles.Header.min_zoom ~max_zoom:r_depth
                       ~min_lon:(Float.max r_min_lon (e7f bh.Pmtiles.Header.min_lon_e7))
                       ~min_lat:(Float.max r_min_lat (e7f bh.Pmtiles.Header.min_lat_e7))
                       ~max_lon:(Float.min r_max_lon (e7f bh.Pmtiles.Header.max_lon_e7))
                       ~max_lat:(Float.min r_max_lat (e7f bh.Pmtiles.Header.max_lat_e7))
                       ~append ~copy));
            (* Renamed only once whole, exactly as a download is: a half
               written export that looked like a finished one would be
               carried to an offline machine and fail there, which is the
               worst place to discover it. *)
            Eio.Path.rename part_path out_path;
            let bytes =
              match !new_header with
              | Some (nh : Pmtiles.Header.t) ->
                  nh.Pmtiles.Header.data_offset + nh.Pmtiles.Header.data_length
              | None -> !written
            in
            (file, bytes))
  with
  | file, bytes -> set t (Basemap_job.Exported { file; bytes })
  | exception Cancelled_by_user -> set t Basemap_job.Cancelled
  | exception e -> set t (Basemap_job.Failed (friendly e))

let start_export t ~sw ~fs ~basemap_dir ~id =
  if not (claim t) then Error "a download is already running"
  else begin
    Eio.Fiber.fork ~sw (fun () -> run_export t ~fs ~basemap_dir ~id);
    Ok ()
  end

(* What is sitting in the export directory, so the UI can offer the files
   for saving and say how much disk they are holding. Listed from the
   directory rather than remembered in the job: exports outlive the run that
   made them, which is the point -- a user collects several over an evening
   and copies them all to a stick at the end. *)
let exports_json ~fs ~basemap_dir =
  let dir = Eio.Path.(fs / basemap_dir / export_dir_name) in
  let names =
    match Eio.Path.read_dir dir with
    | names -> List.sort String.compare names
    | exception _ -> []
  in
  `List
    (List.filter_map
       (fun name ->
         if not (Filename.check_suffix name ".pmtiles") then None
         else
           match Eio.Path.stat ~follow:true Eio.Path.(dir / name) with
           | stat when stat.Eio.File.Stat.kind = `Regular_file ->
               Some
                 (`Assoc
                    [
                      ("file", `String name);
                      ( "bytes",
                        `Int (Optint.Int63.to_int stat.Eio.File.Stat.size) );
                    ])
           | _ -> None
           | exception _ -> None)
       names)

(* Deleting one export. The name is checked against the directory listing
   rather than trusted: it arrives from a request, and a name is the one
   thing here that could reach outside the export directory if it held a
   separator. *)
let delete_export ~fs ~basemap_dir ~file =
  let dir = Eio.Path.(fs / basemap_dir / export_dir_name) in
  let listed =
    match Eio.Path.read_dir dir with names -> names | exception _ -> []
  in
  if not (List.mem file listed) then Error "no such export"
  else
    match Eio.Path.unlink Eio.Path.(dir / file) with
    | () -> Ok ()
    | exception e -> Error (friendly e)

(* ----------------------------------------------------------------- import *)

(* Taking a map file someone carried here on a stick and folding it in.

   The trick is that this is not a new kind of download -- it is the ordinary
   one with a different source. [Pmtiles_source.open_url] already falls
   through to a plain file for anything that is not an http URL, and
   [run_download] already merges from whatever source it is handed. So an
   import is: receive the bytes, then run the download that was always
   there, pointed at the file instead of at a planet build on the internet.

   Everything downstream therefore comes free and stays identical to a
   networked download -- the merge that keeps what is already on disk, the
   ledger entry, the browse-cache prune, the search index rebuild. There is
   no second code path to keep in step, which matters more here than
   anywhere: the machine doing this is the one with no way to fetch a fix.

   Two steps, not one. The bytes land first and are described back to the
   user -- what regions, how deep, how big -- and only then does a second
   request commit them. A multi-gigabyte file that turns out to be the wrong
   country should cost a glance, not a merge. *)

let import_dir_name = "import"
let staged_file = "staged.pmtiles"
let staged_path ~fs ~basemap_dir = Eio.Path.(fs / basemap_dir / import_dir_name / staged_file)

(* Where the staged file lives, as the string [run_download] wants for a
   source. Built from the same pieces as the path above so the two cannot
   drift apart. *)
let staged_source ~basemap_dir =
  List.fold_left Filename.concat basemap_dir [ import_dir_name; staged_file ]

(* Receiving the upload. Streamed straight to disk under a .part name: the
   file is the size of a country and must never be held in memory, and a
   dropped connection must not leave something that looks like a finished
   import.

   [expected] is what Content-Length promised. A body that stops short is
   refused rather than kept, because a truncated PMTiles archive answers
   every directory lookup and fails half its reads -- it would import
   cleanly and then draw holes. *)
let receive_import ~fs ~basemap_dir ~expected ~src =
  let dir = Eio.Path.(fs / basemap_dir / import_dir_name) in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 dir;
  let part = Eio.Path.(dir / (staged_file ^ ".part")) in
  let discard () = try Eio.Path.unlink part with _ -> () in
  match
    let received = ref 0 in
    Eio.Path.with_open_out ~create:(`Or_truncate 0o644) part (fun out ->
        let buf = Cstruct.create (1 lsl 20) in
        let rec pump () =
          match Eio.Flow.single_read src buf with
          | 0 -> ()
          | n ->
              Eio.Flow.copy_string (Cstruct.to_string (Cstruct.sub buf 0 n)) out;
              received := !received + n;
              pump ()
          | exception End_of_file -> ()
        in
        pump ());
    !received
  with
  | received when received <> expected ->
      discard ();
      Error
        (Printf.sprintf
           "the upload stopped early: %d bytes arrived of the %d it declared"
           received expected)
  | _ -> (
      (* Whether it is a map at all, decided before it is published under a
         name the commit will trust. *)
      match
        Eio.Switch.run @@ fun sw ->
        let file = Eio.Path.open_in ~sw part in
        Pmtiles.Archive.open_ (Pmtiles_source.file_source file)
      with
      | _archive ->
          Eio.Path.rename part (staged_path ~fs ~basemap_dir);
          Ok ()
      | exception _ ->
          discard ();
          Error "that file is not a PMTiles map archive")
  | exception e ->
      discard ();
      Error (friendly e)

(* What is sitting staged, described from the file itself.

   The regions come out of the exported archive's own ledger, which is what
   makes the far side of the trip need no typing: the file says which places
   it holds, how deep, and what it was called. A file from somewhere else --
   any valid PMTiles archive -- has no ledger, and is described by its header
   instead, as one box at whatever depth it reaches. *)
let import_summary ~fs ~basemap_dir =
  match
    Eio.Switch.run @@ fun sw ->
    let path = staged_path ~fs ~basemap_dir in
    let stat = Eio.Path.stat ~follow:true path in
    let file = Eio.Path.open_in ~sw path in
    let archive = Pmtiles.Archive.open_ (Pmtiles_source.file_source file) in
    let h = archive.Pmtiles.Archive.header in
    let entries =
      match Ledger.of_metadata (Pmtiles.Archive.metadata archive) with
      | Ok l -> l
      | Error _ -> []
    in
    (stat, h, entries)
  with
  | stat, h, entries ->
      let e7f v = float_of_int v /. 1e7 in
      let named =
        match entries with
        | [] -> None
        | e :: _ -> Some e.Ledger.name
      in
      let regions =
        match entries with
        | [] ->
            [
              `Assoc
                [
                  ("min_lon", `Float (e7f h.Pmtiles.Header.min_lon_e7));
                  ("min_lat", `Float (e7f h.Pmtiles.Header.min_lat_e7));
                  ("max_lon", `Float (e7f h.Pmtiles.Header.max_lon_e7));
                  ("max_lat", `Float (e7f h.Pmtiles.Header.max_lat_e7));
                  ("max_zoom", `Int h.Pmtiles.Header.max_zoom);
                ];
            ]
        | l -> List.concat_map (fun e -> List.map Ledger.json_of_region e.Ledger.regions) l
      in
      Ok
        (`Assoc
           [
             ("staged", `Bool true);
             ( "name",
               match named with Some n -> `String n | None -> `Null );
             ("bytes", `Int (Optint.Int63.to_int stat.Eio.File.Stat.size));
             ("min_zoom", `Int h.Pmtiles.Header.min_zoom);
             ("max_zoom", `Int h.Pmtiles.Header.max_zoom);
             ("tiles", `Int h.Pmtiles.Header.addressed_tiles);
             ("regions", `List regions);
           ])
  | exception _ -> Ok (`Assoc [ ("staged", `Bool false) ])

let discard_import ~fs ~basemap_dir =
  (try Eio.Path.unlink (staged_path ~fs ~basemap_dir) with _ -> ());
  Ok ()

(* Merging what was staged. The regions and their names come from the staged
   file's ledger, so an imported region lands in this machine's ledger under
   the name it was exported as -- listed, updatable and removable exactly
   like one that was downloaded here. *)
let start_import t ~sw ~fs ~net ~basemap_dir ~budget ~now =
  if not (claim t) then Error "a download is already running"
  else begin
    Eio.Fiber.fork ~sw (fun () ->
        match
          Eio.Switch.run @@ fun usw ->
          let path = staged_path ~fs ~basemap_dir in
          let file = Eio.Path.open_in ~sw:usw path in
          let archive = Pmtiles.Archive.open_ (Pmtiles_source.file_source file) in
          let h = archive.Pmtiles.Archive.header in
          let entries =
            match Ledger.of_metadata (Pmtiles.Archive.metadata archive) with
            | Ok l -> l
            | Error m -> failwith m
          in
          let e7f v = float_of_int v /. 1e7 in
          match entries with
          | [] ->
              (* No ledger: an archive from somewhere else, whose origin
                 nobody recorded. Left blank rather than invented. *)
              (* No ledger: an archive from somewhere else. Its header box at
                 its own depth is the honest description of what it holds. *)
              let r =
                {
                  Basemap_job.min_lon = e7f h.Pmtiles.Header.min_lon_e7;
                  min_lat = e7f h.Pmtiles.Header.min_lat_e7;
                  max_lon = e7f h.Pmtiles.Header.max_lon_e7;
                  max_lat = e7f h.Pmtiles.Header.max_lat_e7;
                  max_zoom = h.Pmtiles.Header.max_zoom;
                  polygon = None;
                }
              in
              (None, [ r ], [ "" ], "")
          | l ->
              let name = (List.hd l).Ledger.name in
              let regions = List.concat_map (fun e -> e.Ledger.regions) l in
              ( Some name,
                regions,
                List.map (fun _ -> name) regions,
                (List.hd l).Ledger.source )
        with
        | name, regions, labels, origin ->
            run_download t ~fs ~net ~source:(staged_source ~basemap_dir)
              ~origin
              (* No glyph fetch: see [fetch_assets]. *)
              ~assets:"" ~basemap_dir ~budget ~name ~now ~refresh:false
              ~replaces:None ~target:Detail ~labels:(Some labels) regions;
            (* The staged file has done its job either way. Left behind it is
               a second copy of a country sitting in the user's data
               directory, which on the machine most likely to be short of
               disk is the last thing to leave lying around. *)
            (try Eio.Path.unlink (staged_path ~fs ~basemap_dir) with _ -> ())
        | exception e -> set t (Basemap_job.Failed (friendly e)));
    Ok ()
  end

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
    | Some _ when t.clear_requested ->
        (* Asked for between the fork and here: erase rather than fold, or
           the browsed tiles become permanent residents of the archive that
           no later erasing can reach. *)
        honor_clear t ~fs ~basemap_dir
    | Some cache ->
        let base = open_base ~sw ~fs ~basemap_dir in
        (* The fold stamps the cache's header over blobs copied verbatim
           from BOTH files. A compression mismatch -- the source changed
           schemes after the main archive was downloaded -- would relabel
           every pre-existing tile as something it is not, corrupting the
           whole archive in one silent rename. Refuse loudly instead. *)
        guard_compression ~h:cache.Pmtiles.Archive.header base;
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
            let copy ~index:_ ~origin ~offset ~length =
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
        (* The merged archive lands FIRST, and only then does the cache go.
           Do not swap these. A crash in this window leaves a cache holding
           tiles byte-identical to ones map.pmtiles now also holds: the
           endpoint serves the same bytes from either, the TileJSON folds
           to the same ranges, and the next browse past the threshold folds
           again and completes the unlink -- it self-heals, and costs
           nothing meanwhile. Unlinking first instead means a crash, or
           merely a failing rename, destroys every browsed tile while
           map.pmtiles is still the pre-fold archive. *)
        Eio.Path.rename part_path Eio.Path.(dir / "map.pmtiles");
        (* The fold is published; the leftover cache is the benign duplicate
           argued for above, so failing to remove it must not be reported as
           a failed compaction. *)
        (try Eio.Path.unlink Eio.Path.(dir / "cache.pmtiles") with _ -> ());
        (* Browsed tiles carry labels too, and they have just become part of
           the archive: without this, a place the user browsed to is on the
           map but not findable. *)
        (try reindex t ~fs ~basemap_dir with
        | Cancelled_by_user -> ()
        | e ->
            Logs.warn (fun m ->
                m "search index build failed: %s" (Printexc.to_string e)))
  with
  | () ->
      honor_clear t ~fs ~basemap_dir;
      set t Basemap_job.Idle
  | exception Cancelled_by_user ->
      discard_part ();
      honor_clear t ~fs ~basemap_dir;
      set t Basemap_job.Cancelled
  | exception e ->
      discard_part ();
      honor_clear t ~fs ~basemap_dir;
      set t (Basemap_job.Failed (friendly e))

(* One viewport's missing tiles, fetched into the cache. Opt-in (gated in
   the handler on the browse_cache setting), quiet, and bounded: a request
   naming too many tiles is refused rather than becoming a download in
   disguise -- the card is the place for those. *)
let max_browse_tiles = 1_024

(* The depth a browse can actually be served at: the view asks, the source
   decides. Named and separate because the answer travels back to the
   client, which compares it against the depth its map is showing -- a
   client that mistook its own request for what arrived would ask for a
   zoom the source cannot reach, forever. *)
let browse_zoom ~header ~requested =
  max header.Pmtiles.Header.min_zoom
    (min requested header.Pmtiles.Header.max_zoom)

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
        release_browsing t;
        (* This fiber wrote the cache; it is the one that must erase it if
           the user switched browsing off while it was in flight. *)
        honor_clear t ~fs ~basemap_dir)
      (fun () ->
        match
          Eio.Switch.run @@ fun bsw ->
          let _resolved, src, archive = open_source ~sw:bsw ~fs ~net ~source in
          let h = archive.Pmtiles.Archive.header in
          let zoom = browse_zoom ~header:h ~requested:req.max_zoom in
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
            (* Same refusal as a download's: a source whose compression no
               longer matches what is on disk must not write a single blob.
               The cache matters as much as the main archive here -- its
               header is what compaction later stamps over everything. *)
            guard_compression ~h main;
            guard_compression ~h cache;
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
            if Array.length wanted = 0 then (0, zoom)
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
                  let copy ~index:_ ~origin ~offset ~length =
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
              (mp.Pmtiles.Merge.fresh_tiles, zoom)
            end
          end
        with
        | (fetched, written_zoom) ->
            (* Fold the cache into the main archive once it outgrows the
               threshold -- unless a download holds the writer's seat, in
               which case a later browse will try again. Failures here stay
               here: a broken look at the cache must not fail the browse
               that already succeeded, and it must not escape as a dropped
               connection either. *)
            (if fetched > 0 && not t.clear_requested then
               try
                 Eio.Switch.run @@ fun csw ->
                 match open_cache ~sw:csw ~fs ~basemap_dir with
                 | Some c
                   when c.Pmtiles.Archive.header.Pmtiles.Header.data_length
                        > budget.compact ->
                     if claim t then
                       Eio.Fiber.fork ~sw (fun () ->
                           run_compact t ~fs ~basemap_dir)
                 | _ -> ()
               with
               | Eio.Cancel.Cancelled _ as e -> raise e
               | e ->
                 Logs.warn (fun m ->
                     m "compaction check failed: %s" (Printexc.to_string e)));
            Ok (fetched, written_zoom)
        | exception (Eio.Cancel.Cancelled _ as e) -> raise e
        | exception e ->
            (* The .part is dead weight the moment its browse dies; the
               file is also reachable under /basemap/, so litter is not
               merely untidy. *)
            (try
               Eio.Path.unlink Eio.Path.(fs / basemap_dir / "cache.pmtiles.part")
             with _ -> ());
            Error (friendly e))

(* Turning the browse setting off also forgets what was browsed: the cache
   is a record of the places the user looked at, and in a privacy-focused
   tool "off" should mean gone, not dormant. Tiles already folded into the
   main archive are past helping -- the hint text says as much.

   Never waits. The obvious spelling -- block until the in-flight browse
   finishes, then delete -- puts an unbounded network wait on a request the
   user is watching: a stalled upstream read would hang the settings
   response until the browser gave up, and the toggle would snap back to
   "on" over a setting the server had already saved. So a busy cache is
   marked instead, and whoever holds it erases it as it leaves. *)
let clear_cache t ~fs ~basemap_dir =
  if t.browsing || Basemap_job.is_running t.job then t.clear_requested <- true
  else unlink_cache ~fs ~basemap_dir

(* ------------------------------------------------------------- lifecycle *)

(* The overview covers the planet or it is not one.

   Checked rather than trusted because the client says which kind of download
   this is, and a half-planet written to world.pmtiles would be a file whose
   name is a lie -- the floor measurement would still be honest, since it
   counts tiles rather than reading the name, but every later reader of that
   file would be wrong about it. The world offer sends exactly this box. *)
let covers_the_planet (reqs : Basemap_job.request list) =
  match reqs with
  | [ r ] ->
      r.Basemap_job.min_lon <= -180. && r.Basemap_job.max_lon >= 180.
      && r.Basemap_job.min_lat <= -85. && r.Basemap_job.max_lat >= 85.
  | _ -> false

let start t ~sw ~fs ~net ~source ~assets ~basemap_dir ~budget ~name ~labels
    ~world ~now reqs =
  let target = if world then World else Detail in
  if world && not (covers_the_planet reqs) then
    Error "a world overview has to cover the whole world"
  else if not (claim t) then Error "a download is already running"
  else begin
    Eio.Fiber.fork ~sw (fun () ->
        run_download t ~fs ~net ~source ~assets ~basemap_dir ~budget ~name ~now
          ~refresh:false ~replaces:None ~target ~labels reqs);
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
            (* Updates come from ledger entries, and only the detail
               archive has one. *)
            run_download t ~fs ~net ~source ~assets ~basemap_dir ~budget
              ~name:(Some e.Ledger.name) ~now ~refresh:true ~replaces:(Some id)
              ~target:Detail
              (* Every box in a recorded entry was downloaded under one name,
                 so they all carry it: an update of "France and Germany"
                 draws the rows it was saved as, not two anonymous boxes. *)
              ~labels:
                (Some (List.map (fun _ -> e.Ledger.name) e.Ledger.regions))
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
        (* Whether there is a map on disk at all, which is NOT whether the
           ledger has entries. A world overview fetched with the extraction
           tool writes no entry and is still a drawn, labelled planet, and
           the setup docs make fetching one step 1 -- so a banner reading
           "no basemap found" over it would be contradicting the map behind
           it. Answered here rather than by the page probing for files,
           because a probe for one that is absent is a 404 in the console on
           a supported configuration. *)
        ( "held",
          `Bool
            (List.exists
               (fun name ->
                 match Eio.Path.kind ~follow:true Eio.Path.(fs / basemap_dir / name) with
                 | `Regular_file -> true
                 | _ -> false)
               [ base_file; world_file ]) );
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

(* ------------------------------------------------------------- coverage *)

(* Where the map goes blank, and how deep it goes where it does not.

   One question about one viewport: which of its tiles this server can
   actually serve, answered with a directory lookup each and no tile bytes
   read at all. The map draws whatever the tile endpoint returns, so this
   asks the same archives in the same order -- browse cache first, then the
   main one -- rather than reading the ledger. The ledger is a different
   thing: it records what was ASKED for. An archive seeded by the
   extraction tool holds tiles no entry claims, browsed tiles belong to no
   entry at all, and a mask drawn from the ledger would grey out places the
   user can plainly see drawn -- which is worse than saying nothing, the
   state this replaces.

   Bounded by construction: a viewport is a few dozen tiles at its own
   zoom, and a query for more than [max_coverage_tiles] is refused rather
   than answered slowly. *)

let max_coverage_tiles = 4096

(* The deepest zoom the DOWNLOADED archives reach, and [None] when there
   are none of them at all.

   Separate from the floor's depth, which is about the overview underneath.
   This one answers "how deep does detail go", and it is the question the
   coverage clamp below needs. *)
let detail_depth ~sw ~fs ~basemap_dir =
  match List.filter_map (open_readable ~sw ~fs ~basemap_dir) detail_files with
  | [] -> None
  | archives ->
      Some
        (List.fold_left
           (fun acc (a : Pmtiles.Archive.t) ->
             max acc a.Pmtiles.Archive.header.Pmtiles.Header.max_zoom)
           0 archives)

let coverage ~fs ~basemap_dir (req : Basemap_job.request) =
  (* The zoom the map is DISPLAYING, carried in [max_zoom] because that is
     the field a validated request has; nothing here downloads.

     Clamped HERE rather than by the client, and that is the whole of this
     fix. Past a source's own depth MapLibre stops asking for more and
     overzooms the deepest tiles it has, so a query at the camera zoom
     would report a blank that is not on screen -- the clamp is real and
     has to happen somewhere. It used to happen in the browser, against the
     depth `/tiles.json` advertised, which forced that number to lie: an
     archive with no detail in it had to claim depth 15 or the clamp
     dragged every question down to the floor's zoom, where the overview
     answers "present" and the offer to download this area never appears.
     One number cannot both tell MapLibre what to request and tell this
     query what to ask about.

     So the client sends the zoom it is really looking at, and the answer
     is clamped against the archives that actually hold detail. With none
     of them the camera zoom stands, which is the honest reading: there is
     no detail at any zoom, and the note that says so is exactly what a
     fresh install needs to see. *)
  let z =
    match
      Eio.Switch.run (fun sw -> detail_depth ~sw ~fs ~basemap_dir)
    with
    | Some deepest -> min req.max_zoom deepest
    | None -> req.max_zoom
    | exception _ -> req.max_zoom
  in
  let last = (1 lsl z) - 1 in
  let grid v = max 0 (min last v) in
  (* The same floor arithmetic [Tile_id.covering] plans with, so a cell
     means the tile the map will ask for rather than its neighbour. *)
  let x0 = grid (Pmtiles.Tile_id.tile_x ~z ~lon:req.min_lon)
  and x1 = grid (Pmtiles.Tile_id.tile_x ~z ~lon:req.max_lon)
  and y0 = grid (Pmtiles.Tile_id.tile_y ~z ~lat:req.max_lat)
  and y1 = grid (Pmtiles.Tile_id.tile_y ~z ~lat:req.min_lat) in
  let w = x1 - x0 + 1 and h = y1 - y0 + 1 in
  if w * h > max_coverage_tiles then
    Error
      (Too_large
         (Printf.sprintf "a coverage query covers at most %d tiles"
            max_coverage_tiles))
  else
    match
      Eio.Switch.run @@ fun sw ->
      (* The tile endpoint's own list, in its own order -- though an
         existence test cannot tell the difference. What makes this agree
         with what the map is served is not the order but that
         [Archive.tile] IS [locate] followed by a read: the same directory
         walk, the same run-length entries, the same nested leaves.

         The world floor counts. It is a real tile the map really draws, so
         calling it absent would wash a drawn map grey and offer a download
         for something already on screen. *)
      let archives =
        List.filter_map (open_readable ~sw ~fs ~basemap_dir) tile_files
      in
      let held ~z ~x ~y =
        let id = Pmtiles.Tile_id.of_zxy ~z ~x ~y in
        List.exists (fun a -> Pmtiles.Archive.locate a id <> None) archives
      in
      (* Row-major from the north-west corner, one character per tile: the
         client draws rectangles from it, and a string survives a JSON
         round trip without a base64 step on either side. *)
      let present = Buffer.create (w * h) in
      for y = y0 to y1 do
        for x = x0 to x1 do
          Buffer.add_char present (if held ~z ~x ~y then '1' else '0')
        done
      done;
      (* How deep the archive goes under the middle of the view.

         Measured at the centre of the middle CELL of the rectangle above,
         not at the midpoint of the requested degrees. Those are different
         tiles surprisingly often -- Mercator is not linear in latitude and
         the viewport's edges fall at arbitrary points inside their tiles --
         and when they disagreed, the client could be told the middle of
         its view was blank while the depth described the tile next door.
         The descent starts at the zoom asked about rather than at the
         archive's own depth, which makes the answer an exact statement
         about the middle cell: depth = zoom means that cell is held, and
         anything less means it is not, with the number saying how far out
         the map still has something. Starting deeper would let a partial
         archive report a depth ABOVE a zoom it has no tile at, and the
         client would then have a blank middle and a depth denying it. *)
      let cx = x0 + (w / 2) and cy = y0 + (h / 2) in
      let cl, cb, cr, ct = Pmtiles.Tile_id.tile_box ~z ~x:cx ~y:cy in
      let lon = (cl +. cr) /. 2. and lat = (cb +. ct) /. 2. in
      let rec depth_at zd =
        if zd < 0 then -1
        else
          let n = (1 lsl zd) - 1 in
          let clamp v = max 0 (min n v) in
          if
            held ~z:zd
              ~x:(clamp (Pmtiles.Tile_id.tile_x ~z:zd ~lon))
              ~y:(clamp (Pmtiles.Tile_id.tile_y ~z:zd ~lat))
          then zd
          else depth_at (zd - 1)
      in
      (* Whether the map underneath draws here at all, which is NOT what
         [depth] says.

         A one-city archive holds the single zoom-0 tile of the whole
         planet, so its depth over Tokyo is 0 -- and whether anything is
         drawn there depends on the floor covering the planet at that zoom,
         which is a fact about the whole archive rather than about this
         view. Told only the depth, the client would promise "this is the
         wider map" over ground with no wider map on it. *)
      let floor_here =
        floor_depth (whole_archives ~sw ~fs ~basemap_dir tile_files) >= 0
      in
      `Assoc
        [
          ("zoom", `Int z);
          ("x", `Int x0);
          ("y", `Int y0);
          ("w", `Int w);
          ("h", `Int h);
          ("present", `String (Buffer.contents present));
          ("floor", `Bool floor_here);
          ("depth", `Int (depth_at z));
        ]
    with
    | json -> Ok json
    | exception e -> Error (Unreadable (friendly e))

let ops t ~sw ~fs ~net ~source ~assets ~basemap_dir ~budget ~now =
  {
    estimate =
      (fun ~world reqs ->
        estimate ~fs ~net ~source ~basemap_dir ~budget ~world reqs);
    start =
      (fun ~name ~labels ~world reqs ->
        start t ~sw ~fs ~net ~source ~assets ~basemap_dir ~budget ~name ~labels
          ~world ~now reqs);
    cancel = (fun () -> cancel t);
    status = (fun () -> status t);
    ledger = (fun () -> ledger_json ~fs ~basemap_dir);
    update =
      (fun ~id ->
        start_update t ~sw ~fs ~net ~source ~assets ~basemap_dir ~budget ~now
          ~id);
    remove = (fun ~id -> start_remove t ~sw ~fs ~basemap_dir ~id);
    export = (fun ~id -> start_export t ~sw ~fs ~basemap_dir ~id);
    exports = (fun () -> exports_json ~fs ~basemap_dir);
    delete_export = (fun ~file -> delete_export ~fs ~basemap_dir ~file);
    staged =
      (fun () ->
        match import_summary ~fs ~basemap_dir with
        | Ok j -> j
        | Error _ -> `Assoc [ ("staged", `Bool false) ]);
    import = (fun () -> start_import t ~sw ~fs ~net ~basemap_dir ~budget ~now);
    discard_import = (fun () -> discard_import ~fs ~basemap_dir);
    browse =
      (fun req -> run_browse t ~sw ~fs ~net ~source ~basemap_dir ~budget req);
    clear_cache = (fun () -> clear_cache t ~fs ~basemap_dir);
    coverage = (fun req -> coverage ~fs ~basemap_dir req);
    search =
      (fun ~query ~limit ->
        match Place_index.search ~fs ~basemap_dir ~query ~limit with
        | results -> Ok (Place_index.to_json results)
        | exception e -> Error (friendly e));
  }
