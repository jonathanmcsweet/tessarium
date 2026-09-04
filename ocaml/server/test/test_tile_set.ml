(* What a tile lookup will search, now that it is a directory rather than
   three names.

   Two things here can lose a tile that is really on disk, and losing tiles
   silently is the failure this whole layout exists to avoid. One is the
   ordering: an older copy of a region must not answer ahead of a newer one.
   The other is [may_hold], which decides not to open a file at all -- a
   false "no" there draws a hole in the map that nothing else in the system
   would notice. So both are driven against real files on a real
   filesystem. *)

module Tile_set = Tessarium_server.Tile_set

let checks = ref 0
let failures = ref 0

let check name ok =
  incr checks;
  if not ok then begin
    incr failures;
    Printf.printf "  FAIL  %s\n" name
  end

let e7 v = int_of_float (Float.round (v *. 1e7))

(* An archive holding exactly [ids], with the bounds and zoom range it
   claims in its header -- which is what [may_hold] reads and therefore the
   only part of it these tests care about. *)
let archive_of ~min_zoom ~max_zoom ~min_lon ~min_lat ~max_lon ~max_lat ids =
  let tile = "x" in
  let entries =
    Array.of_list
      (List.map
         (fun id ->
           {
             Pmtiles.Directory.tile_id = id;
             offset = 0;
             length = String.length tile;
             run_length = 1;
           })
         ids)
  in
  let root = Pmtiles.Directory.serialize entries in
  let metadata = "{}" in
  let root_offset = Pmtiles.Header.size in
  let metadata_offset = root_offset + String.length root in
  let data_offset = metadata_offset + String.length metadata in
  let header =
    {
      Pmtiles.Header.root_offset;
      root_length = String.length root;
      metadata_offset;
      metadata_length = String.length metadata;
      leaf_offset = data_offset;
      leaf_length = 0;
      data_offset;
      data_length = String.length tile;
      addressed_tiles = Array.length entries;
      tile_entries = Array.length entries;
      tile_contents = 1;
      clustered = true;
      internal_compression = Pmtiles.Header.None_;
      tile_compression = Pmtiles.Header.None_;
      tile_type = Pmtiles.Header.Mvt;
      min_zoom;
      max_zoom;
      min_lon_e7 = e7 min_lon;
      min_lat_e7 = e7 min_lat;
      max_lon_e7 = e7 max_lon;
      max_lat_e7 = e7 max_lat;
      center_zoom = min_zoom;
      center_lon_e7 = 0;
      center_lat_e7 = 0;
    }
  in
  (header, Pmtiles.Header.serialize header ^ root ^ metadata ^ tile)

(* Roughly the state of Georgia, USA -- the region the download UI is
   usually driven with. *)
let georgia = (-85.6, 30.3, -80.8, 35.0)
let london = (-0.5, 51.3, 0.3, 51.7)

let box_archive ?(min_zoom = 0) ?(max_zoom = 12) (min_lon, min_lat, max_lon, max_lat) =
  archive_of ~min_zoom ~max_zoom ~min_lon ~min_lat ~max_lon ~max_lat
    (Pmtiles.Tile_id.covering ~min_zoom ~max_zoom ~min_lon ~min_lat ~max_lon
       ~max_lat)

let () =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let root = Filename.temp_dir "tessarium-tileset" "" in
  let dir_name = Filename.concat root "archive" in
  let dir = Eio.Path.(fs / dir_name) in
  Eio.Path.mkdir ~perm:0o755 dir;

  let write name content =
    Eio.Path.save ~create:(`Or_truncate 0o644) Eio.Path.(dir / name) content
  in
  (* mtime, not wall-clock order, is what the sort reads -- and a test that
     wrote three files in a row would be at the mercy of the filesystem's
     timestamp resolution. Set them explicitly. *)
  let touch name secs =
    Unix.utimes (Filename.concat dir_name name) secs secs
  in

  (* ------------------------------------------------------------- order *)

  let _, world = box_archive ~max_zoom:6 (-180., -85., 180., 85.) in
  let _, ga = box_archive georgia in
  let _, uk = box_archive london in
  write Tile_set.world_file world;
  write Tile_set.cache_file uk;
  write Tile_set.base_file ga;
  write "Georgia-2026-01-02-aaaaaa.pmtiles" ga;
  write "London-2026-01-03-bbbbbb.pmtiles" uk;
  (* Not archives, and not to be listed as ones: a download in flight and
     the file the exporter is writing. *)
  write "Georgia-2026-02-01-cccccc.pmtiles.part" ga;
  write "notes.txt" "hello";
  touch "Georgia-2026-01-02-aaaaaa.pmtiles" 1_000_000.;
  touch "London-2026-01-03-bbbbbb.pmtiles" 2_000_000.;

  let names = Tile_set.names ~dir in
  check "the browse cache answers first"
    (List.nth_opt names 0 = Some Tile_set.cache_file);
  check "then the regions, newest first"
    (List.nth_opt names 1 = Some "London-2026-01-03-bbbbbb.pmtiles"
     && List.nth_opt names 2 = Some "Georgia-2026-01-02-aaaaaa.pmtiles");
  check "then the old merged archive"
    (List.nth_opt names 3 = Some Tile_set.base_file);
  check "and the world overview last, because it is the coarsest"
    (List.nth_opt names 4 = Some Tile_set.world_file);
  check "a download still being written is not searched"
    (not (List.exists (fun n -> Filename.check_suffix n ".part") names));
  check "and neither is a file that is not an archive"
    (not (List.mem "notes.txt" names));
  check "nothing else is in the list" (List.length names = 5);

  (* A region downloaded again is a newer file, and it must answer ahead of
     the copy it supersedes -- otherwise last year's tiles win forever. *)
  touch "Georgia-2026-01-02-aaaaaa.pmtiles" 3_000_000.;
  let names = Tile_set.names ~dir in
  check "a region touched later moves ahead of one touched earlier"
    (List.nth_opt names 1 = Some "Georgia-2026-01-02-aaaaaa.pmtiles");

  check "the world overview is not counted as downloaded detail"
    (not
       (List.exists
          (fun (e : Tile_set.entry) -> e.Tile_set.name = Tile_set.world_file)
          (Tile_set.detail ~dir)));

  (* ---------------------------------------------------- the shortcut *)

  let h_ga, _ = box_archive georgia in
  let inside ~z ~lon ~lat =
    Tile_set.may_hold h_ga ~z
      ~x:(Pmtiles.Tile_id.tile_x ~z ~lon)
      ~y:(Pmtiles.Tile_id.tile_y ~z ~lat)
  in
  check "a tile over the region is worth opening the file for"
    (inside ~z:12 ~lon:(-84.4) ~lat:33.7);
  check "a tile on the far side of the planet is not"
    (not (inside ~z:12 ~lon:139.7 ~lat:35.7));
  check "nor is one just outside the region's own box"
    (not (inside ~z:12 ~lon:(-70.0) ~lat:33.7));
  check "a zoom deeper than the archive goes is not worth opening either"
    (not (inside ~z:14 ~lon:(-84.4) ~lat:33.7));

  (* The direction that matters: a tile this archive really holds must never
     be refused, or the map has a hole nothing else would report. *)
  let min_lon, min_lat, max_lon, max_lat = georgia in
  let corners =
    [
      (min_lon, min_lat); (min_lon, max_lat); (max_lon, min_lat);
      (max_lon, max_lat);
    ]
  in
  check "every corner tile of the region is admitted"
    (List.for_all (fun (lon, lat) -> inside ~z:12 ~lon ~lat) corners);
  check "and so is every tile the extract actually wrote"
    (List.for_all
       (fun id ->
         let z, x, y = Pmtiles.Tile_id.to_zxy id in
         Tile_set.may_hold h_ga ~z ~x ~y)
       (Pmtiles.Tile_id.covering ~min_zoom:0 ~max_zoom:12 ~min_lon ~min_lat
          ~max_lon ~max_lat));

  (* A file carried in from another tool, whose header understates its own
     box. Ours cannot -- the extract derives its bounds from the same
     projection [may_hold] reads them back with -- but a hand-carried file
     was written by whatever wrote it, and an archive one tile tighter than
     its own contents would draw a seam down the edge of every region. This
     is what the tile of slack in [may_hold] is for, and it is the only
     thing that shows it working. *)
  let tight_z = 12 in
  let step = 360. /. float_of_int (1 lsl tight_z) in
  let h_tight, _ =
    archive_of ~min_zoom:0 ~max_zoom:tight_z ~min_lon:(min_lon +. step)
      ~min_lat:(min_lat +. step) ~max_lon:(max_lon -. step)
      ~max_lat:(max_lat -. step) []
  in
  check "an archive whose header is a tile tighter than its tiles is still opened"
    (Tile_set.may_hold h_tight ~z:tight_z
       ~x:(Pmtiles.Tile_id.tile_x ~z:tight_z ~lon:min_lon)
       ~y:(Pmtiles.Tile_id.tile_y ~z:tight_z ~lat:min_lat));

  (* An archive that did not record where it is has not earned a "no". *)
  let h_blank, _ =
    archive_of ~min_zoom:0 ~max_zoom:12 ~min_lon:0. ~min_lat:0. ~max_lon:0.
      ~max_lat:0. []
  in
  check "an archive with no bounds recorded is opened rather than skipped"
    (Tile_set.may_hold h_blank ~z:12 ~x:0 ~y:0);

  (* ---------------------------------------------------- stale headers *)

  (* Headers are remembered so that a pan does not re-read a hundred of
     them, and the downloader publishes by renaming a .part over the name it
     is replacing. So the name can stay the same while the bytes underneath
     it become a different region entirely. If the memory did not notice,
     the map would keep answering from a header describing a file that is
     gone. *)
  let held name ~z ~lon ~lat =
    match
      List.find_opt
        (fun (e : Tile_set.entry) -> e.Tile_set.name = name)
        (Tile_set.entries ~dir)
    with
    | None -> false
    | Some e ->
        Tile_set.may_hold e.Tile_set.header ~z
          ~x:(Pmtiles.Tile_id.tile_x ~z ~lon)
          ~y:(Pmtiles.Tile_id.tile_y ~z ~lat)
  in
  let swap = "Swapped-2026-01-01-dddddd.pmtiles" in
  write swap ga;
  check "a fresh region file answers for its own ground"
    (held swap ~z:12 ~lon:(-84.4) ~lat:33.7);
  check "and not for anyone else's"
    (not (held swap ~z:12 ~lon:(-0.1) ~lat:51.5));
  (* Published the way the downloader publishes: written elsewhere, renamed
     over. Same name, different inode. *)
  write (swap ^ ".new") uk;
  Eio.Path.rename Eio.Path.(dir / (swap ^ ".new")) Eio.Path.(dir / swap);
  check "after a rename over it, the same name answers for its new ground"
    (held swap ~z:12 ~lon:(-0.1) ~lat:51.5);
  check "and no longer for the ground it used to hold"
    (not (held swap ~z:12 ~lon:(-84.4) ~lat:33.7));

  Printf.printf "\n%d checks, %d failures\n" !checks !failures;
  if !failures > 0 then exit 1;
  print_endline "tile set holds"
