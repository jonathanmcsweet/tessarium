(* A download, end to end, against a source archive on disk.

   Under test is the layout: a region downloads into a file of its own, that
   file carries its own record, and listing, exporting or removing the region
   acts on that one file. These checks would have passed before the split too,
   describing one growing map.pmtiles; what they pin down is that the answers
   are unchanged now that there are several files.

   Driven through [run_download] rather than the HTTP endpoint so the source
   can be a path -- [Pmtiles_source.open_url] takes a file as readily as a
   URL. Real planning, real merging, real renaming, no socket. *)

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

(* A source archive: every tile of a box between two zooms, each with its
   own bytes so a merge that mixed two of them up would be visible. *)
let source_archive ?metadata ~min_zoom ~max_zoom ~min_lon ~min_lat ~max_lon
    ~max_lat () =
  snd
    (Pmtiles.Build.of_box ?metadata ~min_zoom ~max_zoom ~min_lon ~min_lat
       ~max_lon ~max_lat
       ~body:(fun id -> Printf.sprintf "tile-%d;" id)
       ())

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
  Eio.Path.save ~create:(`Or_truncate 0o644)
    Eio.Path.(fs / source)
    (source_archive ~min_zoom:0 ~max_zoom:5 ~min_lon:(-180.) ~min_lat:(-85.)
       ~max_lon:180. ~max_lat:85. ());

  let t = D.create () in
  (* Fixed clock, so the file names below carry this date and the assertions
     do not change at midnight. 2026-08-28. *)
  let clock = ref 1787875200 in
  let now () = !clock in
  let download ?replaces ~name reqs =
    D.run_download t ~fs ~net ~source ~assets:"" ~basemap_dir
      ~budget:D.default_budget ~name:(Some name) ~now ~refresh:false ~replaces
      ~target:D.Detail reqs
  in
  let listing () = List.filter Tile_set.is_region (Eio.Path.read_dir dir) in
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
    | `Assoc fs -> (
        match List.assoc_opt k fs with Some v -> v | None -> `Null)
    | _ -> `Null
  in
  let str k j = match field k j with `String s -> s | _ -> "" in
  let bool k j = match field k j with `Bool b -> b | _ -> false in
  (* [status] wraps the job in a generation counter, which is the poller's
     business and not this test's. *)
  let job () = field "job" (D.status t) in
  let state () = str "state" (job ()) in
  let outcome () =
    match state () with "failed" -> str "reason" (job ()) | s -> s
  in

  (* ------------------------------------------------- one region, one file *)
  download ~name:"Georgia"
    [
      req ~min_lon:(-85.6) ~min_lat:30.3 ~max_lon:(-80.8) ~max_lat:35.0
        ~max_zoom:5;
    ];
  check ("the download finished: " ^ outcome ()) (state () = "done");

  let files = listing () in
  check "it wrote exactly one region file" (List.length files = 1);
  let ga_file = match files with [ f ] -> f | _ -> "" in
  check "named after the region, the day and the record"
    (ga_file
    = "Georgia-2026-08-28-"
      ^ String.sub (str "id" (List.hd (entries ()))) 0 8
      ^ ".pmtiles");
  check "and nothing was merged into the old archive"
    (not (Eio.Path.is_file Eio.Path.(dir / Tile_set.base_file)));
  check "no half-written file was left behind"
    (not
       (List.exists
          (fun n -> Filename.check_suffix n ".part")
          (Eio.Path.read_dir dir)));

  (* The record lives inside the file it describes, so a machine handed only
     this file can say what it holds. *)
  let ledger_in name =
    Eio.Switch.run @@ fun sw ->
    let a =
      Pmtiles.Archive.open_
        (Pmtiles_source.file_source
           (Eio.Path.open_in ~sw Eio.Path.(dir / name)))
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
    (match entries () with [ e ] -> str "file" e = ga_file | _ -> false);

  (* --------------------------------------------- a second region, beside *)
  clock := !clock + 86_400;
  download ~name:"London"
    [ req ~min_lon:(-0.5) ~min_lat:51.3 ~max_lon:0.3 ~max_lat:51.7 ~max_zoom:5 ];
  check ("the second download finished: " ^ outcome ()) (state () = "done");
  check "a second region is a second file, not a bigger one"
    (List.length (listing ()) = 2);
  check "dated the day it was fetched, not the day the first one was"
    (List.exists
       (fun n ->
         Filename.check_suffix n ".pmtiles"
         && String.length n > 8
         && String.sub n 0 7 = "London-"
         && String.length n > 20
         && String.sub n 7 10 = "2026-08-29")
       (listing ()));
  check "and both are listed" (List.length (entries ()) = 2);
  check "each pointing at its own file"
    (List.for_all (fun e -> str "file" e <> "") (entries ()));

  (* Both files are searched and neither shadows the other: several files,
     one map. *)
  let holds ~z ~lon ~lat =
    Eio.Switch.run @@ fun sw ->
    let x = Pmtiles.Tile_id.tile_x ~z ~lon
    and y = Pmtiles.Tile_id.tile_y ~z ~lat in
    let id = Pmtiles.Tile_id.of_zxy ~z ~x ~y in
    List.exists
      (fun (e : Tile_set.entry) ->
        Tile_set.may_hold e.Tile_set.header ~z ~x ~y
        &&
        let a =
          Pmtiles.Archive.open_
            (Pmtiles_source.file_source
               (Eio.Path.open_in ~sw Eio.Path.(dir / e.Tile_set.name)))
        in
        Pmtiles.Archive.tile a id <> None)
      (Tile_set.entries ~dir)
  in
  check "a tile over the first region is served"
    (holds ~z:5 ~lon:(-84.4) ~lat:33.7);
  check "and a tile over the second, from the other file"
    (holds ~z:5 ~lon:(-0.1) ~lat:51.5);
  check "and one over neither is not" (not (holds ~z:5 ~lon:139.7 ~lat:35.7));

  (* ----------------------------------------------------- asking again *)
  clock := !clock + 86_400;
  download ~name:"Georgia"
    [
      req ~min_lon:(-85.6) ~min_lat:30.3 ~max_lon:(-80.8) ~max_lat:35.0
        ~max_zoom:5;
    ];
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

  (* ----------------------------------------------------------- carrying in *)

  (* The other end of the trip: the exported file lands on a machine with no
     internet. It is already a region file -- one archive, one record -- so
     importing it only moves it into place, and the bytes must come back
     identical. Rebuilding it tile by tile would produce a different file. *)
  let carried_name = match listing () with f :: _ -> f | [] -> "" in
  let carried = Eio.Path.load Eio.Path.(dir / carried_name) in
  let away_dir = Filename.concat root "carried" in
  let away = Eio.Path.(fs / away_dir) in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 Eio.Path.(away / "import");
  Eio.Path.save ~create:(`Or_truncate 0o644)
    Eio.Path.(away / "import" / "staged.pmtiles")
    carried;
  let t2 = D.create () in
  Eio.Switch.run (fun sw ->
      match
        D.start_import t2 ~sw ~fs ~net ~basemap_dir:away_dir
          ~budget:D.default_budget ~now
      with
      | Ok () -> ()
      | Error e -> failwith e);
  let away_files = List.filter Tile_set.is_region (Eio.Path.read_dir away) in
  check "an imported region lands under the name it was carried under"
    (away_files = [ carried_name ]);
  check "byte for byte, because it was put in place rather than rebuilt"
    (match Eio.Path.load Eio.Path.(away / carried_name) with
    | got -> got = carried
    | exception _ -> false);
  check "and the staged copy does not stay behind"
    (not (Eio.Path.is_file Eio.Path.(away / "import" / "staged.pmtiles")));
  check "the machine that received it can name what it was given"
    (match D.ledger_json ~fs ~basemap_dir:away_dir with
    | Ok (`Assoc fields) -> (
        match List.assoc_opt "entries" fields with
        | Some (`List [ e ]) -> str "file" e = carried_name
        | _ -> false)
    | _ -> false);

  (* ------------------------------------------------- the map under the map *)

  (* The world overview is not a download and must never be removable. It
     draws everywhere no region has been fetched, every package ships one, and
     a user who deleted it on an offline machine could not get it back.

     Two locks, tested separately, because one of them is an absence and an
     absence is easy to delete by accident. *)
  D.run_download t ~fs ~net ~source ~assets:"" ~basemap_dir
    ~budget:D.default_budget ~name:None ~now ~refresh:false ~replaces:None
    ~target:D.World
    [
      req ~min_lon:(-180.) ~min_lat:(-85.) ~max_lon:180. ~max_lat:85.
        ~max_zoom:3;
    ];
  check ("the overview downloaded: " ^ outcome ()) (state () = "done");
  check "it goes to its own file"
    (Eio.Path.is_file Eio.Path.(dir / Tile_set.world_file));
  check "which is not one of the region files"
    (not (List.mem Tile_set.world_file (listing ())));
  check "it is still searched for tiles, like every other archive"
    (List.mem Tile_set.world_file (Tile_set.names ~dir));
  check "but it is not downloaded detail"
    (not
       (List.exists
          (fun (e : Tile_set.entry) -> e.Tile_set.name = Tile_set.world_file)
          (Tile_set.detail ~dir)));
  (* It writes no record, but it is listed anyway, under an id the server
     makes up.

     Hiding it used to be the defence: no row, so no button. What that
     produced was a panel showing a three-megabyte box over London and nothing
     about the forty-five megabytes the map is standing on -- so users read
     that box as the world map, and the button beside it as the one that
     deletes it. The overview is listed now because it must not be removable:
     shown, sized, with no verb attached, it is visibly there to stay. *)
  let world_row () = List.find_opt (fun e -> bool "overview" e) (entries ()) in
  check "the overview is listed once, as the overview"
    (List.length (entries ()) = 2 && world_row () <> None);
  check "under a reserved id no download could ever be given"
    (match world_row () with
    | Some e -> str "id" e = D.overview_id
    | None -> false);
  check "with nothing to carry away, because every package ships one"
    (match world_row () with Some e -> str "file" e = "" | None -> false);
  check "sized from the file on disk"
    (match world_row () with
    | Some e -> (
        match field "bytes" e with
        | `Int n -> (
            n
            =
            match
              Eio.Path.stat ~follow:true Eio.Path.(dir / Tile_set.world_file)
            with
            | st -> Optint.Int63.to_int st.Eio.File.Stat.size
            | exception Eio.Io _ -> -1)
        | _ -> false)
    | None -> false);
  check "and no completion date, because nobody recorded downloading it"
    (match world_row () with
    | Some e -> field "completed" e = `Int 0
    | None -> false);

  (* Listing the overview makes its id sayable, so each verb has to refuse
     that id by name rather than by not recognising it. All three verbs take
     an id off the same list. *)
  let says_overview () =
    let r = outcome () in
    let rec find i =
      i + 8 <= String.length r && (String.sub r i 8 = "overview" || find (i + 1))
    in
    state () = "failed" && find 0
  in
  D.run_remove t ~fs ~basemap_dir ~id:D.overview_id;
  (* The reason matters, not just the refusal. With no guard of its own this
     id falls through to [home_of], which says "no such downloaded map" --
     true of the record, false of the row the user is looking at. *)
  check
    ("removing the overview by its listed id is refused as such: " ^ outcome ())
    (says_overview ());
  check "and the overview is still on disk"
    (Eio.Path.is_file Eio.Path.(dir / Tile_set.world_file));
  D.run_export t ~fs ~basemap_dir ~id:D.overview_id;
  check
    ("exporting it is refused as such too: " ^ outcome ())
    (says_overview ());
  check "and updating it is refused before any work starts"
    ( Eio.Switch.run @@ fun sw ->
      match
        D.start_update t ~sw ~fs ~net ~source ~assets:"" ~basemap_dir
          ~budget:D.default_budget ~now ~id:D.overview_id
      with
      | Error _ -> true
      | Ok () -> false );

  (* Second lock. An overview claiming to be a region -- hand-built, or an
     export renamed on a USB stick -- must not become removable by saying so.
     Removal refuses the file name outright and reads no record inside it. *)
  let planted =
    Ledger.make ~name:"Pretending" ~completed:1 ~source:"nowhere" ~bytes:1
      ~regions:
        [
          req ~min_lon:(-10.) ~min_lat:(-10.) ~max_lon:10. ~max_lat:10.
            ~max_zoom:3;
        ]
  in
  let planted_meta =
    match Ledger.to_metadata [ planted ] ~previous:"{}" with
    | Ok m -> m
    | Error e -> failwith e
  in
  Eio.Path.save ~create:(`Or_truncate 0o644)
    Eio.Path.(dir / Tile_set.world_file)
    (source_archive ~metadata:planted_meta ~min_zoom:0 ~max_zoom:3
       ~min_lon:(-180.) ~min_lat:(-85.) ~max_lon:180. ~max_lat:85. ());
  check "an overview claiming to be a region is still listed only as itself"
    (List.length (entries ()) = 2
    && not (List.exists (fun e -> str "id" e = Ledger.id planted) (entries ()))
    );
  D.run_remove t ~fs ~basemap_dir ~id:(Ledger.id planted);
  check
    ("removing it by the id it claims fails: " ^ outcome ())
    (state () = "failed");
  check "and the overview is still there"
    (Eio.Path.is_file Eio.Path.(dir / Tile_set.world_file));

  (* Removing everything that is removable leaves the overview standing.
     Walks the whole list, overview row included, as a script driving the API
     would. *)
  List.iter
    (fun e -> D.run_remove t ~fs ~basemap_dir ~id:(str "id" e))
    (entries ());
  check "removing every downloaded region leaves the overview alone"
    (Eio.Path.is_file Eio.Path.(dir / Tile_set.world_file));
  check "and it is the only thing left in the list"
    (match entries () with [ e ] -> bool "overview" e | _ -> false);

  (* Third lock, the one an upgrade walks straight into.

     Installs from before the split hold their overview inside map.pmtiles as
     an ordinary ledger entry, because that is what downloading the world did
     then. Neither lock above catches it: the file is the merged archive, not
     the overview's own, and the entry is a real record, not a planted one. So
     the row appeared with a Remove button, under whatever the picker called
     it -- "Map view" on the install that turned this up -- and pressing it
     pruned the tiles the whole map falls back to.

     Judged by what the entry covers, since the name says nothing. *)
  let legacy =
    Ledger.make ~name:"Map view" ~completed:1 ~source:"nowhere" ~bytes:1
      ~regions:
        [
          req ~min_lon:(-180.) ~min_lat:(-85.) ~max_lon:180. ~max_lat:85.
            ~max_zoom:6;
        ]
  in
  check
    "an entry spanning the planet is recognised as such, whatever it iscalled"
    (Ledger.spans_world legacy);
  check "and one spanning a country is not"
    (not
       (Ledger.spans_world
          (Ledger.make ~name:"Georgia" ~completed:1 ~source:"nowhere" ~bytes:1
             ~regions:
               [
                 req ~min_lon:(-85.6) ~min_lat:30.3 ~max_lon:(-80.8)
                   ~max_lat:35.0 ~max_zoom:12;
               ])));
  let legacy_meta =
    match Ledger.to_metadata [ legacy ] ~previous:"{}" with
    | Ok m -> m
    | Error e -> failwith e
  in
  Eio.Path.save ~create:(`Or_truncate 0o644)
    Eio.Path.(dir / Tile_set.base_file)
    (source_archive ~metadata:legacy_meta ~min_zoom:0 ~max_zoom:6
       ~min_lon:(-180.) ~min_lat:(-85.) ~max_lon:180. ~max_lat:85. ());
  check "the legacy overview is listed, because its tiles are really there"
    (List.exists (fun e -> str "id" e = Ledger.id legacy) (entries ()));
  check "but it is marked as the overview, so nothing offers to remove it"
    (List.exists
       (fun e ->
         str "id" e = Ledger.id legacy
         &&
         match e with
         | `Assoc f -> List.assoc_opt "overview" f = Some (`Bool true)
         | _ -> false)
       (entries ()));
  D.run_remove t ~fs ~basemap_dir ~id:(Ledger.id legacy);
  check
    ("removing the legacy overview fails: " ^ outcome ())
    (state () = "failed");
  check "and the merged archive still holds its tiles"
    (Eio.Path.is_file Eio.Path.(dir / Tile_set.base_file));

  (* The rule the three locks above were really about.

     [spans_world] judges what an entry covers, which is not enough. The row
     users kept pointing at was a small box over London called "Map view" --
     not the overview by any reading of its bounds -- sitting inside
     map.pmtiles and offering Remove. Whether it is the shipped map or a
     download that merged into it is not a distinction the panel can draw.

     So the line is drawn by where an entry lives, not by what it covers.
     map.pmtiles is the base archive: what fetch-basemap.sh writes, what
     pre-split installs grew, and the file every merged entry shares. Removing
     one entry from it rewrites or unlinks the file the rest of the map stands
     on, so nothing in it is removable from the UI, whatever it covers or is
     called. Downloads made today write their own file and stay removable. *)
  let sample =
    Ledger.make ~name:"Map view" ~completed:1 ~source:"nowhere" ~bytes:1
      ~regions:
        [
          req ~min_lon:(-0.25) ~min_lat:51.45 ~max_lon:0.0 ~max_lat:51.55
            ~max_zoom:15;
        ]
  in
  check "a small box over London is not the overview by what it holds"
    (not (Ledger.spans_world sample));
  let sample_meta =
    match Ledger.to_metadata [ sample ] ~previous:"{}" with
    | Ok m -> m
    | Error e -> failwith e
  in
  Eio.Path.save ~create:(`Or_truncate 0o644)
    Eio.Path.(dir / Tile_set.base_file)
    (source_archive ~metadata:sample_meta ~min_zoom:0 ~max_zoom:5
       ~min_lon:(-0.25) ~min_lat:51.45 ~max_lon:0.0 ~max_lat:51.55 ());
  let sample_row () =
    List.find_opt (fun e -> str "id" e = Ledger.id sample) (entries ())
  in
  check "it is listed, because its tiles are really there"
    (sample_row () <> None);
  check "with no file of its own, which is what says where it lives"
    (match sample_row () with Some e -> str "file" e = "" | None -> false);
  check "and it is not flagged as the overview, because it is not one"
    (match sample_row () with
    | Some e -> not (bool "overview" e)
    | None -> false);
  D.run_remove t ~fs ~basemap_dir ~id:(Ledger.id sample);
  check ("removing it is refused: " ^ outcome ()) (state () = "failed");
  check "and the base archive still holds its tiles"
    (Eio.Path.is_file Eio.Path.(dir / Tile_set.base_file));
  (* Export is not deletion, and it is the only way a merged entry reaches
     another machine, so it stays allowed. *)
  D.run_export t ~fs ~basemap_dir ~id:(Ledger.id sample);
  check ("exporting it still works: " ^ outcome ()) (state () = "exported");
  (* Update is refused too, and not because updates are destructive: an
     update lands in a new file and leaves the merged row behind, duplicating
     a row nothing can then remove. *)
  Eio.Switch.run (fun sw ->
      match
        D.start_update t ~sw ~fs ~net ~source ~assets:"" ~basemap_dir
          ~budget:D.default_budget ~now ~id:(Ledger.id sample)
      with
      | Error e -> check ("updating it is refused: " ^ e) false
      | Ok () -> ());
  check
    ("updating it fails rather than duplicating it: " ^ outcome ())
    (state () = "failed");
  check "and no second archive was written for it" (List.length (listing ()) = 0);
  Eio.Path.unlink Eio.Path.(dir / Tile_set.base_file);

  (* The other half of the rule, caught missing by the end-to-end suite:
     spanning the planet is not on its own disqualifying. Asking for the whole
     world as detail -- the scripted download in ui/test/e2e.mjs does -- lands
     in a file of its own, sits beside the overview rather than being it, and
     stays removable. *)
  D.run_download t ~fs ~net ~source ~assets:"" ~basemap_dir
    ~budget:D.default_budget ~name:(Some "The lot") ~now ~refresh:false
    ~replaces:None ~target:D.Detail
    [
      req ~min_lon:(-180.) ~min_lat:(-85.) ~max_lon:180. ~max_lat:85.
        ~max_zoom:2;
    ];
  check
    ("the whole world as detail downloads: " ^ outcome ())
    (state () = "done");
  let whole = List.find_opt (fun e -> str "name" e = "The lot") (entries ()) in
  check "it is listed like any other region" (whole <> None);
  check "and is not flagged as the overview"
    (match whole with
    | Some (`Assoc f) -> List.assoc_opt "overview" f = Some (`Bool false)
    | _ -> false);
  (match whole with
  | Some e -> D.run_remove t ~fs ~basemap_dir ~id:(str "id" e)
  | None -> ());
  check ("and removing it works: " ^ outcome ()) (state () = "removed");

  (* ================================================ carrying maps by hand *)

  (* Everything below uses its own directory. The one above has a history,
     and these tests are about a file arriving on a machine that has never
     seen it. *)
  let fresh name =
    let d = Filename.concat root name in
    Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 Eio.Path.(fs / d);
    d
  in
  let stage ~basemap_dir bytes =
    Eio.Path.mkdirs ~exists_ok:true ~perm:0o755
      Eio.Path.(fs / basemap_dir / "import");
    Eio.Path.save ~create:(`Or_truncate 0o644)
      Eio.Path.(fs / basemap_dir / "import" / "staged.pmtiles")
      bytes
  in
  let staged_bytes ~basemap_dir =
    match
      Eio.Path.load Eio.Path.(fs / basemap_dir / "import" / "staged.pmtiles")
    with
    | b -> Some b
    | exception _ -> None
  in
  let import ?(budget = D.default_budget) ?(now = now) t ~basemap_dir =
    Eio.Switch.run (fun sw ->
        match D.start_import t ~sw ~fs ~net ~basemap_dir ~budget ~now with
        | Ok () -> ()
        | Error e -> check ("the import started: " ^ e) false)
  in
  let listing_in ~basemap_dir =
    List.filter Tile_set.is_region
      (Eio.Path.read_dir Eio.Path.(fs / basemap_dir))
  in
  let entries_in ~basemap_dir =
    match D.ledger_json ~fs ~basemap_dir with
    | Error e -> failwith e
    | Ok (`Assoc fields) -> (
        match List.assoc_opt "entries" fields with
        | Some (`List es) -> es
        | _ -> [])
    | Ok _ -> []
  in
  let ledger_in ~basemap_dir name =
    Eio.Switch.run @@ fun sw ->
    let a =
      Pmtiles.Archive.open_
        (Pmtiles_source.file_source
           (Eio.Path.open_in ~sw Eio.Path.(fs / basemap_dir / name)))
    in
    match Ledger.of_metadata (Pmtiles.Archive.metadata a) with
    | Ok l -> l
    | Error e -> failwith e
  in
  let holds_in ~basemap_dir name ~z ~lon ~lat =
    Eio.Switch.run @@ fun sw ->
    let a =
      Pmtiles.Archive.open_
        (Pmtiles_source.file_source
           (Eio.Path.open_in ~sw Eio.Path.(fs / basemap_dir / name)))
    in
    Pmtiles.Archive.locate a
      (Pmtiles.Tile_id.of_zxy ~z
         ~x:(Pmtiles.Tile_id.tile_x ~z ~lon)
         ~y:(Pmtiles.Tile_id.tile_y ~z ~lat))
    <> None
  in
  let with_ledger entries ~min_zoom ~max_zoom
      (min_lon, min_lat, max_lon, max_lat) =
    source_archive
      ~metadata:
        (match Ledger.to_metadata entries ~previous:"{}" with
        | Ok m -> m
        | Error e -> failwith e)
      ~min_zoom ~max_zoom ~min_lon ~min_lat ~max_lon ~max_lat ()
  in

  (* ----------------------------------------------- one upload at a time *)

  (* Two uploads at once used to open the same staged .part with Or_truncate
     and both write from byte zero. Each counted only its own bytes against
     its own Content-Length, so both length checks passed over a file that was
     neither archive -- and that file got renamed to staged.pmtiles and merged
     as tiles. The reads below yield between chunks, like a socket does. *)
  let up_dir = fresh "uploads" in
  let payload_a =
    source_archive ~min_zoom:0 ~max_zoom:3 ~min_lon:(-85.6) ~min_lat:30.3
      ~max_lon:(-80.8) ~max_lat:35.0 ()
  in
  let payload_b =
    source_archive ~min_zoom:0 ~max_zoom:4 ~min_lon:(-0.5) ~min_lat:51.3
      ~max_lon:0.3 ~max_lat:51.7 ()
  in
  check "the two uploads are telling apart" (payload_a <> payload_b);
  (* Two chunk sizes, so the writes land on different boundaries. With equal
     chunks the later writer covered the earlier one block for block and the
     damage was invisible. Real sockets do not agree on chunk sizes either. *)
  let upload t ~chunk payload =
    let pos = ref 0 in
    let read buf =
      if !pos >= String.length payload then 0
      else begin
        (* Where a real upload gives the scheduler its chance. *)
        Eio.Fiber.yield ();
        let n = min chunk (String.length payload - !pos) in
        Cstruct.blit_from_string payload !pos buf 0 n;
        pos := !pos + n;
        n
      end
    in
    D.receive_import t ~fs ~basemap_dir:up_dir ~expected:(String.length payload)
      ~read
  in
  let tu = D.create () in
  let ra = ref (Error (D.Rejected "not run")) in
  let rb = ref (Error (D.Rejected "not run")) in
  Eio.Fiber.both
    (fun () -> ra := upload tu ~chunk:64 payload_a)
    (fun () -> rb := upload tu ~chunk:100 payload_b);
  let landed = List.filter Result.is_ok [ !ra; !rb ] in
  check "exactly one of two simultaneous uploads is accepted"
    (List.length landed = 1);
  check "and the other is told the seat is taken, not that its file is bad"
    (match (!ra, !rb) with
    | Ok (), Error (D.Busy _) | Error (D.Busy _), Ok () -> true
    | _ -> false);
  check "so what is staged is one whole archive, not two interleaved"
    (match staged_bytes ~basemap_dir:up_dir with
    | Some b -> b = payload_a || b = payload_b
    | None -> false);

  (* An upload must not land while a job holds the writer's seat: the import
     merge reads staged.pmtiles, and a rename over it mid-merge swaps the file
     out from under the reader. *)
  D.set tu
    (Job.Fetching
       { done_bytes = 0; total_bytes = 1; part = 1; parts = 1; regions = [] });
  check "an upload arriving while a job runs is refused"
    (match upload tu ~chunk:64 payload_a with
    | Error (D.Busy _) -> true
    | _ -> false);
  D.set tu Job.Idle;

  (* And the other direction: committing an import while bytes are still
     arriving would merge whatever had been written so far. *)
  tu.D.staging <- true;
  check "and an import is refused while an upload is still in flight"
    (Eio.Switch.run (fun sw ->
         match
           D.start_import tu ~sw ~fs ~net ~basemap_dir:up_dir
             ~budget:D.default_budget ~now
         with
         | Error _ -> true
         | Ok () -> false));
  tu.D.staging <- false;

  (* ------------------------------------- an import keeps what it was given *)

  (* Cancel a merge at 90%, or fill the disk, and the staged upload used to
     be deleted anyway -- forcing the re-upload that two-step staging exists
     to spare. Provoked here by importing the same archive twice: the second
     import fails because every region is already held, and the staged file
     must still be there to retry with. *)
  let keep_dir = fresh "keeps-its-upload" in
  let georgia_entry =
    Ledger.make ~name:"Georgia" ~completed:1 ~source:"a planet build" ~bytes:1
      ~regions:
        [
          req ~min_lon:(-85.6) ~min_lat:30.3 ~max_lon:(-80.8) ~max_lat:35.0
            ~max_zoom:4;
        ]
  in
  let london_entry =
    Ledger.make ~name:"London" ~completed:2 ~source:"another planet build"
      ~bytes:2
      ~regions:
        [
          req ~min_lon:(-0.5) ~min_lat:51.3 ~max_lon:0.3 ~max_lat:51.7
            ~max_zoom:4;
        ]
  in
  let two_records =
    with_ledger
      [ georgia_entry; london_entry ]
      ~min_zoom:0 ~max_zoom:4 (-180., -85., 180., 85.)
  in
  stage ~basemap_dir:keep_dir two_records;
  let tk = D.create () in
  import tk ~basemap_dir:keep_dir;
  check
    ("an archive of several records imports: "
    ^ str "state" (field "job" (D.status tk)))
    (str "state" (field "job" (D.status tk)) = "done");
  check "and the staged copy is cleared away once it has landed"
    (staged_bytes ~basemap_dir:keep_dir = None);

  stage ~basemap_dir:keep_dir two_records;
  import tk ~basemap_dir:keep_dir;
  check "importing what is already held fails"
    (str "state" (field "job" (D.status tk)) = "failed");
  check "and leaves the upload where it is, to be retried or discarded"
    (staged_bytes ~basemap_dir:keep_dir = Some two_records);

  (* ------------------------------------ several records, several regions *)

  (* Folding a multi-record archive into one entry took the first record's
     name and source, labelled every progress bar with it, and wrote one
     combined row. London's name, date and byte count were lost for good, and
     the two regions could only be removed together. *)
  let named n =
    List.find_opt (fun e -> str "name" e = n) (entries_in ~basemap_dir:keep_dir)
  in
  check "each record arrives as itself"
    (List.length (listing_in ~basemap_dir:keep_dir) = 2);
  check "under its own name" (named "Georgia" <> None && named "London" <> None);
  check "with its own source, not the first record's"
    (match (named "Georgia", named "London") with
    | Some g, Some l -> str "source" g <> str "source" l
    | _ -> false);
  check "and its own file to carry on with"
    (match (named "Georgia", named "London") with
    | Some g, Some l ->
        str "file" g <> "" && str "file" l <> "" && str "file" g <> str "file" l
    | _ -> false);
  check "each holding the tiles of its own place and not the other's"
    (match (named "Georgia", named "London") with
    | Some g, Some l ->
        holds_in ~basemap_dir:keep_dir (str "file" g) ~z:4 ~lon:(-84.4)
          ~lat:33.7
        && holds_in ~basemap_dir:keep_dir (str "file" l) ~z:4 ~lon:(-0.1)
             ~lat:51.5
        && not
             (holds_in ~basemap_dir:keep_dir (str "file" g) ~z:4 ~lon:(-0.1)
                ~lat:51.5)
    | _ -> false);
  (* The point of separate identities: one can go without the other. *)
  (match named "London" with
  | Some l -> D.run_remove tk ~fs ~basemap_dir:keep_dir ~id:(str "id" l)
  | None -> ());
  check "so removing one leaves the other"
    (List.length (entries_in ~basemap_dir:keep_dir) = 1
    && named "Georgia" <> None);

  (* Names travel with the regions, not beside them, so an imported region
     knows what to call each of its boxes. *)
  check "and the imported regions carry the name they were exported under"
    (match named "Georgia" with
    | Some g ->
        List.for_all
          (fun (r : Job.request) -> r.Job.label = Some "Georgia")
          (List.concat_map
             (fun (e : Ledger.entry) -> e.Ledger.regions)
             (ledger_in ~basemap_dir:keep_dir (str "file" g)))
    | None -> false);

  (* -------------------------------------- an import is not a download *)

  (* The budget is a network budget, and an import uses no network. Clamping
     an import to it makes a deep foreign archive re-plan shallow: only those
     zooms merge, the ledger records the clamped depth as though that were all
     the file held, and the staged file with the rest of the tiles is thrown
     away. *)
  let deep_dir = fresh "not-clamped" in
  let deep =
    source_archive ~min_zoom:0 ~max_zoom:5 ~min_lon:(-10.) ~min_lat:(-10.)
      ~max_lon:10. ~max_lat:10. ()
  in
  stage ~basemap_dir:deep_dir deep;
  let td = D.create () in
  (* Far too small for the box at zoom 5: a network download would be clamped
     to a couple of levels and say so. *)
  let tiny = { D.full = 4; quick = 2; max_parts = 1; compact = 48_000_000 } in
  import ~budget:tiny td ~basemap_dir:deep_dir;
  check
    ("an archive with no record imports: "
    ^ str "reason" (field "job" (D.status td)))
    (str "state" (field "job" (D.status td)) = "done");
  let deep_file =
    match listing_in ~basemap_dir:deep_dir with [ f ] -> f | _ -> ""
  in
  check "into one file" (deep_file <> "");
  check "recording the depth the source really holds, not the budget's"
    (match ledger_in ~basemap_dir:deep_dir deep_file with
    | [ e ] ->
        List.for_all
          (fun (r : Job.request) -> r.Job.max_zoom = 5)
          e.Ledger.regions
    | _ -> false);
  check "and holding the deep tiles the summary promised"
    (holds_in ~basemap_dir:deep_dir deep_file ~z:5 ~lon:0. ~lat:0.);

  (* An upload landing during a merge is a different file, and the merge must
     not delete it on its way out. The clock is read once per merge, after the
     source is open, so the [now] hook is a safe place to swap the file by
     rename -- the merge keeps reading the inode it opened. *)
  let swap_dir = fresh "replaced-mid-merge" in
  let first =
    source_archive ~min_zoom:0 ~max_zoom:3 ~min_lon:(-10.) ~min_lat:(-10.)
      ~max_lon:10. ~max_lat:10. ()
  in
  let replacement =
    source_archive ~min_zoom:0 ~max_zoom:4 ~min_lon:20. ~min_lat:20.
      ~max_lon:30. ~max_lat:30. ()
  in
  stage ~basemap_dir:swap_dir first;
  let swapped = ref false in
  let swapping_now () =
    if not !swapped then begin
      swapped := true;
      Eio.Path.save ~create:(`Or_truncate 0o644)
        Eio.Path.(fs / swap_dir / "import" / "next.tmp")
        replacement;
      Eio.Path.rename
        Eio.Path.(fs / swap_dir / "import" / "next.tmp")
        Eio.Path.(fs / swap_dir / "import" / "staged.pmtiles")
    end;
    !clock
  in
  let ts = D.create () in
  import ~now:swapping_now ts ~basemap_dir:swap_dir;
  check
    ("the first import still finished: "
    ^ str "reason" (field "job" (D.status ts)))
    (str "state" (field "job" (D.status ts)) = "done");
  check "the upload that arrived during it was swapped in" !swapped;
  check "and the finished import did not delete somebody else's upload"
    (staged_bytes ~basemap_dir:swap_dir = Some replacement);

  (* ------------------------------------------------ one id, one row *)

  (* An install upgraded from the merged layout can hold the same region
     twice: inside map.pmtiles and in a file of its own, because a re-download
     refuses to write into the base archive. Both copies hash to the same id --
     identity is the geometry and nothing else -- so the list emitted that id
     twice: a duplicate key, two rows reconciling into each other, and
     removing the file-backed one left the base copy claiming the same
     ground. *)
  let dup_dir = fresh "one-id-one-row" in
  let kent =
    Ledger.make ~name:"Kent" ~completed:1 ~source:"a planet build" ~bytes:1
      ~regions:
        [
          req ~min_lon:0.2 ~min_lat:51.0 ~max_lon:1.4 ~max_lat:51.5 ~max_zoom:4;
        ]
  in
  let kent_bytes =
    with_ledger [ kent ] ~min_zoom:0 ~max_zoom:4 (0.2, 51.0, 1.4, 51.5)
  in
  Eio.Path.save ~create:(`Or_truncate 0o644)
    Eio.Path.(fs / dup_dir / Tile_set.base_file)
    kent_bytes;
  Eio.Path.save ~create:(`Or_truncate 0o644)
    Eio.Path.(fs / dup_dir / "Kent-2026-01-01-abcdef.pmtiles")
    kent_bytes;
  let dup_rows =
    List.filter
      (fun e -> str "id" e = Ledger.id kent)
      (entries_in ~basemap_dir:dup_dir)
  in
  check "a region held in both layouts is listed once" (List.length dup_rows = 1);
  check "as the copy that has a file of its own, which is the removable one"
    (match dup_rows with
    | [ e ] -> str "file" e = "Kent-2026-01-01-abcdef.pmtiles"
    | _ -> false);
  D.run_remove tk ~fs ~basemap_dir:dup_dir ~id:(Ledger.id kent);
  check "and removing it takes that file"
    (not
       (Eio.Path.is_file
          Eio.Path.(fs / dup_dir / "Kent-2026-01-01-abcdef.pmtiles")));

  (* --------------------------------------- what a remembered ledger says *)

  (* Ledgers are parsed once per file and cached against the file's identity,
     because every poll and every estimate used to re-open and re-parse every
     archive on disk. The downloader publishes by renaming a .part over a
     name, so one name can end up holding a different region. *)
  let swap_name = "Kent-2026-01-01-abcdef.pmtiles" in
  Eio.Path.save ~create:(`Or_truncate 0o644)
    Eio.Path.(fs / dup_dir / swap_name)
    kent_bytes;
  check "a fresh file is read for what it says"
    (List.exists
       (fun e -> str "name" e = "Kent")
       (entries_in ~basemap_dir:dup_dir));
  let sussex =
    Ledger.make ~name:"Sussex" ~completed:3 ~source:"a planet build" ~bytes:3
      ~regions:
        [
          req ~min_lon:(-0.8) ~min_lat:50.7 ~max_lon:0.9 ~max_lat:51.1
            ~max_zoom:4;
        ]
  in
  Eio.Path.save ~create:(`Or_truncate 0o644)
    Eio.Path.(fs / dup_dir / (swap_name ^ ".new"))
    (with_ledger [ sussex ] ~min_zoom:0 ~max_zoom:4 (-0.8, 50.7, 0.9, 51.1));
  Eio.Path.rename
    Eio.Path.(fs / dup_dir / (swap_name ^ ".new"))
    Eio.Path.(fs / dup_dir / swap_name);
  check "and after a rename over it, the same name says what the new file says"
    (let rows = entries_in ~basemap_dir:dup_dir in
     List.exists (fun e -> str "name" e = "Sussex") rows
     (* The Kent row that survives is the base archive's, which still holds
        that record; what must not survive is a Kent row pointing at the file
        that is now Sussex. *)
     && List.for_all
          (fun e -> str "file" e <> swap_name || str "name" e = "Sussex")
          rows);

  (* ------------------------------------------- an export that stops early *)

  (* Every other job discards its .part and honours a pending cache clear on
     the way out; the export only set a state. A cancelled export stranded a
     file the UI cannot list -- [exports_json] shows only names ending in
     .pmtiles -- and that delete_export cannot remove, because it checks the
     name against that same listing. Gigabytes, invisibly, on the machine
     least likely to have the room. *)
  let ex_dir = fresh "export-stops" in
  Eio.Path.save ~create:(`Or_truncate 0o644)
    Eio.Path.(fs / ex_dir / Tile_set.base_file)
    kent_bytes;
  let te = D.create () in
  te.D.cancel_requested <- true;
  D.run_export te ~fs ~basemap_dir:ex_dir ~id:(Ledger.id kent);
  check
    ("a cancelled export says so: " ^ str "state" (field "job" (D.status te)))
    (str "state" (field "job" (D.status te)) = "cancelled");
  check "and leaves nothing half-written in the export directory"
    (match Eio.Path.read_dir Eio.Path.(fs / ex_dir / "export") with
    | names ->
        not (List.exists (fun n -> Filename.check_suffix n ".part") names)
    | exception _ -> true);

  (* The job holds the writer's seat, so a clear asked for while it runs is
     the job's to carry out as it leaves. Browsing is off by then and nothing
     else is coming to do it. *)
  te.D.cancel_requested <- false;
  Eio.Path.save ~create:(`Or_truncate 0o644)
    Eio.Path.(fs / ex_dir / Tile_set.cache_file)
    (source_archive ~min_zoom:0 ~max_zoom:3 ~min_lon:139.0 ~min_lat:35.0
       ~max_lon:140.0 ~max_lat:36.0 ());
  te.D.clear_requested <- true;
  D.run_export te ~fs ~basemap_dir:ex_dir ~id:(Ledger.id kent);
  check
    ("the export finished: " ^ str "reason" (field "job" (D.status te)))
    (str "state" (field "job" (D.status te)) = "exported");
  check "and the cache clear asked for while it ran was not forgotten"
    (not (Eio.Path.is_file Eio.Path.(fs / ex_dir / Tile_set.cache_file)));

  (* The import's fast path -- a region file put straight into place -- held
     the seat just as long and forgot it just the same. *)
  let ic_dir = fresh "import-clear" in
  stage ~basemap_dir:ic_dir
    (with_ledger [ georgia_entry ] ~min_zoom:0 ~max_zoom:4
       (-85.6, 30.3, -80.8, 35.0));
  Eio.Path.save ~create:(`Or_truncate 0o644)
    Eio.Path.(fs / ic_dir / Tile_set.cache_file)
    (source_archive ~min_zoom:0 ~max_zoom:3 ~min_lon:139.0 ~min_lat:35.0
       ~max_lon:140.0 ~max_lat:36.0 ());
  let ti = D.create () in
  ti.D.clear_requested <- true;
  import ti ~basemap_dir:ic_dir;
  check
    ("a one-record archive is put straight into place: "
    ^ str "reason" (field "job" (D.status ti)))
    (str "state" (field "job" (D.status ti)) = "done");
  check "and it honours a cache clear on its way out too"
    (not (Eio.Path.is_file Eio.Path.(fs / ic_dir / Tile_set.cache_file)));

  (* ------------------------------------------- the base archive is not ours *)

  (* Nothing is removed from map.pmtiles, whatever the entry covers and
     whatever it is called: that would rewrite or unlink the file the rest of
     the map is standing on. The refusal has to leave the archive untouched,
     not merely present. *)
  let before = Eio.Path.load Eio.Path.(fs / ex_dir / Tile_set.base_file) in
  D.run_remove te ~fs ~basemap_dir:ex_dir ~id:(Ledger.id kent);
  check
    ("removing a merged entry is refused: "
    ^ str "reason" (field "job" (D.status te)))
    (str "state" (field "job" (D.status te)) = "failed");
  check "and the base archive is byte for byte what it was"
    (Eio.Path.load Eio.Path.(fs / ex_dir / Tile_set.base_file) = before);

  (* --------------------------------------- one answer about the planet *)

  (* Two predicates used to ask whether a box was the whole world, with
     different thresholds and no idea of each other: a box starting at -179.5
     was the world to the ledger's overview lock but not to the world-download
     validator. One predicate now, with the slack as its argument. *)
  let world_box ?polygon () =
    match
      Job.validate ?polygon ~min_lon:(-180.) ~min_lat:(-85.) ~max_lon:180.
        ~max_lat:85. ~max_zoom:4 ()
    with
    | Ok r -> r
    | Error e -> failwith e
  in
  let nearly =
    req ~min_lon:(-179.5) ~min_lat:(-84.5) ~max_lon:179.5 ~max_lat:84.5
      ~max_zoom:4
  in
  check "the exact question and the lenient one are the same question"
    (D.covers_the_planet [ world_box () ]
    && Ledger.spans_regions ~margin:1.0 [ world_box () ]);
  check "and they differ only by the slack they are given"
    ((not (D.covers_the_planet [ nearly ]))
    && Ledger.spans_regions ~margin:1.0 [ nearly ]);
  check "a clipped world is not the world to either of them"
    ((not
        (D.covers_the_planet
           [ world_box ~polygon:[| [| (-1., -1.); (1., -1.); (1., 1.) |] |] () ]))
    && not
         (Ledger.spans_regions ~margin:1.0
            [
              world_box ~polygon:[| [| (-1., -1.); (1., -1.); (1., 1.) |] |] ();
            ]));

  Printf.printf "\n%d checks, %d failures\n" !checks !failures;
  if !failures > 0 then exit 1;
  print_endline "regions are files"
