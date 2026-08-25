(* The map a package ships, and how it reaches the directory the app writes.

   A map application that opens on a blank planet is not one, so every
   package carries a world overview, the glyphs its labels are drawn from
   and the sprites its icons come from. What a package cannot carry is
   somewhere to put them: the payload is installed under a prefix the user
   cannot write to, and everything downstream of it -- downloads, merges,
   the browse cache, the ledger -- assumes one writable directory holding
   every archive.

   So the bundle is copied into that directory the first time it is found
   missing, and from then on it is ordinary user data: a deeper world
   overview fetched in the app replaces the shipped one, regions land
   beside it, and removing a region cannot take the floor away.

   Copying rather than reading the bundle where it lies, which was the other
   way to do this. A second read-only root would have to be threaded through
   the tile lookup, the floor measurement, the coverage query and the static
   file route, and each of those is a place where "which archive answered"
   is load-bearing. A copy costs the user 21 MB once and leaves every one of
   those paths exactly as it was.

   Three rules, each a bug if broken:

   - Never overwrite. An entry already in the target belongs to the user,
     and a world overview they fetched at depth must survive restarts.
   - Whole or not at all. Each entry is built under a temporary name and
     renamed into place, so an interrupted first run leaves it missing --
     to be seeded again next time -- rather than a font directory holding
     half its glyphs, which draws as labels that are absent for no visible
     reason.
   - Quiet when there is nothing to do. A source build has no bundle and a
     second run has nothing to seed. Neither is news. *)

(* What a bundle holds. Named here rather than discovered by listing the
   directory: a bundle is a thing this project builds, and copying whatever
   happens to be in it would make an accident in a packaging script into a
   write to the user's map directory. *)
let entries = [ "world.pmtiles"; "fonts"; "sprites" ]

(* Suffix for a half-copied entry. Inside the target directory, so the
   rename that publishes it stays within one filesystem and is therefore
   atomic; a temporary directory elsewhere could land on another mount and
   turn the rename into a copy that can tear. *)
let pending name = name ^ ".seeding"

let default_dir () =
  let bin = Filename.dirname Sys.executable_name in
  let prefix = Filename.dirname bin in
  List.fold_left Filename.concat prefix [ "share"; "tessarium"; "basemap" ]

let is_dir path =
  match Eio.Path.kind ~follow:true path with `Directory -> true | _ -> false

let exists path = Eio.Path.kind ~follow:true path <> `Not_found

(* Depth-first, and only the two kinds a bundle can hold. Anything else --
   a symlink out of the tree, a socket left behind by something else -- is
   skipped rather than followed: this runs against a directory the packager
   assembled, and following a link out of it would copy something nobody
   chose to ship. *)
let rec copy_tree ~src ~dst =
  match Eio.Path.kind ~follow:false src with
  | `Directory ->
      Eio.Path.mkdir ~perm:0o755 dst;
      List.iter
        (fun name ->
          copy_tree ~src:Eio.Path.(src / name) ~dst:Eio.Path.(dst / name))
        (List.sort String.compare (Eio.Path.read_dir src))
  | `Regular_file ->
      Eio.Switch.run @@ fun sw ->
      let from = Eio.Path.open_in ~sw src in
      let into = Eio.Path.open_out ~sw ~create:(`Exclusive 0o644) dst in
      Eio.Flow.copy from into
  | _ -> ()

let seed_entry ~src_root ~dst_root name =
  let src = Eio.Path.(src_root / name) in
  let dst = Eio.Path.(dst_root / name) in
  let tmp = Eio.Path.(dst_root / pending name) in
  (* [follow:false], and the two kinds a bundle may hold. A symlink here
     would be a packaging accident, and following one would copy something
     nobody chose to ship; treating it as absent leaves the entry to be
     seeded properly once the bundle is fixed. *)
  let seedable =
    match Eio.Path.kind ~follow:false src with
    | `Directory | `Regular_file -> true
    | _ -> false
  in
  if exists dst || not seedable then ()
  else begin
    (* A leftover from a run that died mid-copy. It cannot be resumed --
       nothing records how far it got -- so it goes. *)
    Eio.Path.rmtree ~missing_ok:true tmp;
    copy_tree ~src ~dst:tmp;
    Eio.Path.rename tmp dst;
    Logs.app (fun m -> m "  seeded  %s" name)
  end

let seed ~fs ~from ~into =
  let src_root = Eio.Path.(fs / from) in
  if is_dir src_root then begin
    let dst_root = Eio.Path.(fs / into) in
    match Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 dst_root with
    | () ->
        List.iter
          (fun name ->
            try seed_entry ~src_root ~dst_root name with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | e ->
                Logs.warn (fun m ->
                    m "could not seed %s from %s: %s" name from
                      (Printexc.to_string e)))
          entries
    | exception e ->
        Logs.warn (fun m ->
            m "could not use %s as a map directory: %s" into
              (Printexc.to_string e))
  end
