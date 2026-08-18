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
}

(* What the request handler sees: four closures, so the handler can be tested
   with pure fakes and never needs the switch, the network or the clock. *)
type ops = {
  estimate : Basemap_job.request list -> (Yojson.Safe.t, string) result;
  start : Basemap_job.request list -> (unit, string) result;
  cancel : unit -> bool;
  status : unit -> Yojson.Safe.t;
}

let create () =
  {
    mutex = Eio.Mutex.create ();
    job = Basemap_job.Idle;
    generation = 0;
    cancel_requested = false;
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

(* Exceptions out of Eio and cohttp arrive as their printed form; Failure
   carries the messages this codebase writes for humans. *)
let friendly = function Failure m -> m | e -> Printexc.to_string e

(* ------------------------------------------------------------------ plan *)

(* How deep a download goes. An explicit ask that plans within [full_limit]
   tile ids gets its full depth -- whole-France street level is ~2.2 million
   ids and qualifies, as does every US state. A box beyond that (Brazil, a
   whole-world viewport) falls back to a quick [quick_limit] regional plan
   and the UI says to pick a state; without the ceiling, half a continent at
   street level meant planning tens of millions of ids -- minutes of
   grinding and memory to match. *)
let full_limit = 6_000_000
let quick_limit = 131_072

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

let plan_regions ?cancel ~sw ~fs ~net ~source
    (reqs : Basemap_job.request list) =
  let src = Pmtiles_source.open_url ~sw ~fs ~net source in
  let archive = Pmtiles.Archive.open_ src in
  let h = archive.Pmtiles.Archive.header in
  (* All zooms from the top: the world-context tiles are a rounding error next
     to the deep ones and are what keeps zooming out from hitting blank. *)
  let min_zoom = h.Pmtiles.Header.min_zoom in
  (* Each region is budgeted on its own: one giant pick falls back to
     regional depth without dragging the states picked beside it down. *)
  let planned =
    List.map
      (fun (req : Basemap_job.request) ->
        let max_zoom, _clamped =
          Pmtiles.Tile_id.download_depth ~min_zoom
            ~requested:(min req.max_zoom h.Pmtiles.Header.max_zoom)
            ~min_lon:req.min_lon ~min_lat:req.min_lat ~max_lon:req.max_lon
            ~max_lat:req.max_lat ~full_limit ~quick_limit
        in
        let plan =
          Pmtiles.Extract.plan
            ~on_tile:(breathe ?cancel ())
            archive ~min_zoom ~max_zoom ~min_lon:req.min_lon
            ~min_lat:req.min_lat ~max_lon:req.max_lon ~max_lat:req.max_lat
        in
        (max_zoom, plan))
      reqs
  in
  (src, h, min_zoom, List.map fst planned, List.map snd planned)

(* The archive already on disk, if any -- the merge's base. *)
let open_base ~sw ~fs ~basemap_dir =
  let path = Eio.Path.(fs / basemap_dir / "map.pmtiles") in
  match Eio.Path.kind ~follow:true path with
  | `Regular_file ->
      Some
        (Pmtiles.Archive.open_
           (Pmtiles_source.file_source (Eio.Path.open_in ~sw path)))
  | _ -> None

let merge_plan ?cancel ~sw ~fs ~net ~source ~basemap_dir reqs =
  let src, h, min_zoom, depths, fresh =
    plan_regions ?cancel ~sw ~fs ~net ~source reqs
  in
  let base = open_base ~sw ~fs ~basemap_dir in
  (match base with
  | Some b
    when b.Pmtiles.Archive.header.Pmtiles.Header.tile_compression
         <> h.Pmtiles.Header.tile_compression ->
      failwith
        "the basemap on disk and the tile source disagree on compression; \
         delete the basemap directory and download again"
  | _ -> ());
  ( src,
    h,
    base,
    min_zoom,
    depths,
    Pmtiles.Merge.plan ~on_entry:(breathe ?cancel ()) ~base fresh,
    fresh )

(* The estimate is what the user will actually pay for over the network:
   tiles the base already holds are excluded, so re-asking for an area you
   have says zero rather than re-quoting the full price. [covered] separates
   "you have all of this" from "the source has nothing here". *)
let estimate ~fs ~net ~source ~basemap_dir (reqs : Basemap_job.request list) =
  match
    Eio.Switch.run @@ fun sw ->
    let _, _, _, _, depths, mp, fresh =
      merge_plan ~sw ~fs ~net ~source ~basemap_dir reqs
    in
    ( mp.Pmtiles.Merge.fetch_bytes,
      mp.Pmtiles.Merge.fresh_tiles,
      List.exists
        (fun (f : Pmtiles.Extract.plan) ->
          Array.length f.Pmtiles.Extract.tiles > 0)
        fresh
      && mp.Pmtiles.Merge.fresh_tiles = 0,
      depths )
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
             ( "max_zooms",
               `List (List.map (fun z -> `Int z) depths) );
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

let run_download t ~fs ~net ~source ~assets ~basemap_dir
    (reqs : Basemap_job.request list) =
  let dir = Eio.Path.(fs / basemap_dir) in
  let part = Eio.Path.(dir / "map.pmtiles.part") in
  let discard_part () = try Eio.Path.unlink part with _ -> () in
  match
    Eio.Switch.run @@ fun sw ->
    let src, h, base, min_zoom, depths, mp, _fresh =
      merge_plan ~cancel:t ~sw ~fs ~net ~source ~basemap_dir reqs
    in
    if Array.length mp.Pmtiles.Merge.tiles = 0 then
      failwith "the source has no tiles in that area";
    if mp.Pmtiles.Merge.fresh_tiles = 0 && Option.is_some base then
      failwith "you already have the maps for that area";
    check_cancel t;
    (* Progress counts every byte the merged archive writes, local copies
       included: it is the write that takes the time on a fast link, and a
       bar that ignored the base would sit at 100% while still working. *)
    let total = mp.Pmtiles.Merge.total_bytes in
    set t (Basemap_job.progress ~done_bytes:0 ~total_bytes:total);
    ensure_dir dir;
    (* The merged header describes the union: every requested box and the
       base's, folded together, at the deepest zoom any of them reached. *)
    let e7f v = float_of_int v /. 1e7 in
    let max_zoom = List.fold_left max min_zoom depths in
    let min_lon, min_lat, max_lon, max_lat =
      List.fold_left
        (fun (a, b, c, d) (r : Basemap_job.request) ->
          ( Float.min a r.min_lon,
            Float.min b r.min_lat,
            Float.max c r.max_lon,
            Float.max d r.max_lat ))
        (180., 90., -180., -90.)
        reqs
    in
    let min_zoom, max_zoom, min_lon, min_lat, max_lon, max_lat =
      match base with
      | None -> (min_zoom, max_zoom, min_lon, min_lat, max_lon, max_lat)
      | Some b ->
          let bh = b.Pmtiles.Archive.header in
          ( min min_zoom bh.Pmtiles.Header.min_zoom,
            max max_zoom bh.Pmtiles.Header.max_zoom,
            Float.min min_lon (e7f bh.Pmtiles.Header.min_lon_e7),
            Float.min min_lat (e7f bh.Pmtiles.Header.min_lat_e7),
            Float.max max_lon (e7f bh.Pmtiles.Header.max_lon_e7),
            Float.max max_lat (e7f bh.Pmtiles.Header.max_lat_e7) )
    in
    (* Written under a .part name and renamed only once complete, so the file
       the map reads is never mid-write and a failed download leaves the
       previous basemap untouched. The base is read from the old file while
       the new one is written beside it. *)
    Eio.Path.with_open_out ~create:(`Or_truncate 0o644) part (fun out ->
        let written = ref 0 in
        let append s = Eio.Flow.copy_string s out in
        let copy ~origin ~offset ~length =
          check_cancel t;
          let bytes =
            match origin with
            | Pmtiles.Merge.Base -> (
                match base with
                | Some b -> b.Pmtiles.Archive.src.Pmtiles.Archive.read ~offset ~length
                | None -> assert false (* no Base blobs without a base *))
            | Pmtiles.Merge.Fresh -> src.Pmtiles.Archive.read ~offset ~length
          in
          Eio.Flow.copy_string bytes out;
          written := !written + length;
          set t (Basemap_job.progress ~done_bytes:!written ~total_bytes:total)
        in
        ignore
          (Pmtiles.Merge.write mp h ~min_zoom ~max_zoom ~min_lon ~min_lat
             ~max_lon ~max_lat ~append ~copy));
    Eio.Path.rename part Eio.Path.(dir / "map.pmtiles");
    fetch_assets t ~sw ~net ~assets ~dir;
    total
  with
  | total -> set t (Basemap_job.Done { total_bytes = total })
  | exception Cancelled_by_user ->
      discard_part ();
      set t Basemap_job.Cancelled
  | exception e ->
      discard_part ();
      set t (Basemap_job.Failed (friendly e))

let start t ~sw ~fs ~net ~source ~assets ~basemap_dir reqs =
  let claimed =
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
  in
  if not claimed then Error "a download is already running"
  else begin
    Eio.Fiber.fork ~sw (fun () ->
        run_download t ~fs ~net ~source ~assets ~basemap_dir reqs);
    Ok ()
  end

let ops t ~sw ~fs ~net ~source ~assets ~basemap_dir =
  {
    estimate = (fun req -> estimate ~fs ~net ~source ~basemap_dir req);
    start = (fun req -> start t ~sw ~fs ~net ~source ~assets ~basemap_dir req);
    cancel = (fun () -> cancel t);
    status = (fun () -> status t);
  }
