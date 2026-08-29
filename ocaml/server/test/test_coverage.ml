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
  | Error e -> Error (Tessarium_server.Basemap_download.Unreadable e)
  | Ok req ->
      Tessarium_server.Basemap_download.coverage ~fs ~basemap_dir:dir req

let why = function
  | Tessarium_server.Basemap_download.Too_large e
  | Tessarium_server.Basemap_download.Unreadable e ->
      e

let field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let int_field name json =
  match field name json with Some (`Int i) -> i | _ -> min_int

let string_field name json =
  match field name json with Some (`String s) -> s | _ -> "<missing>"

let bool_field name json =
  match field name json with Some (`Bool b) -> Some b | _ -> None

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
  | Error e -> check ("a view inside coverage answers: " ^ why e) false
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
  | Error e -> check ("a view outside coverage answers: " ^ why e) false
  | Ok json ->
      check "a view outside every downloaded box is blank at street zoom"
        (String.for_all (fun c -> c = '0') (string_field "present" json));
      check "the overview underneath is still reported as depth"
        (int_field "depth" json = 2);
      (* And the floor really does draw there, which is a different
         sentence: this archive covers the WHOLE planet at zoom 2, so the
         map under the map has something to show over Tokyo. *)
      check "the floor reaches somewhere never downloaded"
        (bool_field "floor" json = Some true));

  (match
     query ~fs ~dir:dir_name ~min_lon:139.6 ~min_lat:35.6 ~max_lon:139.8
       ~max_lat:35.8 ~zoom:2
   with
  | Error e -> check ("a view at overview zoom answers: " ^ why e) false
  | Ok json ->
      check "the same place at overview zoom is covered"
        (String.for_all (fun c -> c = '1') (string_field "present" json)));

  (* --------------------------------------------------- the edge itself *)
  (* A view over the north-east corner of the London box, which is the case
     the mask exists to draw. The expected string is computed from the box
     the archive was built from, so the starting corner and both directions
     of travel are pinned here rather than in a screenshot.

     Both axes only get pinned if the mask is asymmetric in both, which a
     view over a straight edge is not: the first version of this check used
     one, and reversing the ROWS passed it. The two guards below fail if
     this fixture ever drifts back into a shape that cannot tell. *)
  (match
     query ~fs ~dir:dir_name ~min_lon:0. ~min_lat:51.55 ~max_lon:1.2
       ~max_lat:52.1 ~zoom:10
   with
  | Error e -> check ("a straddling view answers: " ^ why e) false
  | Ok json ->
      let x0 = int_field "x" json and y0 = int_field "y" json in
      let w = int_field "w" json and h = int_field "h" json in
      let present = string_field "present" json in
      let row i = String.sub present (i * w) w in
      let rows = List.init h row in
      let expected = Buffer.create (w * h) in
      for y = y0 to y0 + h - 1 do
        for x = x0 to x0 + w - 1 do
          let inside =
            x >= Pmtiles.Tile_id.tile_x ~z:10 ~lon:(-0.5)
            && x <= Pmtiles.Tile_id.tile_x ~z:10 ~lon:0.3
            && y >= Pmtiles.Tile_id.tile_y ~z:10 ~lat:51.7
            && y <= Pmtiles.Tile_id.tile_y ~z:10 ~lat:51.3
          in
          Buffer.add_char expected (if inside then '1' else '0')
        done
      done;
      check "the mask runs west to east, north to south"
        (present = Buffer.contents expected);
      check "the edge is actually in this view -- otherwise it proves nothing"
        (String.contains present '0' && String.contains present '1');
      check "this view can tell north from south -- otherwise it proves less"
        (rows <> List.rev rows);
      check "and west from east"
        (List.exists
           (fun r ->
             let reversed = String.init w (fun i -> r.[w - 1 - i]) in
             r <> reversed)
           rows));

  (* The middle of the view is where the note speaks about, so the depth
     reported has to be the depth of THAT tile. When it was measured at the
     midpoint of the requested degrees instead, the two named different
     tiles often enough to matter -- and the client could then be told its
     middle was blank while being handed a depth saying otherwise, which
     reads on screen as "zoom out to see it" over ground already at this
     zoom. *)
  let blank_centre_is_shallow ~min_lon ~min_lat ~max_lon ~max_lat ~zoom =
    match query ~fs ~dir:dir_name ~min_lon ~min_lat ~max_lon ~max_lat ~zoom with
    | Error _ -> false
    | Ok json ->
        let w = int_field "w" json and h = int_field "h" json in
        let present = string_field "present" json in
        let middle = present.[(h / 2 * w) + (w / 2)] in
        (* Either the middle holds a tile, or the depth is below the zoom
           asked about. Never "blank here, but covered at this zoom". *)
        middle = '1' || int_field "depth" json < zoom
  in
  (* Swept rather than sampled. The two ways of naming "the middle" agree
     for most viewports and disagree for a few hundred in every few
     thousand, so three hand-picked boxes proved nothing: measuring the
     depth at the degree midpoint again passed them all. This walks
     viewports across the edge of the London box at every zoom the archive
     holds, which finds the disagreement in the first handful. *)
  let swept = ref 0 and broke = ref 0 in
  for zoom = 6 to 12 do
    for i = 0 to 19 do
      for j = 0 to 5 do
        let lon = -0.8 +. (float_of_int i *. 0.0731) in
        let lat = 51.13 +. (float_of_int j *. 0.0917) in
        incr swept;
        if
          not
            (blank_centre_is_shallow ~min_lon:lon ~min_lat:lat
               ~max_lon:(lon +. 0.211) ~max_lat:(lat +. 0.083) ~zoom)
        then incr broke
      done
    done
  done;
  check
    (Printf.sprintf
       "a blank middle always reports a depth below the zoom asked about \
        (%d of %d viewports disagreed)" !broke !swept)
    (!broke = 0 && !swept = 840);

  (* The edges of the world, where the tile grid runs out.

     [tile_x] at exactly 180 returns 2^z -- one past the last column, which
     [of_zxy] refuses -- so a view against the date line raises rather than
     answers without the clamp on the rectangle. [tile_y] cannot do the
     same at the pole because it clamps the latitude itself first, which is
     why the clamp inside the depth probe is insurance rather than load
     bearing: the centre of a tile is never on the edge of the world. *)
  check "a view against the date line answers instead of raising"
    (match
       query ~fs ~dir:dir_name ~min_lon:179. ~min_lat:0. ~max_lon:180.
         ~max_lat:1. ~zoom:6
     with
    | Ok json -> String.length (string_field "present" json) > 0
    | Error _ -> false);
  check "and so does one against the pole"
    (match
       query ~fs ~dir:dir_name ~min_lon:(-1.) ~min_lat:85.0 ~max_lon:1.
         ~max_lat:85.06 ~zoom:6
     with
    | Ok json -> String.length (string_field "present" json) > 0
    | Error _ -> false);

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
  | Error e -> check ("a browsed view answers: " ^ why e) false
  | Ok json ->
      check "a tile only the browse cache holds counts as coverage"
        (String.for_all (fun c -> c = '1') (string_field "present" json));
      check "the cache's depth counts too" (int_field "depth" json = 12));
  Eio.Path.unlink Eio.Path.(dir / "cache.pmtiles");

  (* ------------------------------------------------- a broken archive *)
  (* A half-written map.pmtiles is what a crashed download leaves behind.
     The tile endpoint skips such a file and serves what it can; coverage
     has to do the same, or the mask disappears exactly where someone most
     wants to know whether they hold tiles -- and it must not blame the
     page that asked. The browse cache beside it still answers. *)
  write dir "cache.pmtiles" (archive_of ~max_zoom:12 tokyo_z12);
  let good = Eio.Path.load Eio.Path.(dir / "map.pmtiles") in
  write dir "map.pmtiles" "";
  (match
     query ~fs ~dir:dir_name ~min_lon:139.6 ~min_lat:35.6 ~max_lon:139.8
       ~max_lat:35.8 ~zoom:12
   with
  | Error e ->
      check ("an unreadable archive still answers from the other: " ^ why e)
        false
  | Ok json ->
      check "an archive that will not open is skipped, not fatal"
        (String.for_all (fun c -> c = '1') (string_field "present" json)));
  write dir "map.pmtiles" good;
  Eio.Path.unlink Eio.Path.(dir / "cache.pmtiles");

  (* ------------------------------------------------------------- bounds *)
  (* A viewport is dozens of tiles; a request for a continent at street
     zoom is not a viewport, and answering it slowly would be worse than
     refusing it. *)
  check "a query too large to be a viewport is refused, as the caller's error"
    (match
       query ~fs ~dir:dir_name ~min_lon:(-10.) ~min_lat:40. ~max_lon:10.
         ~max_lat:55. ~zoom:12
     with
    | Error (Tessarium_server.Basemap_download.Too_large _) -> true
    | Error (Tessarium_server.Basemap_download.Unreadable _) | Ok _ -> false);

  (* An empty basemap directory is the state before the first download, and
     it must answer rather than fail: the map is blank everywhere, which is
     exactly what the mask should say. *)
  let empty = Filename.concat root "empty" in
  Eio.Path.mkdir ~perm:0o755 Eio.Path.(fs / empty);
  (match
     query ~fs ~dir:empty ~min_lon:(-0.2) ~min_lat:51.45 ~max_lon:(-0.05)
       ~max_lat:51.55 ~zoom:12
   with
  | Error e -> check ("an empty basemap directory answers: " ^ why e) false
  | Ok json ->
      check "with no archive at all, nothing is covered"
        (String.for_all (fun c -> c = '0') (string_field "present" json));
      check "and there is no depth to report" (int_field "depth" json = -1);
      check "and no floor under it either" (bool_field "floor" json = Some false));

  (* --------------------------------------------------- what is on disk *)
  (* The banner over the map reads this. A world overview alone is a drawn,
     labelled planet and writes no ledger entry -- the extraction tool does
     not keep one -- so "are there entries" is the wrong question and
     "no basemap found" over it would contradict the map behind it. *)
  let held_in dir_name =
    match Tessarium_server.Basemap_download.ledger_json ~fs ~basemap_dir:dir_name with
    | Ok json -> bool_field "held" json
    | Error _ -> None
  in
  let world_only = Filename.concat root "world-only" in
  Eio.Path.mkdir ~perm:0o755 Eio.Path.(fs / world_only);
  write Eio.Path.(fs / world_only) "world.pmtiles" (archive_of ~max_zoom:2 world);
  check "a world overview on its own counts as a basemap"
    (held_in world_only = Some true);
  check "an empty directory does not" (held_in empty = Some false);
  (* And the one row it does list is the overview describing itself, not a
     download. "Held" still cannot be read off the entry count -- an entry
     here is the map itself -- which is the reason [held] is answered
     separately at all. *)
  check "and lists exactly the map it is, with nothing to remove"
    (match
       Tessarium_server.Basemap_download.ledger_json ~fs ~basemap_dir:world_only
     with
    | Ok (`Assoc fields) -> (
        match List.assoc_opt "entries" fields with
        | Some (`List [ `Assoc e ]) ->
            List.assoc_opt "overview" e = Some (`Bool true)
            && List.assoc_opt "id" e
               = Some (`String Tessarium_server.Basemap_download.overview_id)
        | _ -> false)
    | _ -> false);
  check "while an empty directory lists nothing"
    (match Tessarium_server.Basemap_download.ledger_json ~fs ~basemap_dir:empty with
    | Ok (`Assoc fields) -> List.assoc_opt "entries" fields = Some (`List [])
    | _ -> false);
  (* --------------------------------------------- how deep the answer is *)
  (* The question a viewport asks is the camera zoom, and the answer has to
     be about the zoom MapLibre will really REQUEST -- which past an
     archive's own depth is that depth, because the map overzooms the
     deepest tiles it has rather than asking for more. Clamping that in the
     browser is what used to force `/tiles.json` to advertise a depth it
     did not have.

     This archive stops at zoom 12. *)
  (match
     query ~fs ~dir:dir_name ~min_lon:(-0.2) ~min_lat:51.45 ~max_lon:(-0.05)
       ~max_lat:51.55 ~zoom:15
   with
  | Error e -> check ("a view past the archive's depth answers: " ^ why e) false
  | Ok json ->
      check "a question deeper than the archive is answered at its depth"
        (int_field "zoom" json = 12);
      check "and the tiles there are the ones that were downloaded"
        (String.for_all (fun c -> c = '1') (string_field "present" json)));
  (match
     query ~fs ~dir:dir_name ~min_lon:(-0.2) ~min_lat:51.45 ~max_lon:(-0.05)
       ~max_lat:51.55 ~zoom:9
   with
  | Error e -> check ("a shallower view answers: " ^ why e) false
  | Ok json ->
      check "a question inside the archive's depth is answered where it asked"
        (int_field "zoom" json = 9));

  (* With an overview and no downloaded detail, nothing clamps: there is no
     detail at any zoom, and dragging the question down to the overview's
     own depth would answer "present" and silence the offer to download
     the area being looked at. That is the state every fresh install starts
     in, so it is the one that matters most. *)
  let overview_only = Filename.concat root "overview-only" in
  Eio.Path.mkdir ~perm:0o755 Eio.Path.(fs / overview_only);
  write Eio.Path.(fs / overview_only) "world.pmtiles"
    (archive_of ~max_zoom:2 world);
  (match
     query ~fs ~dir:overview_only ~min_lon:(-0.2) ~min_lat:51.45
       ~max_lon:(-0.05) ~max_lat:51.55 ~zoom:15
   with
  | Error e -> check ("an overview-only view answers: " ^ why e) false
  | Ok json ->
      check "with no detail downloaded the question is answered where it asked"
        (int_field "zoom" json = 15);
      check "and says the detail is not there"
        (String.for_all (fun c -> c = '0') (string_field "present" json));
      check "while still reporting the overview underneath"
        (bool_field "floor" json = Some true));
  Eio.Path.unlink Eio.Path.(fs / overview_only / "world.pmtiles");
  Eio.Path.rmdir Eio.Path.(fs / overview_only);

  (* ------------------------------------------------------------- the floor *)
  (* The floor's depth is the deepest zoom the archives cover the WHOLE
     planet at, and it has to be measured rather than read off a header.
     Everything below turns on that difference: this archive's header says
     zoom 12, and a floor cut to 12 would be asking for tiles that exist
     over London and nowhere else -- which draws an empty tile over Tokyo,
     which is the bug the floor exists to prevent. *)
  let depth_of dir_name =
    Eio.Switch.run @@ fun sw ->
    Tessarium_server.Basemap_download.floor_depth
      (Tessarium_server.Basemap_download.whole_archives ~sw ~fs
         ~basemap_dir:dir_name
         (Tessarium_server.Basemap_download.tile_files ~fs ~basemap_dir:dir_name))
  in
  (* Two, not the twelve the header claims: a floor cut to twelve would ask
     for tiles that exist over London and nowhere else. *)
  check "the floor stops at the deepest zoom that covers the whole planet"
    (depth_of dir_name = 2);
  check "with no archive at all there is no floor" (depth_of empty = -1);
  (* A world overview on its own floors the planet -- it is the only archive
     there is, and it covers every tile of its own range. *)
  check "a world overview on its own is the floor" (depth_of world_only = 2);
  Eio.Path.unlink Eio.Path.(fs / world_only / "world.pmtiles");
  Eio.Path.rmdir Eio.Path.(fs / world_only);

  (* One tile short of a whole zoom level is not a whole zoom level. Removed
     from the far side of the world from London, so nothing else about the
     archive changes: without this the check above passes for an archive
     that merely reaches zoom 2 somewhere. *)
  let world_but_one =
    List.filter
      (fun id ->
        id
        <> Pmtiles.Tile_id.of_zxy ~z:2
             ~x:(Pmtiles.Tile_id.tile_x ~z:2 ~lon:139.7)
             ~y:(Pmtiles.Tile_id.tile_y ~z:2 ~lat:35.7))
      (List.sort_uniq compare (world @ london))
  in
  write dir "map.pmtiles" (archive_of ~max_zoom:12 world_but_one);
  check "one missing tile takes the floor up a level"
    (depth_of dir_name = 1);
  write dir "map.pmtiles"
    (archive_of ~max_zoom:12 (List.sort_uniq compare (world @ london)));

  (* A file cut short after its directories were written. This is what an
     interrupted fetch used to leave behind, and it is the one shape that
     can fool the scan: every lookup succeeds, and the reads behind half of
     them run off the end of the file and are served as "no tile here". A
     floor certified from the directory alone would be full of holes at its
     own declared depth -- the exact failure the floor exists to prevent. *)
  let whole = Eio.Path.load Eio.Path.(dir / "map.pmtiles") in
  write dir "map.pmtiles"
    (String.sub whole 0 (String.length whole - 1));
  check "an archive shorter than its own header says cannot floor anything"
    (depth_of dir_name = -1);
  (match
     query ~fs ~dir:dir_name ~min_lon:139.6 ~min_lat:35.6 ~max_lon:139.8
       ~max_lat:35.8 ~zoom:12
   with
  | Error e -> check ("a truncated archive still answers: " ^ why e) false
  | Ok json ->
      check "and the coverage answer says there is no floor"
        (bool_field "floor" json = Some false);
      (* Still serves what it really holds. Refusing the whole file would
         turn a partial download into no map at all; what it may not do is
         be counted towards a completeness claim. *)
      check "while still reporting the tiles it does hold"
        (int_field "depth" json = 2));
  write dir "map.pmtiles" whole;
  check "and the floor comes back when the file does"
    (depth_of dir_name = 2);

  (* A city and nothing else -- which still holds the single zoom-0 tile of
     the planet, because every download starts at zoom 0. That one tile IS
     the floor, and the app draws the world from it rather than nothing. *)
  let city_only = Filename.concat root "city" in
  Eio.Path.mkdir ~perm:0o755 Eio.Path.(fs / city_only);
  write Eio.Path.(fs / city_only) "map.pmtiles"
    (archive_of ~max_zoom:12
       (Pmtiles.Tile_id.covering ~min_zoom:0 ~max_zoom:12 ~min_lon:(-0.5)
          ~min_lat:51.3 ~max_lon:0.3 ~max_lat:51.7));
  check "one city still floors the world, from its zoom-0 tile"
    (depth_of city_only = 0);
  Eio.Path.unlink Eio.Path.(fs / city_only / "map.pmtiles");
  Eio.Path.rmdir Eio.Path.(fs / city_only);

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
