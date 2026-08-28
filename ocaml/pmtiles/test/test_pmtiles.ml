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

  (* The entry count is the first thing off the wire and Array.make believes
     it. A short blob claiming a huge count allocates before anything can
     notice the bytes are not there -- and Archive.open_ arrives here with a
     length out of the header of a downloaded file. Four columns, one byte
     each at minimum, is the floor a real entry cannot go under. *)
  let refuses s =
    match D.deserialize s with
    | _ -> false
    | exception Invalid_argument _ -> true
  in
  (* Varint 0x80 0x80 0x80 0x80 0x01 = 2^28, in five bytes with nothing after. *)
  let overclaim = "\x80\x80\x80\x80\x01" in
  check "a directory claiming more entries than it holds is refused"
    (refuses overclaim);
  (* Refusing is not the point -- the truncated varint refuses anyway, one
     column in and two gigabytes of pointers later. What has to hold is that
     the ALLOCATION never happens, so it is the allocation that is measured.
     Without the bound this delta is about 2e9. *)
  let allocated f =
    let before = Gc.allocated_bytes () in
    (try ignore (f ()) with _ -> ());
    Gc.allocated_bytes () -. before
  in
  check "and refused before it allocates"
    (allocated (fun () -> D.deserialize overclaim) < 1e6);
  (* The floor is exact, so a directory sitting on it still parses. *)
  check "four entries in sixteen bytes still parse"
    (not (refuses (D.serialize entries)));

  (* ------------------------------------------------------------- gzip *)
  (* Directories and tiles arrive gzipped, out of an archive the user
     downloaded, and what comes out is bounded by nothing the compressed
     bytes declare. Two megabytes of zeroes is a few kilobytes gzipped. *)
  let bomb = Gzip.compress (String.make (2 * 1024 * 1024) '\000') in
  check "a small blob can inflate enormously"
    (String.length bomb < 16 * 1024);
  check "inflating within the limit is fine"
    (String.length (Gzip.decompress bomb) = 2 * 1024 * 1024);
  check "inflating past it stops"
    (match Gzip.decompress ~limit:(1024 * 1024) bomb with
     | _ -> false
     | exception Gzip.Bad_gzip _ -> true);
  (* And it stops WHILE inflating rather than after, or the bomb has already
     been held whole and the bound bought nothing. *)
  let allocated_by f =
    let before = Gc.allocated_bytes () in
    (try ignore (f ()) with _ -> ());
    Gc.allocated_bytes () -. before
  in
  check "and stops before the whole of it is held"
    (allocated_by (fun () -> Gzip.decompress ~limit:1024 bomb) < 1e6);

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

  (* --------------------------------------------------------- depth_for *)
  (* The budget that stops "download this view" from meaning forty million
     tiles. A city fits street level inside the same limit that stops the
     whole world at its overview zoom -- 8192 is the server's budget, and
     the world must land on 6 under it, because that is the world map the
     UI offers. *)
  check "a city box affords full depth"
    (T.depth_for ~min_zoom:0 ~max_zoom:15 ~min_lon:(-0.14) ~min_lat:51.49
       ~max_lon:(-0.11) ~max_lat:51.52 ~limit:8192
     = 15);
  check "the whole world stops at its overview zoom"
    (T.depth_for ~min_zoom:0 ~max_zoom:15 ~min_lon:(-180.) ~min_lat:(-85.)
       ~max_lon:180. ~max_lat:85. ~limit:8192
     = 6);
  check "a continent lands in between"
    (let d =
       T.depth_for ~min_zoom:0 ~max_zoom:15 ~min_lon:(-130.) ~min_lat:20.
         ~max_lon:(-60.) ~max_lat:55. ~limit:8192
     in
     d > 6 && d < 15);
  check "depth never sinks below min_zoom"
    (T.depth_for ~min_zoom:0 ~max_zoom:15 ~min_lon:(-180.) ~min_lat:(-85.)
       ~max_lon:180. ~max_lat:85. ~limit:1
     = 0);

  (* ------------------------------------------------------ download_parts *)
  (* An explicit country or state gets the full ask; a giant splits into
     parts that each fit; only a near-planetary box falls back, and says
     so. Limits here are the server's real ones. *)
  let dp ~min_lon ~min_lat ~max_lon ~max_lat =
    T.download_parts ~min_zoom:0 ~requested:15 ~min_lon ~min_lat ~max_lon
      ~max_lat ~full_limit:6_000_000 ~quick_limit:131_072 ~max_parts:8 ()
  in
  check "France gets street level in one piece"
    (dp ~min_lon:(-5.1) ~min_lat:41.3 ~max_lon:9.6 ~max_lat:51.1
     = ([ (-5.1, 41.3, 9.6, 51.1) ], 15, false));
  check "California gets street level in one piece"
    (let parts, depth, clamped =
       dp ~min_lon:(-124.4) ~min_lat:32.5 ~max_lon:(-114.1) ~max_lat:42.0
     in
     List.length parts = 1 && depth = 15 && not clamped);
  check "Brazil gets street level, split into parts"
    (let parts, depth, clamped =
       dp ~min_lon:(-74.0) ~min_lat:(-33.8) ~max_lon:(-34.7) ~max_lat:5.3
     in
     (not clamped) && depth = 15
     && List.length parts > 1
     && List.length parts <= 8);
  check "the whole world falls back to a quick plan"
    (let parts, depth, clamped =
       dp ~min_lon:(-180.) ~min_lat:(-85.) ~max_lon:180. ~max_lat:85.
     in
     clamped && depth < 12 && List.length parts = 1);

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
  let merged_plan = M.plan ~base:(Some base_archive) [ plan_b ] in
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
      ~copy:(fun ~index:_ ~origin ~offset ~length ->
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
    (let p = M.plan ~base:None [ plan_b ] in
     p.M.fetch_bytes = E.planned_bytes plan_b
     && p.M.fresh_tiles = Array.length plan_b.E.tiles);
  check "merging a region already held fetches nothing"
    (let again = M.plan ~base:(Some merged) [ plan_b ] in
     again.M.fresh_tiles = 0 && again.M.fetch_bytes = 0);

  (* ------------------------------------------------- multi-region merge *)
  (* One request may name several regions. They dedup against each other by
     tile id, exactly as each dedups against the base: naming a country and
     also one of its cities pays for the shared tiles once. *)
  check "a region named twice in one request costs once"
    (let twice = M.plan ~base:None [ plan_b; plan_b ] in
     let once = M.plan ~base:None [ plan_b ] in
     twice.M.fetch_bytes = once.M.fetch_bytes
     && twice.M.fresh_tiles = once.M.fresh_tiles);
  let multi = M.plan ~base:None [ plan_a; plan_b ] in
  check "overlapping regions dedup the zooms they share"
    (multi.M.fetch_bytes
     < E.planned_bytes plan_a + E.planned_bytes plan_b
    && multi.M.fresh_tiles = List.length both);
  (* Downloading both boxes in one request must build the same archive as
     downloading one and then merging in the other. *)
  let multi_buf = Buffer.create 4096 in
  let _ =
    M.write multi src_header ~min_zoom:0 ~max_zoom:10 ~min_lon:(-0.5)
      ~min_lat:50.5 ~max_lon:0.8 ~max_lat:51.5
      ~append:(Buffer.add_string multi_buf)
      ~copy:(fun ~index:_ ~origin ~offset ~length ->
        match origin with
        | M.Fresh ->
            Buffer.add_string multi_buf (String.sub archive_bytes offset length)
        | M.Base -> assert false (* no base, no Base blobs *))
  in
  check "both boxes in one request equal extract-then-merge byte for byte"
    (String.equal (Buffer.contents multi_buf) (Buffer.contents merged_buf));

  (* ---------------------------------------------------- download parts *)
  (* Splitting is what lets a giant box keep full depth: every part must
     plan under the limit, and the union of the parts' ids must be exactly
     the box's ids -- coverage is the correctness property, and seams may
     overlap by a tile row without harm because the merge dedups by id. *)
  let europe = (-10.0, 40.0, 10.0, 55.0) in
  let ids (a, b, c, d) =
    T.covering ~min_zoom:0 ~max_zoom:8 ~min_lon:a ~min_lat:b ~max_lon:c
      ~max_lat:d
  in
  let full_ids = ids europe in
  let limit = List.length full_ids / 3 in
  let dp ~full_limit ~max_parts =
    let a, b, c, d = europe in
    T.download_parts ~min_zoom:0 ~requested:8 ~min_lon:a ~min_lat:b ~max_lon:c
      ~max_lat:d ~full_limit ~quick_limit:64 ~max_parts ()
  in
  let parts, depth, clamped = dp ~full_limit:limit ~max_parts:8 in
  check "a giant box splits rather than clamps"
    ((not clamped) && depth = 8 && List.length parts > 1
    && List.length parts <= 8);
  check "every part plans within the limit"
    (List.for_all
       (fun (a, b, c, d) ->
         T.count_ids ~min_zoom:0 ~max_zoom:8 ~min_lon:a ~min_lat:b ~max_lon:c
           ~max_lat:d
         <= limit)
       parts);
  check "the parts cover exactly the box's ids"
    (List.concat_map ids parts |> List.sort_uniq compare = full_ids);
  check "a box within the limit stays whole"
    (let parts, depth, clamped =
       dp ~full_limit:(List.length full_ids) ~max_parts:8
     in
     parts = [ europe ] && depth = 8 && not clamped);
  check "too big for the part budget falls back to a quick clamp"
    (let parts, depth, clamped = dp ~full_limit:(limit / 64) ~max_parts:2 in
     clamped && depth < 8 && List.length parts = 1);

  (* -------------------------------------------------------------- clip *)
  (* The quadtree walk must agree exactly with the definition it optimises:
     a tile is kept iff its box is not Outside the polygon. Brute force at
     modest zooms is the oracle. *)
  let module C = Pmtiles.Clip in
  let triangle =
    C.of_rings [| [| (-8.0, 42.0); (6.0, 43.5); (-1.0, 53.0) |] |]
  in
  let clip_box = (-12.0, 40.0, 9.0, 55.0) in
  let brute ~min_zoom ~max_zoom (a, b, c, d) clip =
    T.covering ~min_zoom ~max_zoom ~min_lon:a ~min_lat:b ~max_lon:c ~max_lat:d
    |> List.filter (fun id ->
           let z, x, y = T.to_zxy id in
           let bx0, by0, bx1, by1 = T.tile_box ~z ~x ~y in
           C.classify clip ~min_x:bx0 ~min_y:by0 ~max_x:bx1 ~max_y:by1
           <> C.Outside)
  in
  let clipped ~min_zoom ~max_zoom (a, b, c, d) clip =
    T.covering_clipped ~min_zoom ~max_zoom ~min_lon:a ~min_lat:b ~max_lon:c
      ~max_lat:d ~clip ()
  in
  check "clipped covering equals the per-tile definition"
    (clipped ~min_zoom:0 ~max_zoom:7 clip_box triangle
    = brute ~min_zoom:0 ~max_zoom:7 clip_box triangle);
  check "clipping strictly shrinks a box that outgrows the polygon"
    (let all =
       T.covering ~min_zoom:0 ~max_zoom:7 ~min_lon:(-12.0) ~min_lat:40.0
         ~max_lon:9.0 ~max_lat:55.0
     in
     let kept = clipped ~min_zoom:0 ~max_zoom:7 clip_box triangle in
     List.length kept > 0 && List.length kept < List.length all);
  check "clipped count agrees with clipped covering"
    (let a, b, c, d = clip_box in
     T.count_ids_clipped ~min_zoom:0 ~max_zoom:7 ~min_lon:a ~min_lat:b
       ~max_lon:c ~max_lat:d ~clip:triangle ()
     = List.length (clipped ~min_zoom:0 ~max_zoom:7 clip_box triangle));
  let unit_square = C.of_rings [| [| (0., 0.); (10., 0.); (10., 10.); (0., 10.) |] |] in
  check "a box wholly inside the ring is Inside"
    (C.classify unit_square ~min_x:4. ~min_y:4. ~max_x:6. ~max_y:6. = C.Inside);
  check "a box wholly outside the ring is Outside"
    (C.classify unit_square ~min_x:14. ~min_y:4. ~max_x:16. ~max_y:6.
     = C.Outside);
  check "a box the border passes through is Boundary"
    (C.classify unit_square ~min_x:8. ~min_y:4. ~max_x:12. ~max_y:6.
     = C.Boundary);
  check "a ring wholly inside the box is Boundary, never Outside"
    (C.classify unit_square ~min_x:(-5.) ~min_y:(-5.) ~max_x:15. ~max_y:15.
     = C.Boundary);
  check "a multipolygon is the union of its rings"
    (let two =
       C.of_rings
         [|
           [| (-8.0, 42.0); (-4.0, 42.0); (-6.0, 46.0) |];
           [| (2.0, 48.0); (6.0, 48.0); (4.0, 52.0) |];
         |]
     in
     clipped ~min_zoom:2 ~max_zoom:7 clip_box two
     = brute ~min_zoom:2 ~max_zoom:7 clip_box two);
  (* Zoom 9, not 7: at toy scales every part re-counts its shared low-zoom
     ancestors, which swamps the limit and forbids any split -- a modelling
     artifact of tiny numbers, not of production, where ancestors are noise
     against millions of deep ids. *)
  check "a clipped split still covers exactly the clipped ids"
    (let a, b, c, d = clip_box in
     let full = clipped ~min_zoom:0 ~max_zoom:9 clip_box triangle in
     match
       T.split ~clip:triangle ~min_zoom:0 ~max_zoom:9 ~min_lon:a ~min_lat:b
         ~max_lon:c ~max_lat:d
         ~limit:(List.length full / 3)
         ~max_parts:8 ()
     with
     | None -> false
     | Some parts ->
         List.length parts > 1
         && List.concat_map
              (fun box -> clipped ~min_zoom:0 ~max_zoom:9 box triangle)
              parts
            |> List.sort_uniq compare = full);

  (* --------------------------------------------------- archive metadata *)
  (* The download ledger rides in the metadata section, so what a writer is
     given must be exactly what a reader gets back -- byte for byte, with
     the tiles unharmed around it. *)
  let meta = {|{"tessarium_ledger":{"v":1,"entries":[]}}|} in
  let with_meta =
    let p =
      E.plan archive ~min_zoom:0 ~max_zoom:10 ~min_lon:(-0.5) ~min_lat:50.5
        ~max_lon:0.0 ~max_lat:51.5
    in
    let buf = Buffer.create 4096 in
    let _ =
      E.write ~metadata:meta p src_header ~min_zoom:0 ~max_zoom:10
        ~min_lon:(-0.5) ~min_lat:50.5 ~max_lon:0.0 ~max_lat:51.5
        ~append:(Buffer.add_string buf)
        ~copy:(fun ~offset ~length ->
          Buffer.add_string buf (String.sub archive_bytes offset length))
    in
    A.open_ (source_of (Buffer.contents buf))
  in
  check "written metadata reads back byte for byte"
    (A.metadata with_meta = meta);
  check "tiles read exactly around a metadata payload"
    (Array.for_all
       (fun (id, _) ->
         match A.tile with_meta id with
         | Some got -> String.equal got (tile_bytes id)
         | None -> false)
       plan_a.E.tiles);
  check "the default metadata stays the empty object"
    (A.metadata merged = "{}");

  (* ------------------------------------------------------- refresh merge *)
  (* An update inverts exactly one tie: every tile of the region is fetched
     fresh and replaces its held copy, tiles outside the region stay Base,
     and nothing else about the merge changes. *)
  let refreshed = M.plan ~refresh:true ~base:(Some merged) [ plan_b ] in
  check "a refresh re-fetches every tile of its region"
    (refreshed.M.refreshed_tiles = Array.length plan_b.E.tiles
    && refreshed.M.fresh_tiles = 0
    && refreshed.M.fetch_bytes = E.planned_bytes plan_b);
  check "without refresh the same plan fetches nothing"
    (let p = M.plan ~base:(Some merged) [ plan_b ] in
     p.M.refreshed_tiles = 0 && p.M.fetch_bytes = 0);
  check "a refresh never drops a tile"
    (Array.length refreshed.M.tiles = List.length both);
  check "tiles outside the refreshed region stay on disk"
    (let fresh_ids =
       Array.to_list plan_b.E.tiles |> List.map fst |> List.sort_uniq compare
     in
     Array.for_all
       (fun (id, blob) ->
         let origin, _, _ = refreshed.M.blobs.(blob) in
         if List.mem id fresh_ids then origin = M.Fresh else origin = M.Base)
       refreshed.M.tiles);
  check "a refreshed archive reads back byte-identical tiles"
    (let buf = Buffer.create 4096 in
     let _ =
       M.write refreshed src_header ~min_zoom:0 ~max_zoom:10 ~min_lon:(-0.5)
         ~min_lat:50.5 ~max_lon:0.8 ~max_lat:51.5
         ~append:(Buffer.add_string buf)
         ~copy:(fun ~index:_ ~origin ~offset ~length ->
           Buffer.add_string buf
             (match origin with
             | M.Base -> String.sub (Buffer.contents merged_buf) offset length
             | M.Fresh -> String.sub archive_bytes offset length))
     in
     let a = A.open_ (source_of (Buffer.contents buf)) in
     List.for_all
       (fun id ->
         match A.tile a id with
         | Some got -> String.equal got (tile_bytes id)
         | None -> false)
       both);

  (* --------------------------------------------------------------- prune *)
  (* Removal is a filter over the base with blob sharing honoured: a blob
     leaves only when its last referencing tile does. *)
  let b_exclusive =
    Array.to_list plan_b.E.tiles |> List.map fst
    |> List.filter (fun id ->
           not (Array.exists (fun (t, _) -> t = id) plan_a.E.tiles))
  in
  let drop_b ~z ~x ~y = List.mem (T.of_zxy ~z ~x ~y) b_exclusive in
  let pruned, dropped = M.prune ~base:merged ~drop:drop_b () in
  check "prune drops exactly the named tiles"
    (dropped = List.length b_exclusive
    && Array.length pruned.M.tiles
       = List.length both - List.length b_exclusive);
  check "prune fetches nothing" (pruned.M.fetch_bytes = 0);
  check "a pruned archive keeps survivors byte for byte and loses the rest"
    (let buf = Buffer.create 4096 in
     let _ =
       M.write pruned src_header ~min_zoom:0 ~max_zoom:10 ~min_lon:(-0.5)
         ~min_lat:50.5 ~max_lon:0.8 ~max_lat:51.5
         ~append:(Buffer.add_string buf)
         ~copy:(fun ~index:_ ~origin:_ ~offset ~length ->
           Buffer.add_string buf
             (String.sub (Buffer.contents merged_buf) offset length))
     in
     let a = A.open_ (source_of (Buffer.contents buf)) in
     List.for_all
       (fun id ->
         match A.tile a id with
         | Some got ->
             (not (List.mem id b_exclusive))
             && String.equal got (tile_bytes id)
         | None -> List.mem id b_exclusive)
       both);
  check "prune with nothing to drop keeps every tile"
    (let all, none = M.prune ~base:merged ~drop:(fun ~z:_ ~x:_ ~y:_ -> false) () in
     none = 0 && Array.length all.M.tiles = List.length both);

  (* ------------------------------------------------ newest planet build *)
  (* The default source resolves "latest" against the Protomaps build
     listing, because the old stable URL was deleted from under the project
     and only ~60 dated builds exist at a time. These pin the parsing: the
     listing's own order is not trusted, and junk entries are skipped rather
     than fatal. *)
  let entry key = Printf.sprintf {|{"key":"%s","size":1}|} key in
  let listing keys = "[" ^ String.concat "," (List.map entry keys) ^ "]" in
  check "newest build wins regardless of listing order"
    (Pmtiles_source.newest_build
       (listing [ "20260817.pmtiles"; "20260818.pmtiles"; "20230918.pmtiles" ])
    = Ok "https://build.protomaps.com/20260818.pmtiles");
  check "non-dated keys are skipped"
    (Pmtiles_source.newest_build
       (listing [ "latest.pmtiles"; "20260801.pmtiles"; "readme.txt" ])
    = Ok "https://build.protomaps.com/20260801.pmtiles");
  check "entries without a key are skipped"
    (Pmtiles_source.newest_build
       {|[{"size":1},{"key":7},{"key":"20260801.pmtiles","size":1}]|}
    = Ok "https://build.protomaps.com/20260801.pmtiles");
  check "an empty listing is an error"
    (match Pmtiles_source.newest_build "[]" with
    | Error _ -> true
    | Ok _ -> false);
  check "a listing of only junk is an error"
    (match Pmtiles_source.newest_build (listing [ "latest.pmtiles" ]) with
    | Error _ -> true
    | Ok _ -> false);
  check "non-JSON is an error, not an exception"
    (match Pmtiles_source.newest_build "<html>Not Found</html>" with
    | Error _ -> true
    | Ok _ -> false);
  check "a JSON object is an error, not an exception"
    (match Pmtiles_source.newest_build {|{"builds":[]}|} with
    | Error _ -> true
    | Ok _ -> false);

  (* ------------------------------------------------------------- mvt *)
  (* Names come off real tiles or the search index has nothing to offer, and
     the failure mode of a protobuf reader is silence: a misread field and
     the layer simply looks empty. Built here rather than fetched so the
     expected answer is known exactly. *)
  let varint n =
    let b = Buffer.create 4 in
    let rec go n =
      if n < 0x80 then Buffer.add_char b (Char.chr n)
      else begin
        Buffer.add_char b (Char.chr (0x80 lor (n land 0x7f)));
        go (n lsr 7)
      end
    in
    go n;
    Buffer.contents b
  in
  let key f w = varint ((f lsl 3) lor w) in
  let vfield f v = key f 0 ^ varint v in
  let bfield f s = key f 2 ^ varint (String.length s) ^ s in
  (* One point at the tile's centre, named, with a kind and a population. *)
  let geometry = varint 9 ^ varint 4096 ^ varint 4096 in
  let feature =
    vfield 3 1
    ^ bfield 2 (varint 0 ^ varint 0 ^ varint 1 ^ varint 1 ^ varint 2 ^ varint 2)
    ^ bfield 4 geometry
  in
  let layer =
    vfield 15 2 ^ bfield 1 "places" ^ bfield 2 feature ^ bfield 3 "name"
    ^ bfield 3 "kind" ^ bfield 3 "population"
    ^ bfield 4 (bfield 1 "Fixtureville")
    ^ bfield 4 (bfield 1 "locality")
    ^ bfield 4 (vfield 4 4242)
    ^ vfield 5 4096
  in
  let tile = bfield 3 layer in
  (match Pmtiles.Mvt.named ~z:0 ~x:0 ~y:0 tile with
  | [ (layer_name, name, kind, weight, lon, lat) ] ->
      check "a tile's named feature is read whole"
        (layer_name = "places" && name = "Fixtureville" && kind = "locality"
       && weight = 4242.);
      (* Deliberately NOT the centre of the world: at z0 the middle of the
         extent is (0, 0), which a swapped axis, a flipped y or a missing
         projection all still produce. *)
      check "and placed where the geometry says"
        (Float.abs lon < 0.001 && Float.abs lat < 0.001)
  | other ->
      check
        (Printf.sprintf "a tile's named feature is read whole (got %d)"
           (List.length other))
        false);

  (* What a place IS, as specifically as the basemap can say it.

     Every populated place has kind "locality" -- a capital, a town and a
     hamlet of nine alike -- so a search for a name eight towns share
     answered with eight identical rows. `kind_detail` is the word a person
     would use, and for places it is the one to show. *)
  let with_detail =
    bfield 3
      (vfield 15 2 ^ bfield 1 "places" ^ bfield 2 feature ^ bfield 3 "name"
     ^ bfield 3 "kind" ^ bfield 3 "kind_detail"
      ^ bfield 4 (bfield 1 "Fixtureville")
      ^ bfield 4 (bfield 1 "locality")
      ^ bfield 4 (bfield 1 "town")
      ^ vfield 5 4096)
  in
  check "a place is named as specifically as the tile can"
    (match Pmtiles.Mvt.named ~z:0 ~x:0 ~y:0 with_detail with
    | [ (_, _, kind, _, _, _) ] -> kind = "town"
    | _ -> false);
  (* A road's detail is more specific but less readable -- "primary" where
     the kind is "major road" -- and only places have the problem this
     solves, so only places take the swap. *)
  let road_detail =
    bfield 3
      (vfield 15 2 ^ bfield 1 "roads" ^ bfield 2 feature ^ bfield 3 "name"
     ^ bfield 3 "kind" ^ bfield 3 "kind_detail"
      ^ bfield 4 (bfield 1 "Fixture Road")
      ^ bfield 4 (bfield 1 "major_road")
      ^ bfield 4 (bfield 1 "primary")
      ^ vfield 5 4096)
  in
  check "every other layer keeps the kind it always had"
    (match Pmtiles.Mvt.named ~z:0 ~x:0 ~y:0 road_detail with
    | [ (_, _, kind, _, _, _) ] -> kind = "major_road"
    | _ -> false);
  (* Most places carry no detail at all; those must not lose their kind. *)
  check "and a place with no detail keeps its kind"
    (match Pmtiles.Mvt.named ~z:0 ~x:0 ~y:0 tile with
    | [ (_, _, kind, _, _, _) ] -> kind = "locality"
    | _ -> false);
  check "a feature with no name is not a place"
    (Pmtiles.Mvt.named ~z:0 ~x:0 ~y:0
       (bfield 3 (vfield 15 2 ^ bfield 1 "roads"
                  ^ bfield 2 (vfield 3 1 ^ bfield 4 geometry)
                  ^ vfield 5 4096))
    = []);
  (* Unknown fields are the normal case against a real basemap, which carries
     more than this reads; skipping them by wire type must not derail it. *)
  let with_extra =
    bfield 3
      (vfield 15 2 ^ vfield 99 7 ^ bfield 1 "places" ^ bfield 2 feature
     ^ bfield 3 "name" ^ bfield 3 "kind" ^ bfield 3 "population"
     ^ bfield 4 (bfield 1 "Fixtureville")
     ^ bfield 4 (bfield 1 "locality")
     ^ bfield 4 (vfield 4 4242)
     ^ vfield 5 4096)
  in
  check "a field this reader does not know is stepped over"
    (List.length (Pmtiles.Mvt.named ~z:0 ~x:0 ~y:0 with_extra) = 1);
  (* Off-centre, in a tile that is not the world: this is the assertion that
     a swapped axis or a dropped projection fails. Tile (1,0) at z2 spans
     lon -90..-45 and lat 66.51..85.05. The geometry is zigzag-encoded, so
     the stored 2048 is a delta of 1024 -- a quarter into the tile, which
     both coordinates have to agree on. *)
  let quarter = varint 9 ^ varint (2 * 1024) ^ varint (2 * 1024) in
  let off_centre =
    bfield 3
      (vfield 15 2 ^ bfield 1 "places"
      ^ bfield 2
          (vfield 3 1
          ^ bfield 2 (varint 0 ^ varint 0)
          ^ bfield 4 quarter)
      ^ bfield 3 "name"
      ^ bfield 4 (bfield 1 "Corner")
      ^ vfield 5 4096)
  in
  (match Pmtiles.Mvt.named ~z:2 ~x:1 ~y:0 off_centre with
  | [ (_, _, _, _, lon, lat) ] ->
      check
        (Printf.sprintf "a point off the tile's centre projects back (%.3f, %.3f)"
           lon lat)
        (Float.abs (lon -. (-67.5)) < 0.01 && Float.abs (lat -. 82.676) < 0.01)
  | _ -> check "a point off the tile's centre projects back" false);
  (* A length that would overflow the bounds check it must fail. *)
  check "a length near max_int is refused, not wrapped"
    (match
       Pmtiles.Mvt.named ~z:0 ~x:0 ~y:0
         ("\x1a" ^ "\xff\xff\xff\xff\xff\xff\xff\xff\x3f" ^ "pad")
     with
    | _ -> false
    | exception Pmtiles.Mvt.Malformed _ -> true);
  check "a truncated fixed32 value is refused"
    (match
       Pmtiles.Mvt.named ~z:0 ~x:0 ~y:0
         (bfield 3
            (vfield 15 2 ^ bfield 1 "p" ^ bfield 4 (key 2 5 ^ "\x01\x02")))
     with
    | _ -> false
    | exception Pmtiles.Mvt.Malformed _ -> true);
    check "rubbish is refused rather than guessed at"
    (match Pmtiles.Mvt.named ~z:0 ~x:0 ~y:0 "\xff\xff\xff" with
    | _ -> false
    | exception Pmtiles.Mvt.Malformed _ -> true);

  Printf.printf "\n%d checks, %d failures\n" !checks !failures;
  if !failures > 0 then exit 1 else print_endline "pmtiles round-trips"
