(* What a tile lookup will search, now that it is a directory rather than
   three fixed names.

   Two things here can lose a tile that is really on disk. The ordering: an
   older copy of a region must not answer ahead of a newer one. And
   [may_hold], which decides not to open a file at all -- a wrong "no" leaves
   a hole in the map nothing else would report. Both run against real files on
   a real filesystem. *)

module Tile_set = Tessarium_server.Tile_set

let checks = ref 0
let failures = ref 0

let check name ok =
  incr checks;
  if not ok then begin
    incr failures;
    Printf.printf "  FAIL  %s\n" name
  end

(* An archive holding exactly [ids], with the bounds and zoom range its header
   claims. [may_hold] reads only the header, so that is all these tests care
   about; every id points at the same byte. *)
let archive_of ~min_zoom ~max_zoom ~min_lon ~min_lat ~max_lon ~max_lat ids =
  Pmtiles.Build.archive ~min_zoom ~max_zoom ~min_lon ~min_lat ~max_lon ~max_lat
    ~tiles:(List.map (fun id -> (id, "x")) ids)
    ()

(* Roughly the state of Georgia, USA -- the region the download UI is
   usually driven with. *)
let georgia = (-85.6, 30.3, -80.8, 35.0)
let london = (-0.5, 51.3, 0.3, 51.7)

let box_archive ?(min_zoom = 0) ?(max_zoom = 12)
    (min_lon, min_lat, max_lon, max_lat) =
  Pmtiles.Build.of_box ~min_zoom ~max_zoom ~min_lon ~min_lat ~max_lon ~max_lat
    ~body:(fun _ -> "x")
    ()

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
  (* The sort reads mtime. Writing three files in a row would leave the order
     up to the filesystem's timestamp resolution, so set mtimes by hand. *)
  let touch name secs = Unix.utimes (Filename.concat dir_name name) secs secs in

  (* ------------------------------------------------------------- order *)
  let _, world = box_archive ~max_zoom:6 (-180., -85., 180., 85.) in
  let _, ga = box_archive georgia in
  let _, uk = box_archive london in
  write Tile_set.world_file world;
  write Tile_set.cache_file uk;
  write Tile_set.base_file ga;
  write "Georgia-2026-01-02-aaaaaa.pmtiles" ga;
  write "London-2026-01-03-bbbbbb.pmtiles" uk;
  (* Neither belongs in the list: a download still in flight, and a stray
     file. *)
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

  (* A region downloaded again is a newer file and must answer ahead of the
     copy it supersedes, or last year's tiles win forever. *)
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

  (* A tile the archive really holds must never be refused, or the map gets a
     hole nothing else reports. *)
  let min_lon, min_lat, max_lon, max_lat = georgia in
  let corners =
    [
      (min_lon, min_lat);
      (min_lon, max_lat);
      (max_lon, min_lat);
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

  (* A file from another tool whose header understates its own box. Our
     extract cannot do that -- it derives bounds from the same projection
     [may_hold] reads back -- but a hand-carried file might, and a header one
     tile tighter than its contents would draw a seam down every region edge.
     [may_hold] allows a tile of slack; this is the only test of it. *)
  let tight_z = 12 in
  let step = 360. /. float_of_int (1 lsl tight_z) in
  let h_tight, _ =
    archive_of ~min_zoom:0 ~max_zoom:tight_z ~min_lon:(min_lon +. step)
      ~min_lat:(min_lat +. step) ~max_lon:(max_lon -. step)
      ~max_lat:(max_lat -. step) []
  in
  check
    "an archive whose header is a tile tighter than its tiles is still opened"
    (Tile_set.may_hold h_tight ~z:tight_z
       ~x:(Pmtiles.Tile_id.tile_x ~z:tight_z ~lon:min_lon)
       ~y:(Pmtiles.Tile_id.tile_y ~z:tight_z ~lat:min_lat));

  let h_blank, _ =
    archive_of ~min_zoom:0 ~max_zoom:12 ~min_lon:0. ~min_lat:0. ~max_lon:0.
      ~max_lat:0. []
  in
  check "an archive with no bounds recorded is opened rather than skipped"
    (Tile_set.may_hold h_blank ~z:12 ~x:0 ~y:0);

  (* ---------------------------------------------------- stale headers *)

  (* Headers are cached so a pan does not re-read a hundred of them. The
     downloader publishes by renaming a .part over the name it replaces, so
     one name can end up holding a different region. A cache that missed that
     would answer from a header for a file that is gone. *)
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

  (* ------------------------------------------------ files that will not open *)

  (* A file that will not open is remembered as broken, in the same cache and
     against the same file details as a good one.

     It used to be forgotten instead, so it was re-opened and re-logged on
     every single tile request -- hundreds of opens and warning lines a second
     over a file that is never going to work. A half-copied archive off a bad
     USB stick is exactly that case.

     Counted through remembered names, because the only other way to see this
     is to count log lines. *)
  let listed () = List.length (Tile_set.names ~dir) in
  let broken = "Broken-2026-01-01-eeeeee.pmtiles" in
  write broken "this is not a PMTiles archive";
  ignore (Tile_set.entries ~dir);
  check "an unreadable archive is not offered for lookups"
    (not
       (List.exists
          (fun (e : Tile_set.entry) -> e.Tile_set.name = broken)
          (Tile_set.entries ~dir)));
  check "but it is remembered, so it is not re-opened on the next tile"
    (Tile_set.remembered_count () = listed ());
  (* What is remembered is the file, not the name: put readable bytes there
     and it has to start answering. *)
  write broken ga;
  check "and a file that starts working is picked up when it changes"
    (held broken ~z:12 ~lon:(-84.4) ~lat:33.7);

  (* ------------------------------------------------------------- eviction *)

  (* A removed, renamed or re-dated archive used to leave its header behind
     for the life of the process -- one stale entry for every download a user
     ever made. Only the directory listing knows what is actually there, so
     that is where entries get dropped. *)
  Eio.Path.unlink Eio.Path.(dir / broken);
  Eio.Path.unlink Eio.Path.(dir / swap);
  check "a name that has left the directory stops being remembered"
    (Tile_set.remembered_count () = listed ());
  check "and what is still there is still remembered"
    (Tile_set.remembered_count () = List.length (Tile_set.entries ~dir));

  Printf.printf "\n%d checks, %d failures\n" !checks !failures;
  if !failures > 0 then exit 1;
  print_endline "tile set holds"
