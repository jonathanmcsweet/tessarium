(* What the coverage query says about an archive whose contents are known.

   The endpoint's parsing is checked with fakes in test_server; this drives
   the real [Basemap_download.coverage] against a real archive on a real
   filesystem, because everything worth getting wrong here is arithmetic:
   which tile rectangle a viewport becomes, which corner the answer starts
   from, which direction it runs, and which archive wins when two hold
   different tiles.

   The archives are built by hand rather than by the fixture generator: a
   coverage query reads directories and never a tile body, so a one-byte
   blob shared by every entry is a complete archive for this purpose, and
   building it here keeps the expected tile set in the same file as the
   assertions about it. *)

let checks = ref 0
let failures = ref 0

let check name ok =
  incr checks;
  if not ok then begin
    incr failures;
    Printf.printf "  FAIL  %s\n" name
  end

(* An archive holding exactly [ids], every one pointing at the same byte.
   Uncompressed directories, so this is the format's own layout with
   nothing in the way. *)
let archive_of ~max_zoom ids =
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
  let e7 v = int_of_float (Float.round (v *. 1e7)) in
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
      min_zoom = 0;
      max_zoom;
      min_lon_e7 = e7 (-180.);
      min_lat_e7 = e7 (-85.);
      max_lon_e7 = e7 180.;
      max_lat_e7 = e7 85.;
      center_zoom = 0;
      center_lon_e7 = 0;
      center_lat_e7 = 0;
    }
  in
  Pmtiles.Header.serialize header ^ root ^ metadata ^ tile

let write dir name content =
  Eio.Path.save ~create:(`Or_truncate 0o644) Eio.Path.(dir / name) content

(* The one place under test. Answers are read back as JSON, which is also
   the shape the UI parses. *)
let query ~fs ~dir ~min_lon ~min_lat ~max_lon ~max_lat ~zoom =
  match
    Tessarium_server.Basemap_job.validate ~min_lon ~min_lat ~max_lon
      ~max_lat ~max_zoom:zoom ()
  with
  | Error e -> Error e
  | Ok req -> Tessarium_server.Basemap_download.coverage ~fs ~basemap_dir:dir req

let field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let int_field name json =
  match field name json with Some (`Int i) -> i | _ -> min_int

let string_field name json =
  match field name json with Some (`String s) -> s | _ -> "<missing>"

let () =
  Eio_main.run @@ fun env ->
  (* A scratch directory outside the tree: [dune exec] runs from the project
     root, so a relative path here would leave fixture archives lying in the
     repository. *)
  let fs = Eio.Stdenv.fs env in
  let root = Filename.temp_dir "tessarium-coverage" "" in
  let dir_name = Filename.concat root "archive" in
  let dir = Eio.Path.(fs / dir_name) in
  Eio.Path.mkdir ~perm:0o755 dir;

  (* A deliberately lopsided archive: the whole world down to zoom 2, and a
     single small box -- roughly greater London -- down to zoom 12. That is
     the shape a real archive has after a world overview plus one country,
     and it is the shape that makes "coverage" mean two different things at
     two different zooms. *)
  let world = Pmtiles.Tile_id.covering ~min_zoom:0 ~max_zoom:2
      ~min_lon:(-180.) ~min_lat:(-85.) ~max_lon:180. ~max_lat:85. in
  let london = Pmtiles.Tile_id.covering ~min_zoom:3 ~max_zoom:12
      ~min_lon:(-0.5) ~min_lat:51.3 ~max_lon:0.3 ~max_lat:51.7 in
  write dir "map.pmtiles"
    (archive_of ~max_zoom:12 (List.sort_uniq compare (world @ london)));

  (* ------------------------------------------------- inside and outside *)
  (match
     query ~fs ~dir:dir_name ~min_lon:(-0.2) ~min_lat:51.45 ~max_lon:(-0.05)
       ~max_lat:51.55 ~zoom:12
   with
  | Error e -> check ("a view inside coverage answers: " ^ e) false
  | Ok json ->
      let present = string_field "present" json in
      check "every tile of a view inside the downloaded box is present"
        (present <> "" && String.for_all (fun c -> c = '1') present);
      check "the rectangle is the viewport's own tiles"
        (int_field "w" json * int_field "h" json = String.length present);
      check "the north-west corner is where the answer starts"
        (int_field "x" json
         = Pmtiles.Tile_id.tile_x ~z:12 ~lon:(-0.2)
        && int_field "y" json = Pmtiles.Tile_id.tile_y ~z:12 ~lat:51.55);
      check "the deepest zoom here is the one the box was cut to"
        (int_field "depth" json = 12));

  (* Tokyo: outside every downloaded box, but the world overview still has
     a tile over it at zoom 2 -- so "nothing here" is false and "nothing
     here at THIS zoom" is true. The difference is the whole point of
     reporting a depth beside the mask. *)
  (match
     query ~fs ~dir:dir_name ~min_lon:139.6 ~min_lat:35.6 ~max_lon:139.8
       ~max_lat:35.8 ~zoom:12
   with
  | Error e -> check ("a view outside coverage answers: " ^ e) false
  | Ok json ->
      check "a view outside every downloaded box is blank at street zoom"
        (String.for_all (fun c -> c = '0') (string_field "present" json));
      check "the overview underneath is still reported as depth"
        (int_field "depth" json = 2));

  (match
     query ~fs ~dir:dir_name ~min_lon:139.6 ~min_lat:35.6 ~max_lon:139.8
       ~max_lat:35.8 ~zoom:2
   with
  | Error e -> check ("a view at overview zoom answers: " ^ e) false
  | Ok json ->
      check "the same place at overview zoom is covered"
        (String.for_all (fun c -> c = '1') (string_field "present" json)));

  (* --------------------------------------------------- the edge itself *)
  (* A view straddling the eastern edge of the London box at zoom 8, which
     is the case the mask exists to draw. The expected string is computed
     from the box the archive was built from, so a change to the row order
     or the starting corner fails here rather than in a screenshot. *)
  (match
     query ~fs ~dir:dir_name ~min_lon:0. ~min_lat:51.35 ~max_lon:1.6
       ~max_lat:51.65 ~zoom:8
   with
  | Error e -> check ("a straddling view answers: " ^ e) false
  | Ok json ->
      let x0 = int_field "x" json and y0 = int_field "y" json in
      let w = int_field "w" json and h = int_field "h" json in
      let present = string_field "present" json in
      let expected = Buffer.create (w * h) in
      for y = y0 to y0 + h - 1 do
        for x = x0 to x0 + w - 1 do
          let inside =
            x >= Pmtiles.Tile_id.tile_x ~z:8 ~lon:(-0.5)
            && x <= Pmtiles.Tile_id.tile_x ~z:8 ~lon:0.3
            && y >= Pmtiles.Tile_id.tile_y ~z:8 ~lat:51.7
            && y <= Pmtiles.Tile_id.tile_y ~z:8 ~lat:51.3
          in
          Buffer.add_char expected (if inside then '1' else '0')
        done
      done;
      check "the mask runs west to east, north to south"
        (present = Buffer.contents expected);
      check "the edge is actually in this view -- otherwise it proves nothing"
        (String.contains present '0' && String.contains present '1'));

  (* ------------------------------------------------------- the cache wins *)
  (* The browse cache is consulted first by the tile endpoint, so a tile it
     holds is a tile the map draws -- and coverage that ignored it would
     grey out what the user is looking at. *)
  let tokyo_z12 =
    Pmtiles.Tile_id.covering ~min_zoom:12 ~max_zoom:12 ~min_lon:139.6
      ~min_lat:35.6 ~max_lon:139.8 ~max_lat:35.8
  in
  write dir "cache.pmtiles" (archive_of ~max_zoom:12 tokyo_z12);
  (match
     query ~fs ~dir:dir_name ~min_lon:139.6 ~min_lat:35.6 ~max_lon:139.8
       ~max_lat:35.8 ~zoom:12
   with
  | Error e -> check ("a browsed view answers: " ^ e) false
  | Ok json ->
      check "a tile only the browse cache holds counts as coverage"
        (String.for_all (fun c -> c = '1') (string_field "present" json));
      check "the cache's depth counts too" (int_field "depth" json = 12));
  Eio.Path.unlink Eio.Path.(dir / "cache.pmtiles");

  (* ------------------------------------------------------------- bounds *)
  (* A viewport is dozens of tiles; a request for a continent at street
     zoom is not a viewport, and answering it slowly would be worse than
     refusing it. *)
  check "a query too large to be a viewport is refused"
    (match
       query ~fs ~dir:dir_name ~min_lon:(-10.) ~min_lat:40. ~max_lon:10.
         ~max_lat:55. ~zoom:12
     with
    | Error _ -> true
    | Ok _ -> false);

  (* An empty basemap directory is the state before the first download, and
     it must answer rather than fail: the map is blank everywhere, which is
     exactly what the mask should say. *)
  let empty = Filename.concat root "empty" in
  Eio.Path.mkdir ~perm:0o755 Eio.Path.(fs / empty);
  (match
     query ~fs ~dir:empty ~min_lon:(-0.2) ~min_lat:51.45 ~max_lon:(-0.05)
       ~max_lat:51.55 ~zoom:12
   with
  | Error e -> check ("an empty basemap directory answers: " ^ e) false
  | Ok json ->
      check "with no archive at all, nothing is covered"
        (String.for_all (fun c -> c = '0') (string_field "present" json));
      check "and there is no depth to report" (int_field "depth" json = -1));

  Eio.Path.unlink Eio.Path.(dir / "map.pmtiles");
  Eio.Path.rmdir dir;
  Eio.Path.rmdir Eio.Path.(fs / empty);
  Eio.Path.rmdir Eio.Path.(fs / root);

  Printf.printf "\n%d checks, %d failures\n" !checks !failures;
  (* The suite's own report line, which tools/check-suites.sh looks for --
     said either way, so a suite that stopped running is distinguishable
     from one that ran and failed. *)
  print_endline
    (if !failures = 0 then "coverage answers hold"
     else "coverage answers FAILED");
  if !failures > 0 then exit 1
