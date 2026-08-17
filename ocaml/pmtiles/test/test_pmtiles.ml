(* Tests for the PMTiles reader and extractor.

   The bug this suite exists to catch is not a crash. Directory entries store
   offsets relative to the data section, and an extract that treats one as
   absolute writes a file with a perfectly valid header whose every tile is
   garbage -- it reads tile bytes out of the root directory. Nothing detects
   that until a map renders blank. So the round-trip below builds an archive,
   reads it back, and compares tile payloads byte for byte. *)

module V = Pmtiles.Varint
module T = Pmtiles.Tile_id
module D = Pmtiles.Directory
module H = Pmtiles.Header
module A = Pmtiles.Archive
module E = Pmtiles.Extract

let failures = ref 0
let checks = ref 0

let check name ok =
  incr checks;
  if not ok then begin
    incr failures;
    Printf.printf "  FAIL  %s\n" name
  end

let () =
  (* ----------------------------------------------------------- varints *)
  List.iter
    (fun n ->
      let b = Buffer.create 16 in
      V.encode b n;
      let got, pos = V.decode (Buffer.contents b) 0 in
      check
        (Printf.sprintf "varint %d round-trips" n)
        (got = n && pos = Buffer.length b))
    [ 0; 1; 127; 128; 255; 300; 16383; 16384; 1 lsl 30; 1 lsl 50; max_int / 2 ];

  (* Several varints in sequence must be decodable one after another; the
     directory format depends on that and nothing else checks it. *)
  let b = Buffer.create 16 in
  List.iter (V.encode b) [ 1; 300; 0; 70000 ];
  let s = Buffer.contents b in
  let a, p1 = V.decode s 0 in
  let c, p2 = V.decode s p1 in
  let d, p3 = V.decode s p2 in
  let e, _ = V.decode s p3 in
  check "varint sequence decodes in order" (a = 1 && c = 300 && d = 0 && e = 70000);

  (* --------------------------------------------------------- tile ids *)
  check "zoom 0 is tile 0" (T.of_zxy ~z:0 ~x:0 ~y:0 = 0);
  check "zoom 1 starts at 1" (T.of_zxy ~z:1 ~x:0 ~y:0 = 1);
  check "zoom 2 starts at 5" (T.of_zxy ~z:2 ~x:0 ~y:0 = 5);
  check "zoom 3 starts at 21" (T.of_zxy ~z:3 ~x:0 ~y:0 = 21);

  (* The Hilbert index must be a bijection on each zoom: every tile gets an
     id, no two tiles share one, and the ids fill the range exactly. *)
  let bijective =
    List.for_all
      (fun z ->
        let n = 1 lsl z in
        let seen = Hashtbl.create (n * n) in
        let ok = ref true in
        for x = 0 to n - 1 do
          for y = 0 to n - 1 do
            let id = T.of_zxy ~z ~x ~y in
            if Hashtbl.mem seen id then ok := false;
            Hashtbl.replace seen id ();
            if id < T.tiles_before z || id >= T.tiles_before (z + 1) then
              ok := false;
            let z', x', y' = T.to_zxy id in
            if z' <> z || x' <> x || y' <> y then ok := false
          done
        done;
        !ok && Hashtbl.length seen = n * n)
      [ 0; 1; 2; 3; 4; 5; 6; 7; 8 ]
  in
  check "hilbert ids are a bijection and invert, zooms 0-8" bijective;

  (* Locality is the reason for the curve: neighbours on the ground should be
     close in the file. Checked as a property rather than exactly, since the
     curve does have jumps. *)
  let z = 8 in
  let jumps =
    let total = ref 0 and far = ref 0 in
    for x = 10 to 60 do
      for y = 10 to 60 do
        let a = T.of_zxy ~z ~x ~y and b = T.of_zxy ~z ~x:(x + 1) ~y in
        incr total;
        if abs (a - b) > 64 then incr far
      done
    done;
    float_of_int !far /. float_of_int !total
  in
  check
    (Printf.sprintf "hilbert keeps neighbours close (%.2f far)" jumps)
    (jumps < 0.2);

  (* A bounding box must cover the tiles containing its corners. *)
  let ids =
    T.covering ~min_zoom:0 ~max_zoom:5 ~min_lon:(-0.2) ~min_lat:51.4
      ~max_lon:0.1 ~max_lat:51.6
  in
  check "covering is sorted and unique"
    (ids = List.sort_uniq compare ids && ids <> []);
  check "covering includes the zoom 0 tile" (List.mem 0 ids);
  check "covering includes the corner tile at max zoom"
    (List.mem (T.of_zxy ~z:5 ~x:(T.tile_x ~z:5 ~lon:(-0.2)) ~y:(T.tile_y ~z:5 ~lat:51.6)) ids);

  (* --------------------------------------------------------- directories *)
  let entries =
    [|
      { D.tile_id = 0; offset = 0; length = 100; run_length = 1 };
      { D.tile_id = 1; offset = 100; length = 50; run_length = 3 };
      { D.tile_id = 5; offset = 150; length = 70; run_length = 1 };
      { D.tile_id = 900; offset = 9000; length = 20; run_length = 1 };
    |]
  in
  let back = D.deserialize (D.serialize entries) in
  check "directory round-trips" (back = entries);

  (* An exact hit, a hit inside a run, and a miss just past the run's end. *)
  check "find exact" (D.find entries 5 = Some entries.(2));
  check "find inside a run" (D.find entries 3 = Some entries.(1));
  check "find at the end of a run" (D.find entries 3 <> None);
  check "find past a run is a miss" (D.find entries 4 = None);
  check "find before everything is a miss" (D.find entries (-1) = None);
  check "find past everything is a miss" (D.find entries 10000 = None);

  (* A leaf pointer answers for anything at or after it, since the real entry
     lives in the leaf. *)
  let with_leaf =
    [| { D.tile_id = 0; offset = 0; length = 10; run_length = 0 } |]
  in
  check "leaf pointer is followed" (D.find with_leaf 12345 = Some with_leaf.(0));

  (* ------------------------------------------------- archive round-trip *)
  (* Build a source archive, extract a region from it, and read the extract
     back. Everything in memory, so this runs in CI with no network. *)
  let tile_bytes id = Printf.sprintf "tile-%d-%s" id (String.make (id mod 37) 'x') in

  let source_tiles = T.covering ~min_zoom:0 ~max_zoom:10 ~min_lon:(-1.) ~min_lat:50. ~max_lon:1. ~max_lat:52. in
  let data = Buffer.create 4096 in
  let src_entries =
    Array.of_list
      (List.map
         (fun id ->
           let payload = tile_bytes id in
           let offset = Buffer.length data in
           Buffer.add_string data payload;
           { D.tile_id = id; offset; length = String.length payload; run_length = 1 })
         source_tiles)
  in
  let root = D.serialize src_entries in
  let metadata = "{}" in
  let src_header =
    {
      H.root_offset = H.size;
      root_length = String.length root;
      metadata_offset = H.size + String.length root;
      metadata_length = String.length metadata;
      leaf_offset = H.size + String.length root + String.length metadata;
      leaf_length = 0;
      data_offset = H.size + String.length root + String.length metadata;
      data_length = Buffer.length data;
      addressed_tiles = Array.length src_entries;
      tile_entries = Array.length src_entries;
      tile_contents = Array.length src_entries;
      clustered = true;
      internal_compression = H.None_;
      tile_compression = H.None_;
      tile_type = H.Mvt;
      min_zoom = 0;
      max_zoom = 10;
      min_lon_e7 = -10000000;
      min_lat_e7 = 500000000;
      max_lon_e7 = 10000000;
      max_lat_e7 = 520000000;
      center_zoom = 3;
      center_lon_e7 = 0;
      center_lat_e7 = 510000000;
    }
  in
  let archive_bytes =
    H.serialize src_header ^ root ^ metadata ^ Buffer.contents data
  in
  let source_of s =
    { A.read = (fun ~offset ~length -> String.sub s offset (min length (String.length s - offset))) }
  in
  let archive = A.open_ (source_of archive_bytes) in
  check "reopened header matches" (archive.A.header = src_header);

  (* Every tile the source claims must read back byte-identical. This is the
     check that catches a relative offset used as an absolute one. *)
  let all_tiles_match =
    List.for_all
      (fun id ->
        match A.tile archive id with
        | Some got -> String.equal got (tile_bytes id)
        | None -> false)
      source_tiles
  in
  check "every source tile reads back exactly" all_tiles_match;

  (* Now extract a sub-region and confirm the same bytes survive. *)
  let plan =
    E.plan archive ~min_zoom:0 ~max_zoom:6 ~min_lon:(-0.5) ~min_lat:50.5
      ~max_lon:0.5 ~max_lat:51.5
  in
  check "plan found tiles" (Array.length plan.E.tiles > 0);
  check "plan deduplicates nothing here" (Array.length plan.E.blobs = Array.length plan.E.tiles);

  let out = Buffer.create 4096 in
  let append s = Buffer.add_string out s in
  let copy ~offset ~length = Buffer.add_string out (String.sub archive_bytes offset length) in
  let _ =
    E.write plan src_header ~min_zoom:0 ~max_zoom:6 ~min_lon:(-0.5)
      ~min_lat:50.5 ~max_lon:0.5 ~max_lat:51.5 ~append ~copy
  in
  let extracted = A.open_ (source_of (Buffer.contents out)) in
  let extracted_ok =
    Array.for_all
      (fun (id, _) ->
        match A.tile extracted id with
        | Some got -> String.equal got (tile_bytes id)
        | None -> false)
      plan.E.tiles
  in
  check "every extracted tile matches the source byte for byte" extracted_ok;
  check "extract reports the right tile count"
    (extracted.A.header.H.addressed_tiles = Array.length plan.E.tiles);
  check "extract is marked clustered" extracted.A.header.H.clustered;
  check "extract keeps the source tile compression"
    (extracted.A.header.H.tile_compression = src_header.H.tile_compression);

  (* A tile outside the extracted region must be absent, not silently
     answered with a neighbour's bytes. *)
  let outside =
    List.find_opt
      (fun id -> not (Array.exists (fun (t, _) -> t = id) plan.E.tiles))
      source_tiles
  in
  (match outside with
  | Some id ->
      check "a tile outside the region is absent, not a neighbour"
        (match A.tile extracted id with
         | None -> true
         | Some got -> String.equal got (tile_bytes id))
  | None -> ());

  (* Runs: consecutive tiles sharing a blob collapse to one entry. Built
     explicitly because a real archive's repeated ocean tiles are what make
     this matter. *)
  let shared = "same" in
  let run_data = Buffer.create 64 in
  Buffer.add_string run_data shared;
  let run_entries =
    Array.init 8 (fun i ->
        { D.tile_id = 21 + i; offset = 0; length = String.length shared; run_length = 1 })
  in
  let run_root = D.serialize run_entries in
  let run_header =
    { src_header with
      H.root_offset = H.size;
      root_length = String.length run_root;
      metadata_offset = H.size + String.length run_root;
      metadata_length = 0;
      leaf_offset = H.size + String.length run_root;
      leaf_length = 0;
      data_offset = H.size + String.length run_root;
      data_length = Buffer.length run_data;
      min_zoom = 3; max_zoom = 3 }
  in
  let run_archive =
    A.open_ (source_of (H.serialize run_header ^ run_root ^ Buffer.contents run_data))
  in
  let run_plan =
    E.plan run_archive ~min_zoom:3 ~max_zoom:3 ~min_lon:(-180.) ~min_lat:(-85.)
      ~max_lon:180. ~max_lat:85.
  in
  check "identical tiles are stored once"
    (Array.length run_plan.E.blobs = 1 && Array.length run_plan.E.tiles = 8);

  (* ------------------------------------------------------------- merge *)
  (* Extract one box, then merge a second, overlapping box into it. Every
     tile from BOTH must read back byte-identical, and -- base wins -- the
     bytes fetched for the second box must exclude everything the first
     already brought in. This is the property that makes "world map first,
     then detail" affordable: adding a city never re-downloads the world. *)
  let module M = Pmtiles.Merge in
  let extract_box ~min_lon ~max_lon =
    let p =
      E.plan archive ~min_zoom:0 ~max_zoom:10 ~min_lon ~min_lat:50.5 ~max_lon
        ~max_lat:51.5
    in
    let buf = Buffer.create 4096 in
    let _ =
      E.write p src_header ~min_zoom:0 ~max_zoom:10 ~min_lon ~min_lat:50.5
        ~max_lon ~max_lat:51.5
        ~append:(Buffer.add_string buf)
        ~copy:(fun ~offset ~length ->
          Buffer.add_string buf (String.sub archive_bytes offset length))
    in
    (p, Buffer.contents buf)
  in
  let plan_a, base_bytes = extract_box ~min_lon:(-0.5) ~max_lon:0.0 in
  let base_archive = A.open_ (source_of base_bytes) in
  let plan_b =
    E.plan archive ~min_zoom:0 ~max_zoom:10 ~min_lon:0.2 ~min_lat:50.5
      ~max_lon:0.8 ~max_lat:51.5
  in
  let merged_plan = M.plan ~base:(Some base_archive) plan_b in
  let in_base id = Array.exists (fun (t, _) -> t = id) plan_a.E.tiles in
  let expected_fresh =
    Array.to_list plan_b.E.tiles
    |> List.filter (fun (id, _) -> not (in_base id))
    |> List.length
  in
  check "a merge only fetches tiles the base lacks"
    (merged_plan.M.fresh_tiles = expected_fresh && expected_fresh > 0);
  check "overlapping low zooms are not re-fetched"
    (merged_plan.M.fetch_bytes < E.planned_bytes plan_b);
  let merged_buf = Buffer.create 4096 in
  let _ =
    M.write merged_plan src_header ~min_zoom:0 ~max_zoom:10 ~min_lon:(-0.5)
      ~min_lat:50.5 ~max_lon:0.8 ~max_lat:51.5
      ~append:(Buffer.add_string merged_buf)
      ~copy:(fun ~origin ~offset ~length ->
        let bytes =
          match origin with
          | M.Base -> String.sub base_bytes offset length
          | M.Fresh -> String.sub archive_bytes offset length
        in
        Buffer.add_string merged_buf bytes)
  in
  let merged = A.open_ (source_of (Buffer.contents merged_buf)) in
  let both =
    Array.to_list plan_a.E.tiles @ Array.to_list plan_b.E.tiles
    |> List.map fst |> List.sort_uniq compare
  in
  check "every tile from both boxes survives the merge byte for byte"
    (List.for_all
       (fun id ->
         match A.tile merged id with
         | Some got -> String.equal got (tile_bytes id)
         | None -> false)
       both);
  check "the merged archive reports the union's tile count"
    (merged.A.header.H.addressed_tiles = List.length both);
  check "a merge with no base is a plain extract"
    (let p = M.plan ~base:None plan_b in
     p.M.fetch_bytes = E.planned_bytes plan_b
     && p.M.fresh_tiles = Array.length plan_b.E.tiles);
  check "merging a region already held fetches nothing"
    (let again = M.plan ~base:(Some merged) plan_b in
     again.M.fresh_tiles = 0 && again.M.fetch_bytes = 0);

  Printf.printf "\n%d checks, %d failures\n" !checks !failures;
  if !failures > 0 then exit 1 else print_endline "pmtiles round-trips"
