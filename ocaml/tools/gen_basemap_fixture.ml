(* Builds the basemap fixture the end-to-end test downloads from, so the e2e
   runs the real downloader -- range requests, extraction, assets tarball --
   against this project's own server, with no external network.

   Files go in the directory named by argv(1):

   - map.pmtiles: central London, zooms 0-15. Every tile is the same
     hand-encoded MVT (one layer, one point). MapLibre must parse it without
     a console error, and the e2e fails on console errors. The layer matches
     nothing in the style, so nothing is drawn and no glyphs are fetched.

   - assets.tar.gz: the sprite sheets the style loads, plus one glyph file so
     fonts/ exists. Wrapped in a top-level directory like GitHub's tarballs,
     because the server's untar strips exactly that shape. *)

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
    varint_field 15 2 ^ bytes_field 1 "fixture" ^ bytes_field 2 feature
    ^ varint_field 5 4096
  in
  (* A second layer shaped like the real basemap's: one named place with a
     kind and a population, so the search index has something to find and
     rank. The name is invented -- a real place name would make a passing
     test ambiguous. *)
  let named_feature =
    (* tags: name -> "Fixtureville", kind -> "locality", population -> 4242 *)
    let tags =
      varint 0 ^ varint 0 ^ varint 1 ^ varint 1 ^ varint 2 ^ varint 2
    in
    varint_field 3 1 ^ bytes_field 2 tags ^ bytes_field 4 geometry
  in
  let str_value v = bytes_field 1 v in
  let int_value n = varint_field 4 n in
  let places =
    varint_field 15 2 ^ bytes_field 1 "places"
    ^ bytes_field 2 named_feature
    ^ bytes_field 3 "name" ^ bytes_field 3 "kind" ^ bytes_field 3 "population"
    ^ bytes_field 4 (str_value "Fixtureville")
    ^ bytes_field 4 (str_value "locality")
    ^ bytes_field 4 (int_value 4242)
    ^ varint_field 5 4096
  in
  bytes_field 3 layer ^ bytes_field 3 places

(* ---------------------------------------------------------------- pmtiles *)

(* [stride] gives every tile id its own copy of the blob, that many bytes
   apart. Same tiles either way, but the reads differ: one shared blob makes a
   whole region one range request, while a stride wider than the reader's
   readahead window costs a request per tile. The cancellation test needs a
   download slow enough to cancel.

   [Pmtiles.Build] assembles the archive, same as the server's suites, so a
   format change cannot leave this fixture describing a layout nothing
   writes. *)
let pmtiles ?metadata ?(compression = Pmtiles.Header.Gzip) ?stride ~min_lon
    ~min_lat ~max_lon ~max_lat ~max_zoom () =
  (* Gzipped, like the real planet build, so the e2e exercises the
     content-encoding path the browser decodes, not just identity. *)
  let tile =
    match compression with
    | Pmtiles.Header.Gzip -> Gzip.compress mvt_tile
    | _ -> mvt_tile
  in
  snd
    (Pmtiles.Build.of_box ?metadata ~compression ?stride ~min_zoom:0 ~max_zoom
       ~min_lon ~min_lat ~max_lon ~max_lat
       ~center:(10, (min_lon +. max_lon) /. 2., (min_lat +. max_lat) /. 2.)
       ~body:(fun _ -> tile)
       ())

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

(* A 1x1 transparent PNG. MapLibre decodes the sprite sheet on load, so these
   bytes must be a real image. *)
let png =
  "\x89PNG\r\n\x1a\n"
  ^ "\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89"
  ^ "\x00\x00\x00\x0aIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\x0d\x0a\x2d\xb4"
  ^ "\x00\x00\x00\x00IEND\xaeB`\x82"

(* Both sheets the style can name, at both densities. The UI picks one by
   theme, so shipping only light would 404 as soon as a test chose dark, and
   the e2e fails on a failed request. *)
let sprite_sheets = [ "light"; "dark" ]

let assets_tarball () =
  let w = "basemaps-assets-fixture/" in
  let sheet name =
    tar_entry (w ^ "sprites/v4/" ^ name ^ ".json") "{}"
    ^ tar_entry (w ^ "sprites/v4/" ^ name ^ ".png") png
    ^ tar_entry (w ^ "sprites/v4/" ^ name ^ "@2x.json") "{}"
    ^ tar_entry (w ^ "sprites/v4/" ^ name ^ "@2x.png") png
  in
  String.concat "" (List.map sheet sprite_sheets)
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
  (* The same tiles, declaring no compression. Mixing these with the gzipped
     archive above would mislabel every tile, so the server refuses; the suite
     needs a source that provokes that refusal. *)
  write
    (Filename.concat dir "map-raw.pmtiles")
    (london ~compression:Pmtiles.Header.None_ ());
  (* Deliberately slow to fetch: a wide region with every tile in its own
     64 KiB slot, so reading it costs hundreds of range requests instead of
     one. With the e2e harness's delaying proxy, that makes a download last
     long enough to cancel. *)
  write
    (Filename.concat dir "map-slow.pmtiles")
    (pmtiles ~stride:65536 ~min_lon:(-0.6) ~min_lat:51.2 ~max_lon:0.4
       ~max_lat:51.8 ~max_zoom:12 ());
  (* The same place, gzipped, but only down to zoom 6 -- what the mismatch
     server starts with. Shallow on purpose: a browse for street level then
     really does want tiles it lacks, so refusing the differently compressed
     source is what keeps mislabelled bytes out of the cache. *)
  write
    (Filename.concat dir "map-shallow.pmtiles")
    (pmtiles ~min_lon:(-0.20) ~min_lat:51.46 ~max_lon:(-0.05) ~max_lat:51.56
       ~max_zoom:6 ());
  (* An install from before downloads stopped merging: tiles inside
     map.pmtiles with a ledger entry beside them, named whatever the picker
     called it then -- here a small box over London called "Map view", with
     no file of its own.

     The suite drops this in as a server's map.pmtiles to check such a row
     offers nothing that would rewrite that file. Built by
     [Ledger.to_metadata], not by hand, so it cannot drift from the format
     the server reads. *)
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
  write
    (Filename.concat dir "assets.tar.gz")
    (Gzip.compress (assets_tarball ()));
  Printf.printf "basemap fixture written to %s\n" dir
