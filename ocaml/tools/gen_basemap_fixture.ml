(* Emits the basemap fixture the end-to-end test downloads from, so the e2e
   exercises the whole downloader -- range requests, extraction, the assets
   tarball -- against this project's own server, touching no external network.

   Two files land in the directory named by argv(1):

   - map.pmtiles: a small but valid archive covering central London at zooms
     0-15. Every tile is the same hand-encoded MVT -- one layer, one point --
     which MapLibre must parse without a console error, and console errors
     fail the e2e. The layer matches nothing in the style, so nothing is
     drawn and no glyphs are requested; validity is the point, not scenery.

   - assets.tar.gz: the sprite sheets the style asks for on load, plus one
     glyph file so the fonts/ directory exists, wrapped in a top-level
     directory the way GitHub's tarballs are, because the server's untar
     strips exactly that shape. *)

(* --------------------------------------------------------------- protobuf *)

let varint n =
  let buf = Buffer.create 4 in
  let rec go n =
    if n < 0x80 then Buffer.add_char buf (Char.chr n)
    else begin
      Buffer.add_char buf (Char.chr (0x80 lor (n land 0x7f)));
      go (n lsr 7)
    end
  in
  go n;
  Buffer.contents buf

let key field wire = varint ((field lsl 3) lor wire)
let varint_field field v = key field 0 ^ varint v
let bytes_field field s = key field 2 ^ varint (String.length s) ^ s

(* Mapbox Vector Tile: layer version 2, extent 4096, one POINT feature at
   (25, 25) -- MoveTo command 9, then the coordinates zigzag-encoded. *)
let mvt_tile =
  let geometry = varint 9 ^ varint 50 ^ varint 50 in
  let feature = varint_field 3 1 ^ bytes_field 4 geometry in
  let layer =
    varint_field 15 2
    ^ bytes_field 1 "fixture"
    ^ bytes_field 2 feature
    ^ varint_field 5 4096
  in
  (* A second layer shaped like the real basemap's: one named place, with a
     kind and a population, so the search index has something to find and
     something to rank. Named after nothing real -- a fixture that shared a
     name with a place on Earth would make a passing test ambiguous. *)
  let named_feature =
    (* tags: name -> "Fixtureville", kind -> "locality", population -> 4242 *)
    let tags = varint 0 ^ varint 0 ^ varint 1 ^ varint 1 ^ varint 2 ^ varint 2 in
    varint_field 3 1
    ^ bytes_field 2 tags
    ^ bytes_field 4 geometry
  in
  let str_value v = bytes_field 1 v in
  let int_value n = varint_field 4 n in
  let places =
    varint_field 15 2
    ^ bytes_field 1 "places"
    ^ bytes_field 2 named_feature
    ^ bytes_field 3 "name"
    ^ bytes_field 3 "kind"
    ^ bytes_field 3 "population"
    ^ bytes_field 4 (str_value "Fixtureville")
    ^ bytes_field 4 (str_value "locality")
    ^ bytes_field 4 (int_value 4242)
    ^ varint_field 5 4096
  in
  bytes_field 3 layer ^ bytes_field 3 places

(* ---------------------------------------------------------------- pmtiles *)

let e7 v = int_of_float (Float.round (v *. 1e7))

(* [stride], when set, gives every tile id its OWN copy of the blob, that far
   apart in the data section. The archive says the same thing either way --
   the tiles are identical -- but the reads needed to fetch it are not: with
   one shared blob a whole region is a single range request, and with a
   stride wider than the reader's readahead window each tile costs its own.
   That is the difference between a download that finishes instantly and one
   that can be watched, and the cancellation test needs the latter. *)
let pmtiles ?(metadata = "{}") ?(compression = Pmtiles.Header.Gzip)
    ?(stride = 0) ~min_lon
    ~min_lat ~max_lon ~max_lat ~max_zoom () =
  let ids =
    Pmtiles.Tile_id.covering ~min_zoom:0 ~max_zoom ~min_lon ~min_lat ~max_lon
      ~max_lat
  in
  (* Gzipped, like the real planet build: this is what makes the e2e suite
     exercise the content-encoding path the browser actually decodes, not
     only the trivial identity one. *)
  let tile =
    match compression with
    | Pmtiles.Header.Gzip -> Gzip.compress mvt_tile
    | _ -> mvt_tile
  in
  (* Every id points at the one blob at data offset 0, unless a stride
     spreads them out. *)
  let entries =
    List.mapi
      (fun i id ->
        {
          Pmtiles.Directory.tile_id = id;
          offset = (if stride > 0 then i * stride else 0);
          length = String.length tile;
          run_length = 1;
        })
      ids
    |> Array.of_list
  in
  let data =
    if stride = 0 then tile
    else begin
      let count = Array.length entries in
      let b = Buffer.create (count * stride) in
      for _ = 1 to count do
        Buffer.add_string b tile;
        Buffer.add_string b (String.make (stride - String.length tile) '\000')
      done;
      Buffer.contents b
    end
  in
  let root = Pmtiles.Directory.serialize entries in
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
      data_length = String.length data;
      addressed_tiles = Array.length entries;
      tile_entries = Array.length entries;
      tile_contents = (if stride > 0 then Array.length entries else 1);
      clustered = true;
      internal_compression = Pmtiles.Header.None_;
      tile_compression = compression;
      tile_type = Pmtiles.Header.Mvt;
      min_zoom = 0;
      max_zoom;
      min_lon_e7 = e7 min_lon;
      min_lat_e7 = e7 min_lat;
      max_lon_e7 = e7 max_lon;
      max_lat_e7 = e7 max_lat;
      center_zoom = 10;
      center_lon_e7 = e7 ((min_lon +. max_lon) /. 2.);
      center_lat_e7 = e7 ((min_lat +. max_lat) /. 2.);
    }
  in
  Pmtiles.Header.serialize header ^ root ^ metadata ^ data

(* -------------------------------------------------------------------- tar *)

let tar_entry name content =
  let b = Bytes.make 512 '\000' in
  Bytes.blit_string name 0 b 0 (String.length name);
  Bytes.blit_string "0000644" 0 b 100 7;
  Bytes.blit_string "0000000" 0 b 108 7;
  Bytes.blit_string "0000000" 0 b 116 7;
  Bytes.blit_string (Printf.sprintf "%011o" (String.length content)) 0 b 124 11;
  Bytes.blit_string "00000000000" 0 b 136 11;
  Bytes.set b 156 '0';
  Bytes.blit_string "ustar\000" 0 b 257 6;
  Bytes.blit_string "00" 0 b 263 2;
  (* The checksum is the byte sum of the header with this field as spaces. *)
  Bytes.blit_string "        " 0 b 148 8;
  let sum = ref 0 in
  Bytes.iter (fun c -> sum := !sum + Char.code c) b;
  Bytes.blit_string (Printf.sprintf "%06o\000 " !sum) 0 b 148 8;
  let pad = (512 - (String.length content mod 512)) mod 512 in
  Bytes.to_string b ^ content ^ String.make pad '\000'

(* A 1x1 transparent PNG. MapLibre decodes the sprite sheet on load, so the
   bytes must be a real image; the e2e's console-error check is what proves
   they are. *)
let png =
  "\x89PNG\r\n\x1a\n"
  ^ "\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89"
  ^ "\x00\x00\x00\x0aIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\x0d\x0a\x2d\xb4"
  ^ "\x00\x00\x00\x00IEND\xaeB`\x82"

let assets_tarball () =
  let w = "basemaps-assets-fixture/" in
  tar_entry (w ^ "sprites/v4/light.json") "{}"
  ^ tar_entry (w ^ "sprites/v4/light.png") png
  ^ tar_entry (w ^ "sprites/v4/light@2x.json") "{}"
  ^ tar_entry (w ^ "sprites/v4/light@2x.png") png
  ^ tar_entry (w ^ "fonts/Noto Sans Regular/0-255.pbf") ""
  ^ String.make 1024 '\000'

(* ------------------------------------------------------------------- main *)

let write path content =
  let oc = open_out_bin path in
  output_string oc content;
  close_out oc

let () =
  let dir = Sys.argv.(1) in
  if not (Sys.file_exists dir) then Sys.mkdir dir 0o755;
  let london ?metadata ?compression () =
    pmtiles ?metadata ?compression ~min_lon:(-0.20) ~min_lat:51.46
      ~max_lon:(-0.05) ~max_lat:51.56 ~max_zoom:15 ()
  in
  write (Filename.concat dir "map.pmtiles") (london ());
  (* The same tiles declaring no compression at all. A download or a browse
     that mixed these with the gzipped archive above would relabel every
     tile as something it is not, so the server refuses -- and the suite
     needs a source that provokes exactly that. *)
  write
    (Filename.concat dir "map-raw.pmtiles")
    (london ~compression:Pmtiles.Header.None_ ());
  (* The same place, gzipped, but only down to zoom 6 -- the archive the
     mismatch server starts with. Shallow on purpose: a browse for street
     level then genuinely wants tiles it does not hold, so refusing the
     differently compressed source is the only thing standing between the
     cache and bytes labelled as something they are not. *)
  (* Deliberately expensive to fetch: a wide region whose every tile sits in
     its own 64 KiB slot, so reading it costs hundreds of range requests
     instead of one. Paired with a delaying proxy in the e2e harness, that is
     what makes a download last long enough to be cancelled on purpose. *)
  write
    (Filename.concat dir "map-slow.pmtiles")
    (pmtiles ~stride:65536 ~min_lon:(-0.6) ~min_lat:51.2 ~max_lon:0.4
       ~max_lat:51.8 ~max_zoom:12 ());
  write
    (Filename.concat dir "map-shallow.pmtiles")
    (pmtiles ~min_lon:(-0.20) ~min_lat:51.46 ~max_lon:(-0.05) ~max_lat:51.56
       ~max_zoom:6 ());
  (* An archive shaped like an install from before downloads stopped
     merging: tiles in map.pmtiles with a ledger entry beside them, under
     whatever the picker called it at the time. Named and shaped like the
     row that prompted the rule -- a small box over London called "Map
     view", sitting in the base archive with no file of its own.

     The suite drops this in as a server's map.pmtiles to check that such a
     row offers nothing that would rewrite that file. Written by
     [Ledger.to_metadata] rather than by hand, so the fixture cannot drift
     from the format the server actually reads. *)
  let legacy_entry =
    Tessarium_server.Ledger.make ~name:"Map view" ~completed:1787941124
      ~source:"fixture" ~bytes:3126624
      ~regions:
        [
          (match
             Tessarium_server.Basemap_job.validate ~min_lon:(-0.20)
               ~min_lat:51.46 ~max_lon:(-0.05) ~max_lat:51.56 ~max_zoom:15 ()
           with
          | Ok r -> r
          | Error e -> failwith e);
        ]
  in
  write
    (Filename.concat dir "map-legacy.pmtiles")
    (london
       ~metadata:
         (match
            Tessarium_server.Ledger.to_metadata [ legacy_entry ] ~previous:"{}"
          with
         | Ok m -> m
         | Error e -> failwith e)
       ());
  write (Filename.concat dir "assets.tar.gz") (Gzip.compress (assets_tarball ()));
  Printf.printf "basemap fixture written to %s\n" dir
