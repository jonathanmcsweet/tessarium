(* A download, end to end, against a source archive on disk.

   The point under test is the layout: a region is downloaded to a file of
   its own, that file carries its own record, and every operation on the
   region afterwards -- listing it, handing it over, taking it away -- is an
   operation on that one file. Everything here would have passed before the
   split too, describing one growing map.pmtiles; what it pins down is that
   the answers are the same now that there are several files.

   Driven through [run_download] rather than the HTTP endpoint because the
   source can then be a path: [Pmtiles_source.open_url] takes a file as
   readily as a URL, so this is a real download with real planning, real
   merging and real renaming, and no socket. *)

module D = Tessarium_server.Basemap_download
module Job = Tessarium_server.Basemap_job
module Ledger = Tessarium_server.Ledger
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

(* A source archive: every tile of a box between two zooms, each with its
   own bytes so a merge that mixed two of them up would be visible. *)
let source_archive ~min_zoom ~max_zoom ~min_lon ~min_lat ~max_lon ~max_lat =
  let ids =
    Pmtiles.Tile_id.covering ~min_zoom ~max_zoom ~min_lon ~min_lat ~max_lon
      ~max_lat
  in
  let body = Buffer.create 4096 in
  let entries =
    Array.of_list
      (List.map
         (fun id ->
           let blob = Printf.sprintf "tile-%d;" id in
           let offset = Buffer.length body in
           Buffer.add_string body blob;
           {
             Pmtiles.Directory.tile_id = id;
             offset;
             length = String.length blob;
             run_length = 1;
           })
         ids)
  in
  let data = Buffer.contents body in
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
      data_length = String.length data;
      addressed_tiles = Array.length entries;
      tile_entries = Array.length entries;
      tile_contents = Array.length entries;
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
  Pmtiles.Header.serialize header ^ root ^ metadata ^ data

let req ~min_lon ~min_lat ~max_lon ~max_lat ~max_zoom =
  match Job.validate ~min_lon ~min_lat ~max_lon ~max_lat ~max_zoom () with
  | Ok r -> r
  | Error e -> failwith e

let () =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let net = Eio.Stdenv.net env in
  let root = Filename.temp_dir "tessarium-regions" "" in
  let basemap_dir = Filename.concat root "basemap" in
  let dir = Eio.Path.(fs / basemap_dir) in
  Eio.Path.mkdir ~perm:0o755 dir;

  (* The planet down to zoom 5, which is deep enough for two boxes far apart
     to have tiles of their own and shallow enough to build in a moment. *)
  let source = Filename.concat root "source.pmtiles" in
  Eio.Path.save ~create:(`Or_truncate 0o644) Eio.Path.(fs / source)
    (source_archive ~min_zoom:0 ~max_zoom:5 ~min_lon:(-180.) ~min_lat:(-85.)
       ~max_lon:180. ~max_lat:85.);

  let t = D.create () in
  (* Fixed, so the date in every file name below is this one and the test
     does not change what it asserts at midnight. 2026-08-28. *)
  let clock = ref 1787875200 in
  let now () = !clock in
  let download ?replaces ~name reqs =
    D.run_download t ~fs ~net ~source ~assets:"" ~basemap_dir
      ~budget:D.default_budget ~name:(Some name) ~now ~refresh:false ~replaces
      ~target:D.Detail ~labels:None reqs
  in
  let listing () =
    List.filter Tile_set.is_region (Eio.Path.read_dir dir)
  in
  let entries () =
    match D.ledger_json ~fs ~basemap_dir with
    | Error e -> failwith e
    | Ok (`Assoc fields) -> (
        match List.assoc_opt "entries" fields with
        | Some (`List es) -> es
        | _ -> [])
    | Ok _ -> []
  in
  let field k = function
    | `Assoc fs -> ( match List.assoc_opt k fs with Some v -> v | None -> `Null)
    | _ -> `Null
  in
  let str k j = match field k j with `String s -> s | _ -> "" in
  (* [status] wraps the job in a generation counter, which is the poller's
     business and not this test's. *)
  let job () = field "job" (D.status t) in
  let state () = str "state" (job ()) in
  let outcome () =
    match state () with "failed" -> str "reason" (job ()) | s -> s
  in

  (* ------------------------------------------------- one region, one file *)

  download ~name:"Georgia"
    [ req ~min_lon:(-85.6) ~min_lat:30.3 ~max_lon:(-80.8) ~max_lat:35.0 ~max_zoom:5 ];
  check ("the download finished: " ^ outcome ()) (state () = "done");

  let files = listing () in
  check "it wrote exactly one region file" (List.length files = 1);
  let ga_file = match files with [ f ] -> f | _ -> "" in
  check "named after the region, the day and the record"
    (ga_file = "Georgia-2026-08-28-"
               ^ String.sub (str "id" (List.hd (entries ()))) 0 8
               ^ ".pmtiles");
  check "and nothing was merged into the old archive"
    (not (Eio.Path.is_file Eio.Path.(dir / Tile_set.base_file)));
  check "no half-written file was left behind"
    (not (List.exists (fun n -> Filename.check_suffix n ".part")
            (Eio.Path.read_dir dir)));

  (* The record travels inside the file it describes, which is what makes
     the file carryable: a machine handed only this file can say what it is
     holding. *)
  let ledger_in name =
    Eio.Switch.run @@ fun sw ->
    let a =
      Pmtiles.Archive.open_
        (Pmtiles_source.file_source (Eio.Path.open_in ~sw Eio.Path.(dir / name)))
    in
    match Ledger.of_metadata (Pmtiles.Archive.metadata a) with
    | Ok l -> l
    | Error e -> failwith e
  in
  check "the file carries its own record, and only its own"
    (List.length (ledger_in ga_file) = 1);
  check "which names the region the user asked for"
    (match ledger_in ga_file with
     | [ e ] -> e.Ledger.name = "Georgia"
     | _ -> false);
  check "and the list points at the file to carry away"
    (match entries () with
     | [ e ] -> str "file" e = ga_file
     | _ -> false);

  (* --------------------------------------------- a second region, beside *)

  clock := !clock + 86_400;
  download ~name:"London"
    [ req ~min_lon:(-0.5) ~min_lat:51.3 ~max_lon:0.3 ~max_lat:51.7 ~max_zoom:5 ];
  check ("the second download finished: " ^ outcome ()) (state () = "done");
  check "a second region is a second file, not a bigger one"
    (List.length (listing ()) = 2);
  check "dated the day it was fetched, not the day the first one was"
    (List.exists
       (fun n -> Filename.check_suffix n ".pmtiles"
                 && String.length n > 8
                 && String.sub n 0 7 = "London-"
                 && String.length n > 20
                 && String.sub n 7 10 = "2026-08-29")
       (listing ()));
  check "and both are listed" (List.length (entries ()) = 2);
  check "each pointing at its own file"
    (List.for_all (fun e -> str "file" e <> "") (entries ()));

  (* Both are searched, and neither shadows the other. This is the property
     the whole layout rests on: several files, one map. *)
  let holds ~z ~lon ~lat =
    Eio.Switch.run @@ fun sw ->
    let x = Pmtiles.Tile_id.tile_x ~z ~lon and y = Pmtiles.Tile_id.tile_y ~z ~lat in
    let id = Pmtiles.Tile_id.of_zxy ~z ~x ~y in
    List.exists
      (fun (e : Tile_set.entry) ->
        Tile_set.may_hold e.Tile_set.header ~z ~x ~y
        && (let a =
              Pmtiles.Archive.open_
                (Pmtiles_source.file_source
                   (Eio.Path.open_in ~sw Eio.Path.(dir / e.Tile_set.name)))
            in
            Pmtiles.Archive.tile a id <> None))
      (Tile_set.entries ~dir)
  in
  check "a tile over the first region is served" (holds ~z:5 ~lon:(-84.4) ~lat:33.7);
  check "and a tile over the second, from the other file"
    (holds ~z:5 ~lon:(-0.1) ~lat:51.5);
  check "and one over neither is not"
    (not (holds ~z:5 ~lon:139.7 ~lat:35.7));

  (* ----------------------------------------------------- asking again *)

  clock := !clock + 86_400;
  download ~name:"Georgia"
    [ req ~min_lon:(-85.6) ~min_lat:30.3 ~max_lon:(-80.8) ~max_lat:35.0 ~max_zoom:5 ];
  check "asking for a region already held says so rather than fetching it"
    (outcome () = "you already have the maps for that area");
  check "and writes no second copy of it" (List.length (listing ()) = 2);

  (* ------------------------------------------------------------ carrying *)

  let ga_id =
    match List.find_opt (fun e -> str "file" e = ga_file) (entries ()) with
    | Some e -> str "id" e
    | None -> ""
  in
  D.run_export t ~fs ~basemap_dir ~id:ga_id;
  check "exporting hands over the file the download already wrote"
    (state () = "exported" && str "file" (job ()) = ga_file);
  check "and builds nothing to do it"
    (not (Eio.Path.is_directory Eio.Path.(dir / "export")));

  (* ------------------------------------------------------------ removing *)

  D.run_remove t ~fs ~basemap_dir ~id:ga_id;
  check "removing a region takes its file with it"
    (not (Eio.Path.is_file Eio.Path.(dir / ga_file)));
  check "and leaves the other one alone" (List.length (listing ()) = 1);
  check "and the list agrees" (List.length (entries ()) = 1);

  Printf.printf "\n%d checks, %d failures\n" !checks !failures;
  if !failures > 0 then exit 1;
  print_endline "regions are files"
