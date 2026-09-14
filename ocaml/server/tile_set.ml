(* Which archives a tile lookup searches, and in what order.

   A downloaded region used to be MERGED into one growing map.pmtiles. Now
   each region is its own file, dropped in beside the others, the way Organic
   Maps and CoMaps carry offline data: one file per country, downloaded
   whole, never stitched together.

   The file IS the download. So exporting a region copies a file that already
   exists, importing one puts it back, and removing one unlinks it. None of
   those rewrite a gigabyte archive, and none can half-happen.

   The cost is this module. The list of archives used to be three names fixed
   when the server was compiled; now it is whatever sits in the basemap
   directory, and opening every one of them per tile would get slower with
   every region a user keeps. So the directory is listed, each file's header
   is remembered, and a lookup opens only the archives whose header says the
   tile could be inside. *)

(* The three reserved names. Everything else ending in .pmtiles is a region.

   [cache] is what panning around online picked up: anonymous, rewritten
   constantly, and first in the order because it is the freshest thing on
   disk. [world] is the shipped overview, a shallow pyramid of the whole
   planet, and last because it is the coarsest.

   [base] is the shared archive. Downloads no longer write it, but three
   things still do: the tessarium-basemap CLI, tools/fetch-basemap.sh (which
   runs that CLI), and folding in the browse cache. Installs from before the
   split also have one holding every region they ever downloaded, and
   deleting someone's map because the layout changed is not an upgrade. So it
   is read like a region, below the regions and above the world. It differs
   in holding many records at once, which is why removing one still means
   rewriting the file. *)
let cache_file = "cache.pmtiles"
let base_file = "map.pmtiles"
let world_file = "world.pmtiles"
let reserved = [ cache_file; base_file; world_file ]
let extension = ".pmtiles"

(* A region file's name is display-only -- what it holds is in its header and
   its ledger -- but it is what a person reads off a USB stick, so it is
   worth saying what is NOT one. A half-written download is [name ^ ".part"],
   which does not end in .pmtiles and so is skipped with no special case.

   This also answers "may the user delete this file", and every place that
   unlinks one asks here. The world overview must never be deletable: it is
   the map under the map, every package ships one, and a user who removed it
   would have holes everywhere they had not downloaded a region -- with no
   way to get it back on a machine with no internet, which is the machine
   this is all for. It is not a region, so it is not removable. Said once
   here, it stays true in all four places that could break it. *)
let is_region name =
  Filename.check_suffix name extension && not (List.mem name reserved)

(* ------------------------------------------------------------- headers *)

(* Reading a header is a file open and a 127-byte read: cheap once, expensive
   four hundred times a second, which is what panning the map asks for. So
   headers are remembered.

   Keyed on the file's identity, not just its name. The downloader publishes
   by renaming a .part over the real name, so the name can stay put while the
   bytes underneath it change completely. Device and inode catch a
   rename-over; size and mtime catch a rewrite in place. A stale header hides
   tiles that are really there.

   Not synchronised. Eio runs these fibers in one domain, and two fibers
   racing to fill the same key read the same file, so the loser overwrites
   the winner with the same answer.

   The key is the bare name, and the stamp is what makes that safe: a name
   meaning a different file -- another directory, a rename-over, a recycled
   inode -- carries a different stamp, so it misses and is read again. What
   the name alone cannot say is when an entry may be forgotten; that is the
   eviction in [names]. *)
type stamp = {
  dev : Int64.t;
  ino : Int64.t;
  size : int;
  mtime : float;
}

(* A file that will not open is remembered too, as a failure against the
   stamp that produced it.

   Forgetting it instead meant an unreadable archive was re-opened and
   re-logged on EVERY tile request: hundreds of opens and hundreds of warning
   lines a second during a pan, over a file that is not going to start
   working. A truncated copy of an imported archive is the case that hurt.
   Held against the stamp, the retry and the log line happen only when the
   file changes. *)
type remembered =
  | Readable of Pmtiles.Header.t
  | Unreadable

let cache : (string, stamp * remembered) Hashtbl.t = Hashtbl.create 16

let stamp_of (st : Eio.File.Stat.t) =
  {
    dev = st.Eio.File.Stat.dev;
    ino = st.Eio.File.Stat.ino;
    size = Optint.Int63.to_int st.Eio.File.Stat.size;
    mtime = st.Eio.File.Stat.mtime;
  }

(* The header of one archive, from the cache when the file has not changed
   under it. [None] for anything that will not open: a file being written, a
   truncated copy off a bad USB stick, something that is not an archive.
   Warned about once per change, not once per tile -- otherwise a bad file
   costs a log line per pan for as long as it sits there. *)
let header_of ~dir name =
  let path = Eio.Path.(dir / name) in
  match Eio.Path.stat ~follow:true path with
  | exception Eio.Io _ -> None
  | st when st.Eio.File.Stat.kind <> `Regular_file -> None
  | st -> (
      let stamp = stamp_of st in
      match Hashtbl.find_opt cache name with
      | Some (s, Readable h) when s = stamp -> Some (h, stamp.size)
      | Some (s, Unreadable) when s = stamp -> None
      | _ -> (
          match
            Eio.Switch.run @@ fun sw ->
            let a =
              Pmtiles.Archive.open_
                (Pmtiles_source.file_source (Eio.Path.open_in ~sw path))
            in
            a.Pmtiles.Archive.header
          with
          | h ->
              Hashtbl.replace cache name (stamp, Readable h);
              Some (h, stamp.size)
          | exception e ->
              Hashtbl.replace cache name (stamp, Unreadable);
              Logs.warn (fun m ->
                  m "tile archive %s: unreadable header: %s" name
                    (Printexc.to_string e));
              None))

(* How many headers are remembered, so a test can check that a name which
   left the directory was forgotten. Nothing else needs it. *)
let remembered_count () = Hashtbl.length cache

(* ------------------------------------------------------------- the list *)

type entry = {
  name : string;
  header : Pmtiles.Header.t;
  size : int;  (** the file's size on disk, which the header need not match *)
}

(* Every archive in the directory, in the order a lookup tries them: the
   browse cache, the regions, the old merged archive, then the world
   overview.

   Regions are newest first, by when their file was last written. Two files
   can hold the same place -- downloading a region again next year makes a
   second file, not a replacement, until the old one is removed -- and the
   newer one wins when they disagree. The name breaks ties, so the order does
   not depend on the filesystem's mtime resolution.

   A directory that cannot be listed gives an empty list, not an error: a
   fresh install has no basemap directory, which is a map with no tiles, not
   a broken server. *)
let names ~dir =
  match Eio.Path.read_dir dir with
  | exception Eio.Io _ -> []
  | all ->
      (* A name that has left the directory is a header nothing will ask for
         again. Removed regions, renames and re-dated re-downloads used to
         leave their entries behind for the life of the process. Done here
         because this is the one place that knows what is present, and the
         directory listing is already paid for. *)
      (let present = Hashtbl.create (List.length all) in
       List.iter (fun n -> Hashtbl.replace present n ()) all;
       Hashtbl.filter_map_inplace
         (fun name v -> if Hashtbl.mem present name then Some v else None)
         cache);
      let regions =
        List.filter is_region all
        |> List.map (fun name ->
            let mtime =
              match Eio.Path.stat ~follow:true Eio.Path.(dir / name) with
              | st -> st.Eio.File.Stat.mtime
              | exception Eio.Io _ -> 0.
            in
            (name, mtime))
        |> List.sort (fun (n1, m1) (n2, m2) ->
            match compare m2 m1 with 0 -> compare n1 n2 | c -> c)
        |> List.map fst
      in
      let present name = List.mem name all in
      List.concat
        [
          (if present cache_file then [ cache_file ] else []);
          regions;
          (if present base_file then [ base_file ] else []);
          (if present world_file then [ world_file ] else []);
        ]

let entries ~dir =
  List.filter_map
    (fun name ->
      Option.map
        (fun (header, size) -> { name; header; size })
        (header_of ~dir name))
    (names ~dir)

(* What counts as downloaded. The world overview is nobody's region: it is
   what the map falls back to everywhere and every package ships one, so
   counting it as detail would have the map claim a planet nobody fetched. *)
let detail ~dir = List.filter (fun e -> e.name <> world_file) (entries ~dir)

(* --------------------------------------------------------- the shortcut *)

(* Could this archive hold this tile?

   This is why a user can keep twenty regions without the map slowing down. A
   region's header says which zooms and which corner of the planet it covers,
   and a tile outside that box is not worth opening the file to miss.

   Only safe to be wrong one way. A false yes costs one open that finds
   nothing, which is what every lookup did before this existed. A false no
   draws a hole in the map, and nothing downstream would notice -- a tile
   nobody holds is a normal 204. So anything uncertain answers yes.

   Empty or inside-out bounds describe nothing and are not trusted at all.
   The box that is trusted is widened by one tile on each side, because the
   two sides of the comparison are computed differently: the tile's index is
   exact integer arithmetic from the id, the bound's index is a float
   projection through a logarithm. Our own extracts use that same projection
   and cannot fall outside it, but a file carried in from elsewhere was
   written by whatever wrote it, and a header that understates its own box by
   a hair puts a seam down the edge of every region. The slack costs one
   wasted open per region edge. *)
let may_hold (h : Pmtiles.Header.t) ~z ~x ~y =
  let open Pmtiles.Header in
  if z < h.min_zoom || z > h.max_zoom then false
  else
    let min_lon = Degrees.of_e7 h.min_lon_e7
    and min_lat = Degrees.of_e7 h.min_lat_e7
    and max_lon = Degrees.of_e7 h.max_lon_e7
    and max_lat = Degrees.of_e7 h.max_lat_e7 in
    (* Bounds left at zero, or recorded the other way round, say nothing
       about where the archive is. *)
    if min_lon >= max_lon || min_lat >= max_lat then true
    else
      let last = (1 lsl z) - 1 in
      let clamp v = if v < 0 then 0 else if v > last then last else v in
      let x0 = clamp (Pmtiles.Tile_id.tile_x ~z ~lon:min_lon - 1) in
      let x1 = clamp (Pmtiles.Tile_id.tile_x ~z ~lon:max_lon + 1) in
      (* y grows southward, so the northern edge gives the smaller index. *)
      let y0 = clamp (Pmtiles.Tile_id.tile_y ~z ~lat:max_lat - 1) in
      let y1 = clamp (Pmtiles.Tile_id.tile_y ~z ~lat:min_lat + 1) in
      x >= x0 && x <= x1 && y >= y0 && y <= y1
