(* Which archives a tile lookup searches, and in what order.

   A downloaded region used to be MERGED into one growing map.pmtiles. It is
   not any more: each region is its own file, dropped in beside the others,
   which is how Organic Maps and CoMaps have always carried offline data --
   one file per country, downloaded whole, never stitched together.

   That is the whole point of the change. The file IS the download, so
   exporting a region is copying a file that already exists, importing one
   is putting it back, and removing one is unlinking it. None of those
   have to rewrite a gigabyte archive, and none of them can half-happen.

   What it costs is this module. The list of archives used to be three names
   known when the server was compiled; now it is whatever is in the basemap
   directory, and a tile lookup that opened every one of them would get
   slower with every region a user keeps. So the directory is listed, each
   file's header is remembered, and a lookup opens only the archives whose
   header says the tile could be inside them. *)

(* The three reserved names. Everything else ending in .pmtiles is a region.

   [cache] is what browsing picked up while panning online -- anonymous,
   rewritten constantly, and first in the order because it is the freshest
   thing on disk. [world] is the shipped overview, a shallow pyramid of the
   whole planet, and it is last because it is the coarsest: anything any
   other archive holds is better.

   [base] is the shared archive. Downloads no longer write it -- that is the
   change -- but three things still put tiles there: the tessarium-basemap
   CLI writes it, tools/fetch-basemap.sh runs that CLI, and folding the
   browse cache goes into it. Installs from before the split also have one
   holding every region they ever downloaded, and deleting someone's map
   because the layout changed is not an upgrade. So it is read like any
   region, below them and above the world; what makes it different is that
   it can hold many records at once, which is why removing one of them still
   means rewriting the file. *)
let cache_file = "cache.pmtiles"
let base_file = "map.pmtiles"
let world_file = "world.pmtiles"
let reserved = [ cache_file; base_file; world_file ]
let extension = ".pmtiles"

(* A region file's name is display-only -- what it holds is in its own
   header and its own ledger -- but it is also the thing a person reads off
   a USB stick, so it is worth being able to say what is NOT one. A
   half-written download is [name ^ ".part"], which does not end in
   .pmtiles and so is skipped here without a special case. *)
let is_region name =
  Filename.check_suffix name extension && not (List.mem name reserved)

(* ------------------------------------------------------------- headers *)

(* Reading a header is a file open and a 127-byte read. That is cheap once
   and expensive four hundred times a second, which is what a map pan asks
   for, so headers are remembered.

   Keyed on the file's identity rather than its name: the downloader
   publishes by renaming a .part over the real name, so the name can stay
   the same while the bytes underneath it are entirely different. Device and
   inode change on a rename-over, size and mtime catch a rewrite in place.
   A stale header would hide tiles that are really there, which is the one
   failure worth spending four fields to avoid.

   Not synchronised. Eio runs these fibers in one domain, and two fibers
   that race to fill the same key compute the same value from the same file,
   so the loser overwrites the winner with what it was going to say
   anyway. *)
type stamp = { dev : Int64.t; ino : Int64.t; size : int; mtime : float }

let cache : (string, stamp * Pmtiles.Header.t) Hashtbl.t = Hashtbl.create 16

let stamp_of (st : Eio.File.Stat.t) =
  {
    dev = st.Eio.File.Stat.dev;
    ino = st.Eio.File.Stat.ino;
    size = Optint.Int63.to_int st.Eio.File.Stat.size;
    mtime = st.Eio.File.Stat.mtime;
  }

(* The header of one archive, from the cache when the file has not moved
   under it. [None] for anything that will not open: a file being written,
   a truncated copy off a bad USB stick, something that is not an archive at
   all. Warned about once per change rather than once per tile, because the
   alternative is a log line per pan for as long as the bad file sits
   there. *)
let header_of ~dir name =
  let path = Eio.Path.(dir / name) in
  match Eio.Path.stat ~follow:true path with
  | exception Eio.Io _ -> None
  | st when st.Eio.File.Stat.kind <> `Regular_file -> None
  | st -> (
      let stamp = stamp_of st in
      match Hashtbl.find_opt cache name with
      | Some (s, h) when s = stamp -> Some (h, stamp.size)
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
              Hashtbl.replace cache name (stamp, h);
              Some (h, stamp.size)
          | exception e ->
              Hashtbl.remove cache name;
              Logs.warn (fun m ->
                  m "tile archive %s: unreadable header: %s" name
                    (Printexc.to_string e));
              None))

(* ------------------------------------------------------------- the list *)

type entry = {
  name : string;
  header : Pmtiles.Header.t;
  size : int;  (** the file's size on disk, which the header need not match *)
}

(* Every archive in the directory, in the order a lookup tries them: the
   browse cache, then the regions, then the old merged archive, then the
   world overview.

   Regions are newest first, by the time their file was last written. Two
   files can hold the same place -- a region downloaded again next year is a
   second file, not a replacement, until the old one is removed -- and when
   they disagree the newer one is the one to believe. The name breaks ties,
   so the order does not depend on a filesystem's mtime resolution.

   A directory that cannot be listed is an empty list rather than an error:
   a fresh install has no basemap directory, and it is a map with no tiles,
   not a broken server. *)
let names ~dir =
  match Eio.Path.read_dir dir with
  | exception Eio.Io _ -> []
  | all ->
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
      Option.map (fun (header, size) -> { name; header; size }) (header_of ~dir name))
    (names ~dir)

(* What "downloaded" means, as opposed to what is merely on the floor. The
   world overview is nobody's region: it is what the map falls back to
   everywhere, every package ships one, and counting it as detail would have
   the map claim it holds a planet nobody fetched. *)
let detail ~dir = List.filter (fun e -> e.name <> world_file) (entries ~dir)

(* --------------------------------------------------------- the shortcut *)

(* Could this archive hold this tile?

   The whole reason a user can keep twenty regions without the map getting
   slower. A region file's header says which zooms and which corner of the
   planet it covers, and a tile outside that box is not worth opening the
   file to miss.

   Wrong in one direction only. Saying "yes" about an archive that turns out
   not to hold the tile costs one open that finds nothing, which is what
   every lookup did before this existed. Saying "no" about an archive that
   does hold it draws a hole in the map, and nothing downstream would notice
   -- a tile nobody holds is a normal 204. So every uncertainty answers yes.

   Bounds that are degenerate or inside out describe nothing and are not
   trusted at all. The box that is trusted is widened by a tile on each
   side, because the two sides of this comparison are computed differently:
   the tile's index is exact integer arithmetic out of the id, and the
   bound's index is a float projection through a logarithm. Our own
   extracts derive their header from the same projection and so cannot fall
   outside it -- but a file carried in from somewhere else is written by
   whatever wrote it, and an archive whose header understates its own box by
   a hair is a map with a seam down the edge of every region. A tile of
   slack costs one wasted open per region edge. *)
let may_hold (h : Pmtiles.Header.t) ~z ~x ~y =
  let open Pmtiles.Header in
  if z < h.min_zoom || z > h.max_zoom then false
  else
    let e7f v = float_of_int v /. 1e7 in
    let min_lon = e7f h.min_lon_e7
    and min_lat = e7f h.min_lat_e7
    and max_lon = e7f h.max_lon_e7
    and max_lat = e7f h.max_lat_e7 in
    (* An archive written by something that left the bounds at zero, or that
       recorded them the other way round, has not told us where it is. *)
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
