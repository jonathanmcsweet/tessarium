(* The effectful side of the in-app basemap download.

   Every decision -- may a download start, is this box valid, what does
   progress look like -- is [Basemap_job]'s and is tested there. This module
   owns what cannot be pure: the fiber, the socket, the .part file, and the
   mutex around the one shared job cell.

   The tile source and assets URL are the server's configuration, never the
   client's. A request body names a region of the world; it does not name a
   place on the internet to fetch from. *)

type t = {
  mutex : Eio.Mutex.t;
  mutable job : Basemap_job.t;
  mutable cancel_requested : bool;
}

(* What the request handler sees: four closures, so the handler can be tested
   with pure fakes and never needs the switch, the network or the clock. *)
type ops = {
  estimate : Basemap_job.request -> (Yojson.Safe.t, string) result;
  start : Basemap_job.request -> (unit, string) result;
  cancel : unit -> bool;
  status : unit -> Yojson.Safe.t;
}

let create () =
  { mutex = Eio.Mutex.create (); job = Basemap_job.Idle; cancel_requested = false }

let set t job = Eio.Mutex.use_rw ~protect:true t.mutex (fun () -> t.job <- job)

let status t = Basemap_job.to_json (Eio.Mutex.use_ro t.mutex (fun () -> t.job))

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

let plan_region ~sw ~fs ~net ~source (req : Basemap_job.request) =
  let src = Pmtiles_source.open_url ~sw ~fs ~net source in
  let archive = Pmtiles.Archive.open_ src in
  let h = archive.Pmtiles.Archive.header in
  (* All zooms from the top: the world-context tiles are a rounding error next
     to the deep ones and are what keeps zooming out from hitting blank. *)
  let min_zoom = h.Pmtiles.Header.min_zoom in
  let max_zoom = min req.max_zoom h.Pmtiles.Header.max_zoom in
  let plan =
    Pmtiles.Extract.plan archive ~min_zoom ~max_zoom ~min_lon:req.min_lon
      ~min_lat:req.min_lat ~max_lon:req.max_lon ~max_lat:req.max_lat
  in
  (src, h, min_zoom, max_zoom, plan)

let estimate ~fs ~net ~source (req : Basemap_job.request) =
  match
    Eio.Switch.run @@ fun sw ->
    let _, _, _, _, plan = plan_region ~sw ~fs ~net ~source req in
    ( Pmtiles.Extract.planned_bytes plan,
      Array.length plan.Pmtiles.Extract.tiles )
  with
  | total_bytes, tiles ->
      Ok (`Assoc [ ("total_bytes", `Int total_bytes); ("tiles", `Int tiles) ])
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

let run_download t ~fs ~net ~source ~assets ~basemap_dir (req : Basemap_job.request) =
  let dir = Eio.Path.(fs / basemap_dir) in
  let part = Eio.Path.(dir / "map.pmtiles.part") in
  let discard_part () = try Eio.Path.unlink part with _ -> () in
  match
    Eio.Switch.run @@ fun sw ->
    let src, h, min_zoom, max_zoom, plan =
      plan_region ~sw ~fs ~net ~source req
    in
    let total = Pmtiles.Extract.planned_bytes plan in
    if Array.length plan.Pmtiles.Extract.tiles = 0 then
      failwith "the source has no tiles in that area";
    check_cancel t;
    set t (Basemap_job.progress ~done_bytes:0 ~total_bytes:total);
    ensure_dir dir;
    (* Written under a .part name and renamed only once complete, so the file
       the map reads is never mid-write and a failed download leaves the
       previous basemap untouched. *)
    Eio.Path.with_open_out ~create:(`Or_truncate 0o644) part (fun out ->
        let written = ref 0 in
        let append s = Eio.Flow.copy_string s out in
        let copy ~offset ~length =
          check_cancel t;
          Eio.Flow.copy_string (src.Pmtiles.Archive.read ~offset ~length) out;
          written := !written + length;
          set t (Basemap_job.progress ~done_bytes:!written ~total_bytes:total)
        in
        ignore
          (Pmtiles.Extract.write plan h ~min_zoom ~max_zoom
             ~min_lon:req.min_lon ~min_lat:req.min_lat ~max_lon:req.max_lon
             ~max_lat:req.max_lat ~append ~copy));
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

let start t ~sw ~fs ~net ~source ~assets ~basemap_dir req =
  let claimed =
    (* Claiming the job and checking it are one critical section; two requests
       arriving together must not both see a resting state. *)
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        if Basemap_job.can_start t.job then begin
          t.job <- Basemap_job.Planning;
          t.cancel_requested <- false;
          true
        end
        else false)
  in
  if not claimed then Error "a download is already running"
  else begin
    Eio.Fiber.fork ~sw (fun () ->
        run_download t ~fs ~net ~source ~assets ~basemap_dir req);
    Ok ()
  end

let ops t ~sw ~fs ~net ~source ~assets ~basemap_dir =
  {
    estimate = (fun req -> estimate ~fs ~net ~source req);
    start = (fun req -> start t ~sw ~fs ~net ~source ~assets ~basemap_dir req);
    cancel = (fun () -> cancel t);
    status = (fun () -> status t);
  }
