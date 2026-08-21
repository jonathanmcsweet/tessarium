(* Tests for the server's pure decisions. No socket, no filesystem, no clock.

   Range parsing and path resolution are here because both fail silently. A
   wrong range hands back the wrong bytes and the map renders as garbage; a
   path that escapes the asset root serves whatever is above it. Neither
   produces an error the way a crash would. *)

module R = Tessarium_server.Http_range
module U = Tessarium_server.Url_path
module Route = Tessarium_server.Route

let failures = ref 0
let checks = ref 0

let check name ok =
  incr checks;
  if not ok then begin
    incr failures;
    Printf.printf "  FAIL  %s\n" name
  end

let range_to_string = function
  | R.Whole -> "whole"
  | R.Partial { first; last } -> Printf.sprintf "%d-%d" first last
  | R.Unsatisfiable -> "unsatisfiable"

let check_range header length expected =
  let got = R.parse ~header:(Some header) ~length in
  check
    (Printf.sprintf "range %S over %d = %s, want %s" header length
       (range_to_string got) (range_to_string expected))
    (got = expected)

let partial first last = R.Partial { R.first; last }

let () =
  (* ------------------------------------------------------------ ranges *)
  check "no header is whole" (R.parse ~header:None ~length:100 = R.Whole);

  check_range "bytes=0-99" 100 (partial 0 99);
  check_range "bytes=0-0" 100 (partial 0 0);
  check_range "bytes=10-19" 100 (partial 10 19);

  (* An open-ended range runs to the end of the representation. PMTiles asks
     this way for the header block. *)
  check_range "bytes=50-" 100 (partial 50 99);

  (* A range past the end is clamped, not rejected: RFC 9110 says a last-pos
     greater than the length is treated as the length minus one. *)
  check_range "bytes=90-500" 100 (partial 90 99);

  (* Suffix form: the final n bytes. *)
  check_range "bytes=-10" 100 (partial 90 99);
  check_range "bytes=-500" 100 (partial 0 99);
  check_range "bytes=-0" 100 R.Unsatisfiable;

  (* A first-pos at or past the end has nothing to return. This is the case
     that must be 416 rather than an empty 206, or a client loops. *)
  check_range "bytes=100-" 100 R.Unsatisfiable;
  check_range "bytes=200-300" 100 R.Unsatisfiable;
  check_range "bytes=0-0" 0 R.Unsatisfiable;

  (* Malformed or declined forms fall back to the whole representation, which
     is a correct response rather than an error. *)
  check_range "bytes=abc-def" 100 R.Whole;
  check_range "bytes=" 100 R.Whole;
  check_range "items=0-10" 100 R.Whole;
  check_range "bytes=20-10" 100 R.Whole;
  check_range "bytes=0-10,20-30" 100 R.Whole;
  check_range "BYTES=0-9" 100 (partial 0 9);
  check_range " bytes=0-9 " 100 (partial 0 9);

  check "length_of is inclusive" (R.length_of { R.first = 0; last = 99 } = 100);
  check "content-range formats"
    (R.content_range { R.first = 5; last = 9 } ~length:100 = "bytes 5-9/100");
  check "416 content-range names the length"
    (R.unsatisfiable_content_range ~length:100 = "bytes */100");

  (* ------------------------------------------------------- path safety *)
  let resolves target expected =
    check
      (Printf.sprintf "resolve %S" target)
      (U.resolve target = expected)
  in
  resolves "/" (Some [ "index.html" ]);
  resolves "/index.html" (Some [ "index.html" ]);
  resolves "/assets/app.js" (Some [ "assets"; "app.js" ]);
  resolves "/assets//app.js" (Some [ "assets"; "app.js" ]);
  resolves "/assets/app.js?v=2" (Some [ "assets"; "app.js" ]);

  (* Traversal, in every spelling. Percent-decoding happens before validation;
     validating first would accept %2e%2e and hand back "..". *)
  resolves "/../etc/passwd" None;
  resolves "/assets/../../etc/passwd" None;
  resolves "/%2e%2e/etc/passwd" None;
  resolves "/%2E%2E/etc/passwd" None;
  resolves "/assets/%2e%2e%2fsecret" None;
  resolves "/.git/config" None;
  resolves "/.env" None;
  resolves "/a%00b" None;
  resolves "/a\\b" None;
  resolves "/%zz" None;
  resolves "/%2" None;

  (* Percent-decoding still has to work for legitimate names. *)
  resolves "/assets/a%20b.png" (Some [ "assets"; "a b.png" ]);

  (* ------------------------------------------------------ content types *)
  check "js type" (U.content_type "app.js" = "text/javascript; charset=utf-8");
  check "pmtiles type" (U.content_type "planet.pmtiles" = "application/octet-stream");
  check "unknown type is not guessed"
    (U.content_type "thing.xyzzy" = "application/octet-stream");

  (* Vite emits content-hashed names, and only those may be cached forever. *)
  check "hashed asset is immutable"
    (U.cache_control [ "assets"; "index-D4ipvZ4X.js" ]
    = "public, max-age=31536000, immutable");
  check "index.html is revalidated"
    (U.cache_control [ "index.html" ] = "no-cache");
  check "short suffix is not a hash"
    (U.cache_control [ "my-app.js" ] = "no-cache");

  (* ------------------------------------------------------------ routing *)
  let routes meth target expected =
    check
      (Printf.sprintf "route %s" target)
      (Route.of_request ~meth ~target = expected)
  in
  routes `GET "/healthz" Route.Health;
  routes `GET "/" (Route.Asset [ "index.html" ]);
  routes `GET "/assets/app.js" (Route.Asset [ "assets"; "app.js" ]);
  routes `GET "/basemap/planet.pmtiles" (Route.Basemap [ "planet.pmtiles" ]);
  routes `POST "/api/encode" (Route.Api "encode");
  routes `GET "/api/encode" Route.Method_not_allowed;
  routes `POST "/assets/app.js" Route.Method_not_allowed;
  routes `GET "/basemap" Route.Not_found;
  routes `GET "/../etc/passwd" Route.Not_found;
  routes `HEAD "/basemap/planet.pmtiles" (Route.Basemap [ "planet.pmtiles" ]);

  (* The tile endpoint: strict, so every accepted URL names exactly one
     tile id. Everything else must be Not_found, not a guess. *)
  routes `GET "/tiles/0/0/0.mvt" (Route.Tile { z = 0; x = 0; y = 0 });
  routes `GET "/tiles/15/16368/10893.mvt"
    (Route.Tile { z = 15; x = 16368; y = 10893 });
  routes `GET "/tiles/0/0/0.mvt?v=3" (Route.Tile { z = 0; x = 0; y = 0 });
  routes `GET "/tiles/3/8/0.mvt" Route.Not_found;
  routes `GET "/tiles/3/04/0.mvt" Route.Not_found;
  routes `GET "/tiles/3/4/0.png" Route.Not_found;
  routes `GET "/tiles/3/4.mvt" Route.Not_found;
  routes `GET "/tiles/-1/0/0.mvt" Route.Not_found;
  routes `GET "/tiles/27/0/0.mvt" Route.Not_found;
  routes `POST "/tiles/0/0/0.mvt" Route.Method_not_allowed;
  routes `GET "/tiles.json" Route.Tile_json;
  routes `GET "/tiles.json?v=4" Route.Tile_json;
  routes `POST "/tiles.json" Route.Method_not_allowed;

  (* A single-page app owns its own routes: a deep link must survive a reload,
     but a missing script must stay a 404 or every typo looks like the app. *)
  check "extensionless path falls back to the shell"
    (Route.is_spa_fallback [ "somewhere" ]);
  check "missing script does not fall back"
    (not (Route.is_spa_fallback [ "assets"; "app.js" ]));

  (* ------------------------------------------------------- rate limiting *)
  (* The clock is a parameter, so the interesting times can be tested directly
     rather than by sleeping through them. *)
  let module R = Tessarium_server.Rate_limit in
  let cfg = { R.rate = 1.0; burst = 3.0 } in

  (* A cold bucket is full, and the first call must not be refused. *)
  let allowed, st = R.take cfg (R.create cfg) ~now:1000.0 in
  check "first request is allowed" allowed;

  (* Burst is spendable, then exhausted. *)
  let allowed2, st = R.take cfg st ~now:1000.0 in
  let allowed3, st = R.take cfg st ~now:1000.0 in
  let allowed4, st = R.take cfg st ~now:1000.0 in
  check "burst of 3 is spendable" (allowed2 && allowed3);
  check "the fourth in a burst is refused" (not allowed4);
  check "a refused request reports how long to wait"
    (R.retry_after cfg st ~now:1000.0 >= 1);

  (* And refills at the configured rate. *)
  let allowed5, st = R.take cfg st ~now:1001.5 in
  check "refills over time" allowed5;
  (* After an idle age the bucket is full, not overflowing: exactly `burst`
     requests succeed and the next does not. A refill that ignored the ceiling
     would let one quiet hour pay for unlimited derivations. *)
  check "refill stops at the burst ceiling"
    (let rec drain n state =
       let allowed, state' = R.take cfg state ~now:1_000_000.0 in
       if allowed then drain (n + 1) state' else n
     in
     drain 0 st = 3);

  (* A clock that goes backwards must not create tokens. *)
  let _, back = R.take cfg (R.create cfg) ~now:1000.0 in
  let b1, back = R.take cfg back ~now:900.0 in
  let b2, back = R.take cfg back ~now:900.0 in
  let b3, _ = R.take cfg back ~now:900.0 in
  check "a backwards clock does not mint tokens" (b1 && b2 && not b3);

  (* ------------------------------------------------- basemap download job *)
  let module J = Tessarium_server.Basemap_job in
  check "a download may start from idle" (J.can_start J.Idle);
  check "a download may restart after done"
    (J.can_start (J.Done { total_bytes = 9; parts = 1 }));
  check "a download may retry after failure" (J.can_start (J.Failed "x"));
  check "a download may restart after cancel" (J.can_start J.Cancelled);
  check "no second download while planning" (not (J.can_start J.Planning));
  check "no second download while fetching"
    (not
       (J.can_start
          (J.Fetching { done_bytes = 0; total_bytes = 9; part = 1; parts = 1 })));
  check "no second download while assets fetch" (not (J.can_start J.Assets));
  check "progress is clamped to the total"
    (J.progress ~done_bytes:120 ~total_bytes:100 ~part:1 ~parts:1
     = J.Fetching { done_bytes = 100; total_bytes = 100; part = 1; parts = 1 });
  check "progress cannot be negative"
    (J.progress ~done_bytes:(-5) ~total_bytes:100 ~part:1 ~parts:1
     = J.Fetching { done_bytes = 0; total_bytes = 100; part = 1; parts = 1 });
  check "part is clamped into 1..parts"
    (J.progress ~done_bytes:0 ~total_bytes:1 ~part:9 ~parts:4
     = J.Fetching { done_bytes = 0; total_bytes = 1; part = 4; parts = 4 }
    && J.progress ~done_bytes:0 ~total_bytes:1 ~part:0 ~parts:0
       = J.Fetching { done_bytes = 0; total_bytes = 1; part = 1; parts = 1 });
  check "a reversed box is refused"
    (Result.is_error (J.validate ~min_lon:1. ~min_lat:0. ~max_lon:0. ~max_lat:1. ~max_zoom:15 ()));
  check "an out-of-range box is refused"
    (Result.is_error (J.validate ~min_lon:(-181.) ~min_lat:0. ~max_lon:0. ~max_lat:1. ~max_zoom:15 ()));
  check "a NaN is refused"
    (Result.is_error (J.validate ~min_lon:Float.nan ~min_lat:0. ~max_lon:1. ~max_lat:1. ~max_zoom:15 ()));
  check "zoom 16 is refused"
    (Result.is_error (J.validate ~min_lon:0. ~min_lat:0. ~max_lon:1. ~max_lat:1. ~max_zoom:16 ()));
  check "an honest box is accepted"
    (Result.is_ok (J.validate ~min_lon:(-0.25) ~min_lat:51.45 ~max_lon:0. ~max_lat:51.55 ~max_zoom:15 ()));

  (* ------------------------------------------------------------------ untar *)
  (* A ustar archive built by hand, because the reader must be tested against
     bytes this test controls, not against whatever tar(1) emits today. *)
  let tar_entry ?(typeflag = '0') ?(prefix = "") name content =
    let b = Bytes.make 512 '\000' in
    Bytes.blit_string name 0 b 0 (String.length name);
    Bytes.blit_string (Printf.sprintf "%011o" (String.length content)) 0 b 124 11;
    Bytes.set b 156 typeflag;
    Bytes.blit_string "ustar\000" 0 b 257 6;
    Bytes.blit_string prefix 0 b 345 (String.length prefix);
    (* Checksum field is not verified by the reader; fill with spaces. *)
    Bytes.blit_string "        " 0 b 148 8;
    let pad = (512 - String.length content mod 512) mod 512 in
    Bytes.to_string b ^ content ^ String.make pad '\000'
  in
  let archive =
    tar_entry ~typeflag:'5' "fonts/" ""
    ^ tar_entry "fonts/a.pbf" "glyphs"
    ^ tar_entry ~prefix:"sprites/deep/path" "light.png" "pixels"
    ^ tar_entry ~typeflag:'x' "pax"
        (let r = "path=fonts/renamed.pbf\n" in
         Printf.sprintf "%d %s" (String.length r + 3) r)
    ^ tar_entry "ignored-short-name" "renamed-body"
    ^ tar_entry "../escape" "evil"
    ^ tar_entry "/abs" "evil"
    ^ String.make 1024 '\000'
  in
  let files = Tessarium_server.Untar.list archive in
  let find n = List.assoc_opt n files in
  check "a plain file is read" (find "fonts/a.pbf" = Some "glyphs");
  check "the prefix field joins long paths"
    (find "sprites/deep/path/light.png" = Some "pixels");
  check "a pax path record renames the next entry"
    (find "fonts/renamed.pbf" = Some "renamed-body");
  check "directories are not files" (find "fonts/" = None);
  check "dotdot entries are dropped" (find "../escape" = None);
  check "absolute entries are dropped" (find "/abs" = None);
  check "nothing unexpected survives" (List.length files = 3);

  (* -------------------------------------------------- basemap endpoints *)
  (* The dispatch is tested with fake ops, so what is asserted is exactly the
     decision layer: which closure runs, with what request, and that a bad
     body never reaches one at all. The real ops touch the network and are
     exercised end-to-end instead. *)
  let module S = Tessarium_server.Serve in
  let module D = Tessarium_server.Basemap_download in
  check "basemap endpoints bypass the api gate"
    (Route.is_basemap_api "basemap-status"
    && Route.is_basemap_api "basemap-download");
  check "the key-material endpoints do not"
    (not (Route.is_basemap_api "session") && not (Route.is_basemap_api "encode"));

  let scfg =
    {
      S.ui_dir = "ui";
      basemap_dir = "basemap";
      api_enabled = false;
      connect_src = [];
      basemap_source = "unused";
      basemap_assets = "unused";
      tile_budget = D.default_budget;
    }
  in
  let calls = ref [] in
  let ops =
    {
      D.estimate =
        (fun req ->
          calls := `Estimate req :: !calls;
          Ok (`Assoc []));
      start =
        (fun ~name req ->
          calls := `Start (name, req) :: !calls;
          Ok ());
      cancel =
        (fun () ->
          calls := `Cancel :: !calls;
          true);
      status =
        (fun () ->
          calls := `Status :: !calls;
          `Assoc []);
      ledger =
        (fun () ->
          calls := `Ledger :: !calls;
          Ok (`Assoc [ ("entries", `List []) ]));
      update =
        (fun ~id ->
          calls := `Update id :: !calls;
          Ok ());
      remove =
        (fun ~id ->
          calls := `Remove id :: !calls;
          Ok ());
      browse =
        (fun req ->
          calls := `Browse req :: !calls;
          Ok (7, req.Tessarium_server.Basemap_job.max_zoom));
      clear_cache = (fun () -> calls := `Clear_cache :: !calls);
      search =
        (fun ~query ~limit ->
          calls := `Search (query, limit) :: !calls;
          Ok (`Assoc [ ("results", `List []) ]));
      coverage =
        (fun req ->
          calls := `Coverage req :: !calls;
          Ok (`Assoc [ ("present", `String "1") ]));
    }
  in
  let settings_calls = ref [] in
  let browse_on = ref true in
  let settings =
    {
      Tessarium_server.Settings.get =
        (fun () ->
          settings_calls := `Get :: !settings_calls;
          Ok (`Assoc [ ("update_reminder_days", `Int 90) ]));
      set =
        (fun ~days ~browse ->
          settings_calls := `Set (days, browse) :: !settings_calls;
          match days with
          | Some d when not (Tessarium_server.Settings.valid_days d) ->
              Error "update_reminder_days must be 0..3650"
          | _ -> Ok (`Assoc []));
      browse_enabled = (fun () -> !browse_on);
    }
  in
  (* Reading a request body must follow what the request declared. Both
     directions of getting this wrong shipped here briefly: reading an
     undeclared body hung a bodyless curl until timeout, and skipping a
     declared one left its bytes in the keep-alive connection, where they
     were parsed as the start of the next request and turned every later
     poll on that connection into a 405. *)
  let h ps = Http.Header.of_list ps in
  check "a declared content-length means a body to drain"
    (S.declares_body (h [ ("content-length", "2") ]));
  check "a chunked body is a body to drain"
    (S.declares_body (h [ ("transfer-encoding", "chunked") ]));
  check "no declaration means nothing to read -- reading would hang"
    (not (S.declares_body (h [ ("accept", "*/*") ])));

  let run ~endpoint ~body =
    calls := [];
    ignore (S.handle_basemap scfg ops settings ~endpoint ~body);
    !calls
  in

  check "status asks the job and needs no body"
    (run ~endpoint:"basemap-status" ~body:"" = [ `Status ]);
  check "cancel reaches the job"
    (run ~endpoint:"basemap-cancel" ~body:"" = [ `Cancel ]);
  let box = {|{"min_lon":-0.25,"min_lat":51.45,"max_lon":0,"max_lat":51.55,"max_zoom":15}|} in
  let wrap boxes = {|{"regions":[|} ^ String.concat "," boxes ^ "]}" in
  (match run ~endpoint:"basemap-download" ~body:(wrap [ box ]) with
  | [ `Start (_, [ (req : Tessarium_server.Basemap_job.request) ]) ] ->
      check "a good box starts a download with the parsed values"
        (req.min_lon = -0.25 && req.max_lat = 51.55 && req.max_zoom = 15);
      (* max_lon arrived as the JSON integer 0 and must still be a number. *)
      check "integer coordinates are accepted" (req.max_lon = 0.)
  | _ -> check "a good box starts a download with the parsed values" false);
  let paris =
    {|{"min_lon":2.1,"min_lat":48.7,"max_lon":2.6,"max_lat":49,"max_zoom":15}|}
  in
  (* Several regions ride in one request, in order: the picker sends its
     whole selection at once and reads the depths back by position. *)
  (match run ~endpoint:"basemap-download" ~body:(wrap [ box; paris ]) with
  | [ `Start (_, [ (a : Tessarium_server.Basemap_job.request); b ]) ] ->
      check "two regions arrive as one download, in order"
        (a.min_lon = -0.25 && b.min_lon = 2.1)
  | _ -> check "two regions arrive as one download, in order" false);
  check "estimate goes to the planner"
    (match run ~endpoint:"basemap-estimate" ~body:(wrap [ box ]) with
    | [ `Estimate _ ] -> true
    | _ -> false);
  check "a malformed body reaches nothing"
    (run ~endpoint:"basemap-download" ~body:"{not json" = []);
  check "a bare box without the regions wrapper reaches nothing"
    (run ~endpoint:"basemap-download" ~body:box = []);
  check "an empty regions list reaches nothing"
    (run ~endpoint:"basemap-download" ~body:{|{"regions":[]}|} = []);
  check "an absurd number of regions reaches nothing"
    (run ~endpoint:"basemap-download"
       ~body:(wrap (List.init 65 (fun _ -> box)))
     = []);
  check "a reversed box reaches nothing"
    (run ~endpoint:"basemap-download"
       ~body:
         (wrap [ {|{"min_lon":1,"min_lat":0,"max_lon":0,"max_lat":1,"max_zoom":15}|} ])
     = []);
  check "one bad box poisons the whole request"
    (run ~endpoint:"basemap-download" ~body:(wrap [ box; "{}" ]) = []);
  let with_polygon =
    {|{"min_lon":-0.25,"min_lat":51.45,"max_lon":0,"max_lat":51.55,"max_zoom":15,"polygon":[[[-0.2,51.46],[-0.05,51.46],[-0.1,51.54]]]}|}
  in
  (match run ~endpoint:"basemap-download" ~body:(wrap [ with_polygon ]) with
  | [ `Start (_, [ (req : Tessarium_server.Basemap_job.request) ]) ] ->
      check "a polygon rides in with its region"
        (match req.polygon with
        | Some [| ring |] -> Array.length ring = 3 && fst ring.(0) = -0.2
        | _ -> false)
  | _ -> check "a polygon rides in with its region" false);
  check "a malformed polygon reaches nothing"
    (run ~endpoint:"basemap-download"
       ~body:
         (wrap
            [
              {|{"min_lon":0,"min_lat":0,"max_lon":1,"max_lat":1,"max_zoom":15,"polygon":[[[0,0],[1]]]}|};
            ])
     = []);
  check "a two-point ring reaches nothing"
    (run ~endpoint:"basemap-download"
       ~body:
         (wrap
            [
              {|{"min_lon":0,"min_lat":0,"max_lon":1,"max_lat":1,"max_zoom":15,"polygon":[[[0,0],[1,1]]]}|};
            ])
     = []);
  (* Every key-touching endpoint shares one ceiling. Encode was once
     unthrottled -- the security write-up's oracle arithmetic was false
     until this held. Eleven calls against a burst of ten: the last must be
     refused, and it must be the limiter refusing (the session id is bogus,
     so an unthrottled server would answer 404, not 429). *)
  Eio_main.run (fun _env ->
      let sessions = S.Sessions.create () in
      let module R = Tessarium_server.Rate_limit in
      let limiter = ref (R.create R.default) in
      let random = Eio.Flow.string_source (String.make 64 'x') in
      (* Status is not observable through the response closure, but body
         LENGTH is: the 404 for a bogus session is 38 bytes, the 429 with
         its retry_after is over 50. *)
      let body_length endpoint body =
        snd (S.handle_api scfg sessions limiter random ~endpoint ~body ~now:1000.)
      in
      let body = {|{"session":"nope","lat_ns":"1","lon_ns":"1"}|} in
      let not_limited = body_length "encode" body in
      let rec drain n last =
        if n = 0 then last else drain (n - 1) (body_length "encode" body)
      in
      let eleventh = drain 10 not_limited in
      check "encode shares the key api's rate ceiling"
        (eleventh > not_limited + 10);
      check "decode shares it too"
        (body_length "decode" {|{"session":"nope","address":"a.b.c.1"}|}
        > not_limited + 10));
  check "the key api is limited; the tile api is not"
    (S.rate_limited_endpoint "session" && S.rate_limited_endpoint "encode"
    && S.rate_limited_endpoint "decode"
    && not (S.rate_limited_endpoint "basemap-status"));

  check "an oversized polygon reaches nothing"
    (let points =
       List.init 2100 (fun i ->
           Printf.sprintf "[%f,%f]" (float_of_int (i mod 100) /. 100.)
             (float_of_int (i / 100) /. 100.))
       |> String.concat ","
     in
     run ~endpoint:"basemap-download"
       ~body:
         (wrap
            [
              {|{"min_lon":0,"min_lat":0,"max_lon":1,"max_lat":1,"max_zoom":15,"polygon":[[|}
              ^ points ^ {|]]}|};
            ])
     = []);
  check "a missing field reaches nothing"
    (run ~endpoint:"basemap-download"
       ~body:(wrap [ {|{"min_lon":1,"min_lat":0,"max_lon":2,"max_zoom":15}|} ])
     = []);

  (* The ledger endpoints: list, update by id, remove by id, and the name a
     download carries into its ledger row. *)
  check "the ledger endpoint asks the ledger"
    (run ~endpoint:"basemap-ledger" ~body:"" = [ `Ledger ]);
  check "update names its entry by id"
    (run ~endpoint:"basemap-update" ~body:{|{"id":"abc123"}|}
    = [ `Update "abc123" ]);
  check "remove names its entry by id"
    (run ~endpoint:"basemap-remove" ~body:{|{"id":"abc123"}|}
    = [ `Remove "abc123" ]);
  check "a malformed or missing id reaches nothing"
    (run ~endpoint:"basemap-update" ~body:{|{"id":"DROP TABLE"}|} = []
    && run ~endpoint:"basemap-remove" ~body:{|{"id":""}|} = []
    && run ~endpoint:"basemap-update" ~body:"{}" = []
    && run ~endpoint:"basemap-remove" ~body:"not json" = []);
  check "a download's name rides along to the ledger"
    (match
       run ~endpoint:"basemap-download"
         ~body:({|{"name":"France","regions":[|} ^ box ^ "]}")
     with
    | [ `Start (Some "France", _) ] -> true
    | _ -> false);
  check "a download without a name still starts"
    (match run ~endpoint:"basemap-download" ~body:(wrap [ box ]) with
    | [ `Start (None, _) ] -> true
    | _ -> false);
  check "a name with control characters reaches nothing"
    (run ~endpoint:"basemap-download"
       ~body:({|{"name":"a\nb","regions":[|} ^ box ^ "]}")
     = []);

  (* Settings: an empty body reads, a value writes, junk reaches nothing. *)
  let run_settings ~body =
    settings_calls := [];
    ignore (S.handle_basemap scfg ops settings ~endpoint:"basemap-settings" ~body);
    !settings_calls
  in
  check "an empty settings body reads the current value"
    (run_settings ~body:"{}" = [ `Get ]);
  check "a settings value writes"
    (run_settings ~body:{|{"update_reminder_days":30}|}
    = [ `Set (Some 30, None) ]);
  check "the browse toggle writes alone, leaving the reminder be"
    (run_settings ~body:{|{"browse_cache":true}|}
    = [ `Set (None, Some true) ]);
  check "a non-boolean browse toggle reaches nothing"
    (run_settings ~body:{|{"browse_cache":"yes"}|} = []);
  (* Off means gone: turning the toggle off also clears the browse cache;
     turning it on touches nothing. *)
  calls := [];
  check "the browse toggle off clears the cache"
    (run_settings ~body:{|{"browse_cache":false}|} = [ `Set (None, Some false) ]
    && !calls = [ `Clear_cache ]);
  calls := [];
  check "the browse toggle on clears nothing"
    (run_settings ~body:{|{"browse_cache":true}|} = [ `Set (None, Some true) ]
    && !calls = []);

  (* The browse endpoint: a viewport box and a zoom, gated server-side on
     the opt-in setting -- the page must not be able to make this server
     reach the network when the user said no. *)
  let browse_body =
    {|{"min_lon":-0.2,"min_lat":51.46,"max_lon":-0.05,"max_lat":51.56,"zoom":15}|}
  in
  (match run ~endpoint:"basemap-browse" ~body:browse_body with
  | [ `Browse (req : Tessarium_server.Basemap_job.request) ] ->
      check "a browse request carries its box at its zoom"
        (req.min_lon = -0.2 && req.max_zoom = 15 && req.polygon = None)
  | _ -> check "a browse request carries its box at its zoom" false);
  check "a browse without a zoom reaches nothing"
    (run ~endpoint:"basemap-browse"
       ~body:{|{"min_lon":-0.2,"min_lat":51.46,"max_lon":-0.05,"max_lat":51.56}|}
     = []);
  check "a browse past the source's depth reaches nothing"
    (run ~endpoint:"basemap-browse"
       ~body:
         {|{"min_lon":-0.2,"min_lat":51.46,"max_lon":-0.05,"max_lat":51.56,"zoom":16}|}
     = []);
  (* JSON has one number type: a serializer spelling 15 as 15.0 is not
     asking for a fractional zoom, and a real fraction still is. *)
  (match
     run ~endpoint:"basemap-browse"
       ~body:
         {|{"min_lon":-0.2,"min_lat":51.46,"max_lon":-0.05,"max_lat":51.56,"zoom":15.0}|}
   with
  | [ `Browse (req : Tessarium_server.Basemap_job.request) ] ->
      check "a decimal spelling of a whole zoom is still that zoom"
        (req.max_zoom = 15)
  | _ -> check "a decimal spelling of a whole zoom is still that zoom" false);
  check "a fractional zoom reaches nothing"
    (run ~endpoint:"basemap-browse"
       ~body:
         {|{"min_lon":-0.2,"min_lat":51.46,"max_lon":-0.05,"max_lat":51.56,"zoom":14.5}|}
     = []);
  browse_on := false;
  check "browsing off means the endpoint is off, server-side"
    (run ~endpoint:"basemap-browse" ~body:browse_body = []);
  browse_on := true;

  (* Coverage: the same viewport shape as browse, and deliberately NOT
     gated on the browse setting -- it reads the archives on disk, which
     is a question about this machine, not a reason to touch the
     network. Turning browsing off must not blind the map to where its
     own tiles end. *)
  let view =
    {|{"min_lon":-0.2,"min_lat":51.46,"max_lon":-0.05,"max_lat":51.56,"zoom":12}|}
  in
  (match run ~endpoint:"basemap-coverage" ~body:view with
  | [ `Coverage (req : Tessarium_server.Basemap_job.request) ] ->
      check "a coverage query carries the displayed zoom, not a depth"
        (req.max_zoom = 12 && req.min_lon = -0.2 && req.polygon = None)
  | _ -> check "a coverage query carries the displayed zoom, not a depth" false);
  browse_on := false;
  check "coverage answers with browsing off"
    (match run ~endpoint:"basemap-coverage" ~body:view with
     | [ `Coverage _ ] -> true
     | _ -> false);
  browse_on := true;
  check "a coverage query without a zoom reaches nothing"
    (run ~endpoint:"basemap-coverage"
       ~body:{|{"min_lon":-0.2,"min_lat":51.46,"max_lon":-0.05,"max_lat":51.56}|}
     = []);
  (* The two ways a coverage query fails are two different statuses, and
     the message survives either way. A viewport bigger than the cap is the
     caller asking for too much; an archive this server cannot read is this
     server's own data gone wrong, and answering that with a 400 blamed the
     page for it. *)
  check "too large a viewport is the caller's mistake"
    (S.coverage_status (D.Too_large "too big") = `Bad_request);
  check "an archive this server cannot read is this server's mistake"
    (S.coverage_status (D.Unreadable "End_of_file") = `Internal_server_error);
  check "and either way the reason reaches the client"
    (S.coverage_message (D.Too_large "too big") = "too big"
    && S.coverage_message (D.Unreadable "End_of_file") = "End_of_file");
  check "a coverage query with inverted bounds reaches nothing"
    (run ~endpoint:"basemap-coverage"
       ~body:
         {|{"min_lon":0.5,"min_lat":51.46,"max_lon":-0.05,"max_lat":51.56,"zoom":12}|}
     = []);

  (* Compaction obeys the one-writer rule like everything else. *)
  check "nothing starts while a compaction runs"
    (not
       (Tessarium_server.Basemap_job.can_start
          (Compacting { done_bytes = 0; total_bytes = 1 })));
  check "a compaction is a running job"
    (Tessarium_server.Basemap_job.is_running
       (Compacting { done_bytes = 0; total_bytes = 1 }));
  check "a non-integer setting reaches nothing"
    (run_settings ~body:{|{"update_reminder_days":"soon"}|} = []
    && run_settings ~body:"not json" = []);

  (* The settings file format itself. *)
  let module St = Tessarium_server.Settings in
  check "settings round-trip"
    (St.of_string
       (St.to_string { St.update_reminder_days = 30; browse_cache = true })
    = Ok { St.update_reminder_days = 30; browse_cache = true });
  check "the defaults are 90 days and no browsing cache"
    (St.default = { St.update_reminder_days = 90; browse_cache = false });
  check "settings written before the browse cache read as off"
    (St.of_string {|{"update_reminder_days":30}|}
    = Ok { St.update_reminder_days = 30; browse_cache = false });
  check "reminder bounds hold"
    (St.valid_days 0 && St.valid_days 3650
    && (not (St.valid_days (-1)))
    && not (St.valid_days 3651));
  check "corrupt settings are loud"
    (match St.of_string "nope" with Error _ -> true | Ok _ -> false);
  check "out-of-range stored settings are refused"
    (match St.of_string {|{"update_reminder_days":9999}|} with
    | Error _ -> true
    | Ok _ -> false);

  (* The status envelope carries a generation alongside the job: a fast
     download can run idle-to-done between two polls, and only an identity
     lets a poller tell fresh news from stale. Under Eio_main because the
     runner's mutex needs a fiber context, not because anything here does
     IO. *)
  Eio_main.run @@ fun _env ->
  let runner = D.create () in
  check "a fresh runner reports generation zero and an idle job"
    (D.status runner
    = `Assoc
        [
          ("generation", `Int 0);
          ("job", `Assoc [ ("state", `String "idle") ]);
        ]);
  check "cancel with nothing running cancels nothing" (not (D.cancel runner));

  (* --------------------------------------------------- download ledger *)
  (* The ledger is the record of what the archive holds, kept inside the
     archive. Its contract is exactness: canonical bytes for the same
     content, an identity blind to everything but the regions, and loud
     failure on anything it cannot read back perfectly. *)
  let module L = Tessarium_server.Ledger in
  let module J = Tessarium_server.Basemap_job in
  let reg ?polygon ~z (a, b, c, d) =
    Result.get_ok
      (J.validate ?polygon ~min_lon:a ~min_lat:b ~max_lon:c ~max_lat:d
         ~max_zoom:z ())
  in
  let france = reg ~z:15 (-5.1, 41.3, 9.6, 51.1) in
  let georgia = reg ~z:15 (-85.6, 30.3, -80.8, 35.0) in
  let entry ?(name = "France") ?(completed = 1_787_000_000)
      ?(source = "https://build.protomaps.com/20260818.pmtiles")
      ?(bytes = 123_456) regions =
    L.make ~name ~regions ~completed ~source ~bytes
  in

  (* Serialization: exact round-trip, byte-stable, empty means absent. *)
  let e1 = entry [ france ] in
  let meta1 = Result.get_ok (L.to_metadata [ e1 ] ~previous:"{}") in
  check "a ledger round-trips through archive metadata exactly"
    (L.of_metadata meta1 = Ok [ e1 ]);
  check "serialization is byte-stable across a parse cycle"
    (Result.get_ok
       (L.to_metadata (Result.get_ok (L.of_metadata meta1)) ~previous:"{}")
    = meta1);
  check "an empty ledger writes no metadata key at all"
    (L.to_metadata [] ~previous:"{}" = Ok "{}");
  check "removing the last entry leaves metadata as if none ever existed"
    (L.to_metadata [] ~previous:meta1 = Ok "{}");
  check "archives without a ledger read as empty" (L.of_metadata "{}" = Ok []);
  check "foreign metadata keys survive a ledger write in place"
    (match L.to_metadata [ e1 ] ~previous:{|{"author":"protomaps"}|} with
    | Ok s ->
        (match Yojson.Safe.from_string s with
        | `Assoc (("author", `String "protomaps") :: _) ->
            L.of_metadata s = Ok [ e1 ]
        | _ -> false)
    | Error _ -> false);

  (* Identity: the regions and nothing else, in any order. *)
  let polygon = [| [| (-5., 42.); (9., 42.); (2., 51.) |] |] in
  let france_clipped = reg ~polygon ~z:15 (-5.1, 41.3, 9.6, 51.1) in
  check "the same regions in a different order are the same entry"
    (L.id (entry [ france; georgia ]) = L.id (entry [ georgia; france ]));
  check "order-insensitive entries serialize to identical bytes"
    (L.to_metadata [ entry [ france; georgia ] ] ~previous:"{}"
    = L.to_metadata [ entry [ georgia; france ] ] ~previous:"{}");
  check "name, time, source and size do not change identity"
    (L.id (entry [ france ])
    = L.id
        (entry ~name:"Frankreich" ~completed:1 ~source:"other" ~bytes:9
           [ france ]));
  check "moving a box changes identity"
    (L.id (entry [ france ]) <> L.id (entry [ reg ~z:15 (-5.1, 41.3, 9.6, 51.2) ]));
  check "a deeper zoom changes identity"
    (L.id (entry [ france ]) <> L.id (entry [ reg ~z:14 (-5.1, 41.3, 9.6, 51.1) ]));
  check "a polygon changes identity"
    (L.id (entry [ france ]) <> L.id (entry [ france_clipped ]));
  check "a clipped region round-trips with its polygon intact"
    (let m =
       Result.get_ok (L.to_metadata [ entry [ france_clipped ] ] ~previous:"{}")
     in
     L.of_metadata m = Ok [ entry [ france_clipped ] ]);

  (* Edits: same id replaces in place, new id appends, remove is exact. *)
  let e2 = entry ~name:"Georgia" [ georgia ] in
  check "recording a new region appends"
    (L.record [ e1 ] e2 = [ e1; e2 ]);
  check "recording the same regions replaces in place"
    (L.record [ e1; e2 ] (entry ~bytes:999 [ france ])
    = [ entry ~bytes:999 [ france ]; e2 ]);
  check "remove returns the entry and the rest"
    (L.remove [ e1; e2 ] ~id:(L.id e2) = Some (e2, [ e1 ]));
  check "remove of an unknown id is None" (L.remove [ e1 ] ~id:"nope" = None);
  check "find locates by id" (L.find [ e1; e2 ] ~id:(L.id e2) = Some e2);

  (* Corruption is loud, never an empty ledger. *)
  let unreadable = function Error _ -> true | Ok _ -> false in
  check "non-JSON metadata is an error"
    (unreadable (L.of_metadata "<html>"));
  check "non-object metadata is an error" (unreadable (L.of_metadata "[]"));
  let mentions sub s =
    let n = String.length sub in
    let rec go i =
      i + n <= String.length s && (String.sub s i n = sub || go (i + 1))
    in
    go 0
  in
  check "a newer ledger version is refused, saying so"
    (match L.of_metadata {|{"tessarium_ledger":{"v":2,"entries":[]}}|} with
    | Error m -> mentions "newer" m
    | Ok _ -> false);
  check "a ledger without a version is refused"
    (unreadable (L.of_metadata {|{"tessarium_ledger":{"entries":[]}}|}));
  check "an entry with an invalid region is refused"
    (unreadable
       (L.of_metadata
          {|{"tessarium_ledger":{"v":1,"entries":[{"name":"x","completed":0,"source":"s","bytes":0,"regions":[{"min_lon":9,"min_lat":0,"max_lon":2,"max_lat":1,"max_zoom":15}]}]}}|}));
  check "an entry with no regions is refused"
    (unreadable
       (L.of_metadata
          {|{"tessarium_ledger":{"v":1,"entries":[{"name":"x","completed":0,"source":"s","bytes":0,"regions":[]}]}}|}));
  check "corrupt metadata does not blank the ledger on write either"
    (unreadable (L.to_metadata [ e1 ] ~previous:"not json"));

  (* Names: bounded, printable, UTF-8. *)
  check "plain and accented names are valid"
    (L.valid_name "France" && L.valid_name "Besançon, Québec");
  check "the empty name is invalid" (not (L.valid_name ""));
  check "control characters are invalid"
    (not (L.valid_name "a\nb") && not (L.valid_name "a\x7f"));
  check "broken UTF-8 is invalid" (not (L.valid_name "\xff\xfe"));
  check "over-long names are invalid"
    (not (L.valid_name (String.make 121 'x')));
  check "names at the limit are valid" (L.valid_name (String.make 120 'x'));

  (* Removal geometry, on exact tile boundaries. The rule: Remove undoes
     the download. A tile goes exactly when the removed entry's download
     would have fetched it -- everything its region touches, ancestors
     included, down to the zoom it asked for -- and no kept entry's
     download would fetch it too. *)
  let tl, tb, tr, tt = Pmtiles.Tile_id.tile_box ~z:3 ~x:4 ~y:3 in
  let cell = reg ~z:4 (tl, tb, tr, tt) in
  let removed = entry ~name:"cell" [ cell ] in
  let drops = L.drops ~removed ~kept:[] in
  check "the exact tile of a box region is dropped" (drops ~z:3 ~x:4 ~y:3);
  check "its children are dropped" (drops ~z:4 ~x:8 ~y:6);
  check "the parent goes too -- the download fetched the whole pyramid"
    (drops ~z:2 ~x:2 ~y:1);
  check "a tile beyond the region is kept" (not (drops ~z:3 ~x:6 ~y:3));
  check "tiles deeper than the entry ever fetched are kept"
    (not (drops ~z:5 ~x:16 ~y:12));
  let protected = L.drops ~removed ~kept:[ entry ~name:"same" [ cell ] ] in
  check "a kept entry over the same box protects every tile"
    ((not (protected ~z:3 ~x:4 ~y:3))
    && (not (protected ~z:4 ~x:8 ~y:6))
    && not (protected ~z:2 ~x:2 ~y:1));
  let shallow = L.drops ~removed ~kept:[ entry [ reg ~z:3 (tl, tb, tr, tt) ] ] in
  check "a shallower kept entry protects only the zooms it fetched"
    ((not (shallow ~z:3 ~x:4 ~y:3)) && shallow ~z:4 ~x:8 ~y:6);
  let pad = 0.01 in
  let quad =
    [| [| (tl -. pad, tb -. pad); (tr +. pad, tb -. pad);
          (tr +. pad, tt +. pad); (tl -. pad, tt +. pad) |] |]
  in
  let clipped_cell = reg ~polygon:quad ~z:4 (tl -. pad, tb -. pad, tr +. pad, tt +. pad) in
  let pdrops = L.drops ~removed:(entry [ clipped_cell ]) ~kept:[] in
  check "a tile inside the polygon is dropped" (pdrops ~z:3 ~x:4 ~y:3);
  check "a border tile goes too -- the clipped download fetched it"
    (pdrops ~z:3 ~x:5 ~y:3);
  check "a tile wholly outside the polygon is kept"
    (not (pdrops ~z:3 ~x:6 ~y:3));

  (* [Ledger.fetches] must be the covering's membership function EXACTLY --
     the review that demanded this found a geometric edge-touch test
     claiming the west and north neighbours of a tile-aligned box, which
     the covering never fetches. Checked as a property: for boxes plain,
     tile-aligned and clipped, every tile in a z0..5 universe is claimed by
     [drops] iff the planner's covering lists it. *)
  let module T = Pmtiles.Tile_id in
  let universe f =
    let ok = ref true in
    for z = 0 to 5 do
      let n = 1 lsl z in
      for x = 0 to n - 1 do
        for y = 0 to n - 1 do
          if not (f ~z ~x ~y) then ok := false
        done
      done
    done;
    !ok
  in
  let agrees ?polygon ~z:max_zoom (a, b, c, d) =
    let ids =
      match polygon with
      | None ->
          T.covering ~min_zoom:0 ~max_zoom ~min_lon:a ~min_lat:b ~max_lon:c
            ~max_lat:d
      | Some rings ->
          T.covering_clipped ~min_zoom:0 ~max_zoom ~min_lon:a ~min_lat:b
            ~max_lon:c ~max_lat:d
            ~clip:(Pmtiles.Clip.of_rings rings)
            ()
    in
    let drops =
      L.drops ~removed:(entry [ reg ?polygon ~z:max_zoom (a, b, c, d) ])
        ~kept:[]
    in
    universe (fun ~z ~x ~y ->
        drops ~z ~x ~y = List.mem (T.of_zxy ~z ~x ~y) ids)
  in
  check "drops = covering, on an ordinary box" (agrees ~z:4 (-5.1, 41.3, 9.6, 51.1));
  check "drops = covering, on an exactly tile-aligned box"
    (agrees ~z:4 (tl, tb, tr, tt));
  check "drops = covering, on a sliver crossing a tile boundary"
    (agrees ~z:5 (tl -. 0.001, tb, tl +. 0.001, tt));
  check "drops = covering, clipped to a triangle"
    (agrees ~polygon:[| [| (-5., 42.); (9., 42.); (2., 51.) |] |] ~z:4
       (-5.1, 41.3, 9.6, 51.1));
  check "drops = covering, clipped to the padded quad"
    (agrees ~polygon:quad ~z:4 (tl -. pad, tb -. pad, tr +. pad, tt +. pad));

  (* Signed zero is the same bound: one region, one identity, and ties in
     the sort cannot reorder the bytes. *)
  check "negative zero does not split an identity"
    (L.id (entry [ reg ~z:15 (-0.0, 41.3, 9.6, 51.1) ])
    = L.id (entry [ reg ~z:15 (0.0, 41.3, 9.6, 51.1) ]));

  (* A ledger key that appears twice would make reads and writes resolve
     differently; both refuse it. *)
  let doubled =
    {|{"tessarium_ledger":{"v":1,"entries":[]},"tessarium_ledger":{"v":1,"entries":[]}}|}
  in
  check "a duplicated ledger key is refused on read"
    (unreadable (L.of_metadata doubled));
  check "a duplicated ledger key is refused on write"
    (unreadable (L.to_metadata [ e1 ] ~previous:doubled));

  (* Invisible characters exist mostly to make one name display as another. *)
  check "C1 controls are invalid" (not (L.valid_name "a\xc2\x85b"));
  check "zero-width characters are invalid"
    (not (L.valid_name "a\xe2\x80\x8bb"));
  check "bidi overrides are invalid" (not (L.valid_name "a\xe2\x80\xaeb"));
  check "ordinary multi-byte names stay valid" (L.valid_name "北京 – Beijing");

  (* A browse is served at the depth the SOURCE can reach, not the one the
     view asked for, and that answer goes back to the client: it decides
     from it whether deeper tiles have actually arrived. Getting this wrong
     is invisible on the server and leaves the map either blank or
     rebuilding its style on every pan. *)
  let header ~min_zoom ~max_zoom =
    {
      Pmtiles.Header.root_offset = 127;
      root_length = 0;
      metadata_offset = 127;
      metadata_length = 0;
      leaf_offset = 127;
      leaf_length = 0;
      data_offset = 127;
      data_length = 0;
      addressed_tiles = 0;
      tile_entries = 0;
      tile_contents = 0;
      clustered = true;
      internal_compression = Pmtiles.Header.None_;
      tile_compression = Pmtiles.Header.Gzip;
      tile_type = Pmtiles.Header.Mvt;
      min_zoom;
      max_zoom;
      min_lon_e7 = 0;
      min_lat_e7 = 0;
      max_lon_e7 = 0;
      max_lat_e7 = 0;
      center_zoom = 0;
      center_lon_e7 = 0;
      center_lat_e7 = 0;
    }
  in
  let h0_15 = header ~min_zoom:0 ~max_zoom:15 in
  let h0_6 = header ~min_zoom:0 ~max_zoom:6 in
  check "a browse within the source's depth is served there"
    (D.browse_zoom ~header:h0_15 ~requested:12 = 12);
  check "a browse past the source's depth is served at the source's"
    (D.browse_zoom ~header:h0_6 ~requested:15 = 6);
  check "and never above the source's shallowest level"
    (D.browse_zoom ~header:(header ~min_zoom:5 ~max_zoom:15) ~requested:2 = 5);

  (* --------------------------------------------------------- search *)
  (* Accents and case must not decide whether a place can be found: a French
     user typing "orleans" on an English keyboard is asking for Orléans. *)
  let module P = Tessarium_server.Place_index in
  check "folding drops case" (P.fold "MARSEILLE" = "marseille");
  check "folding drops accents" (P.fold "Orléans" = "orleans");
  check "folding leaves other scripts alone" (P.fold "Энурмино" = "Энурмино");

  (* A line survives the file it is written to. *)
  let e =
    {
      P.name = "Fixtureville";
      kind = "locality";
      layer = "places";
      weight = 4242.;
      lon = 2.3484;
      lat = 48.8535;
    }
  in
  (match P.of_line (P.to_line e) with
  | Some back ->
      check "an index line round-trips"
        (back.P.name = e.P.name && back.P.kind = e.P.kind
       && back.P.weight = e.P.weight
       && Float.abs (back.P.lon -. e.P.lon) < 1e-6
       && Float.abs (back.P.lat -. e.P.lat) < 1e-6)
  | None -> check "an index line round-trips" false);
  check "a truncated line is skipped, not fatal" (P.of_line "junk" = None);
  check "a line with no name is skipped"
    (* Seven fields, so it is the empty NAME that rejects it rather than the
       arity -- the six-field version passed this check without ever
       reaching the guard it is named after. *)
    (P.of_line "\t\tlocality\tplaces\t0\t1.0\t2.0" = None);

  (* Eleven French places are called Paris. Ranking exists so the one with
     two million people is offered first, and so an exact match is never
     buried under a longer name that merely contains it. *)
  let place ?(weight = 0.) ?(layer = "places") name =
    { P.name; kind = "locality"; layer; weight; lon = 0.; lat = 0. }
  in
  let big = place ~weight:2_100_000. "Paris" in
  let small = place ~weight:200. "Paris" in
  check "population decides between identical names"
    (P.compare_entry big small < 0);
  check "a town outranks a road of the same name"
    (P.compare_entry (place "Rivoli") (place ~layer:"roads" "Rivoli") < 0);

  (* Ranking bands, in the order the comments claim: an exact name beats one
     that merely starts with the query, which beats a match at a word
     boundary, which beats one buried mid-word. *)
  let band q name =
    match P.score_of ~needle:(P.fold q) (P.fold name) with
    | Some s -> s / 100_000
    | None -> -1
  in
  check "an exact name scores best" (band "york" "York" = 0);
  check "then a name that starts with it" (band "york" "Yorkshire" = 1);
  check "then a match at a word boundary" (band "york" "New York Road" = 2);
  check "then one buried in a word" (band "ork" "Yorkshire" = 3);
  check "and a name without it does not match" (band "zzz" "York" = -1);
  (* The best occurrence decides, not the first: scanning left to right and
     stopping would score this as buried. *)
  check "a later word-start beats an earlier mid-word hit"
    (band "ork" "Yorkshire ork lane" = 2);
  check "a shorter name wins inside a band"
    (P.score_of ~needle:"york" (P.fold "Yorkshire")
    < P.score_of ~needle:"york" (P.fold "Yorkshire Road"));

  (* A query is how a person names a place, not a substring of one row.

     "Atlanta, GA" appears inside no name anywhere, so matching the query
     as one run of characters answered a perfectly good question with
     nothing found -- and got worse the more precisely the place was
     named, which is backwards. *)
  let q = P.parse_query in
  check "the comma separates the name from its context"
    ((q "Atlanta, GA").P.head = [ "atlanta" ]
    && (q "Atlanta, GA").P.context = [ "ga" ]
    && (q "Paris,France").P.context = [ "france" ]);
  check "with no comma, every word is part of the name"
    ((q "Los Angeles").P.head = [ "los"; "angeles" ]
    && (q "Los Angeles").P.context = []);
  check "punctuation inside a name splits it into its words"
    ((q "Saint-Étienne").P.head = [ "saint"; "etienne" ]
    && (q "L'Haÿ-les-Roses").P.head = [ "l"; "hay"; "les"; "roses" ]);
  check "letters in other scripts stay whole"
    ((q "Энурмино").P.head = [ "Энурмино" ]);
  check "pasted punctuation reads as punctuation"
    (* A non-breaking space and a curly apostrophe are what arrives when a
       name is copied off a web page rather than typed. *)
    ((q "Los\xc2\xa0Angeles").P.head = [ "los"; "angeles" ]
    && (q "L\xe2\x80\x99Hay").P.head = [ "l"; "hay" ]
    && (q "Atlanta\xef\xbc\x8cGA").P.context = [ "ga" ]);
  check "more words than name anything are dropped rather than scanned"
    (List.length (q "a b c d e f g h i").P.head = 6
    && List.length (q "x, a b c d").P.context = 2);

  (* Ranking. Every one of these was wrong at some point against the real
     archive, and the number beside it is the population of the answer that
     ought to come first. *)
  let rank query name =
    match P.match_of ~query:(P.parse_query query) (P.fold name) with
    | Some quality -> P.rank_key quality
    | None -> max_int
  in
  check "the place named beats a place named after its first word"
    (* "Los" is a name exactly; "Los Angeles" merely begins with the word.
       Ranking exactness first answered Los Angeles (3,863,148) with a
       hamlet of 100 people. *)
    (rank "Los Angeles" "Los Angeles" < rank "Los Angeles" "Los"
    && rank "Las Vegas" "Las Vegas" < rank "Las Vegas" "Las"
    && rank "Kansas City" "Kansas City" < rank "Kansas City" "Kansas");
  check "and a name with an apostrophe is not beaten by its first letter"
    (rank "L'Hay-les-Roses" "L'Hay-les-Roses" < rank "L'Hay-les-Roses" "L");
  check "the city beats a lake that happens to carry the context"
    (* "ga" hides inside "Gas", "Gardens" and "Maçons", so context that
       decided rather than ranked answered "Atlanta, GA" with Atlanta Gas
       Light Lake and "Savannah, GA" with Savannah Gardens. *)
    (rank "Atlanta, GA" "Atlanta" < rank "Atlanta, GA" "Atlanta Gas Light Lake");
  check "and beats a hospital that carries the state in full"
    (rank "Atlanta, Georgia" "Atlanta"
    < rank "Atlanta, Georgia" "Georgia Regional Hospital Atlanta");
  check "context still breaks a tie between otherwise equal names"
    (* Same first word, same band, same length: all that is left is which
       one carries what came after the comma. *)
    (rank "Alpha, France" "Alpha France" < rank "Alpha, France" "Alpha Xxxxxx");
  check "the words of a name may arrive in either order"
    (rank "york new" "New York" < rank "york new" "York");
  check "a name lacking the first word is no answer at all"
    (rank "Atlanta, GA" "Georgia Gas" = max_int);

  (* Names arrive from tiles this project did not write, and the record
     separator must not be forgeable. *)
  let forged =
    {
      P.name = "Innocent\nEVIL\tEvil Display";
      kind = "locality";
      layer = "places";
      weight = 0.;
      lon = 1.;
      lat = 2.;
    }
  in
  let line = P.to_line forged in
  check "a name cannot smuggle a newline into the index"
    (not (String.contains line '\n'));
  check "nor forge a second row with a tab"
    (List.length (String.split_on_char '\t' line) = 7);

  (* Folding reaches past Latin-1: a Nordic download is searchable by
     someone typing lower case. *)
  check "case folds in Latin Extended-A" (P.fold "Ĉ" = P.fold "ĉ");
  check "and for the Latin-1 letters with no ASCII form"
    (P.fold "Ørsta" = P.fold "ørsta");

  (* The wire shape of a job state is a contract with the UI, which parses
     it as a tagged union and THROWS on anything it does not know. A state
     added here without its client counterpart does not degrade -- it breaks
     status polling for the whole job, which is how the indexing state
     shipped broken once already. *)
  let state_json j =
    match Tessarium_server.Basemap_job.to_json j with
    | `Assoc fields -> List.map fst fields
    | _ -> []
  in
  check "indexing reports tiles, not bytes"
    (state_json (Indexing { done_tiles = 3; total_tiles = 9 })
    = [ "state"; "done_tiles"; "total_tiles" ]);
  check "and names itself the way the client matches on"
    (match Tessarium_server.Basemap_job.to_json
             (Indexing { done_tiles = 0; total_tiles = 1 })
     with
    | `Assoc fields -> List.assoc_opt "state" fields = Some (`String "indexing")
    | _ -> false);
  check "indexing is a running job"
    (Tessarium_server.Basemap_job.is_running
       (Indexing { done_tiles = 0; total_tiles = 1 }));
  check "and nothing else may start during it"
    (not
       (Tessarium_server.Basemap_job.can_start
          (Indexing { done_tiles = 0; total_tiles = 1 })));

  (* The Removing job state obeys the same one-writer rule as downloads. *)
  check "nothing starts while a removal runs"
    (not (J.can_start (J.Removing { done_bytes = 0; total_bytes = 1 })));
  check "a removal is a running job"
    (J.is_running (J.Removing { done_bytes = 0; total_bytes = 1 }));

  (* A settings write serializes against other writers, and the lock it uses
     POISONS on any exception escaping the critical section: Eio refuses a
     poisoned mutex forever after. So a transient read failure -- a bad mode
     on the file, an exhausted fd table -- must not be allowed to escape, or
     one unlucky request costs the user their settings endpoint for the
     lifetime of the process. Driven against a real directory, because the
     failure is the filesystem's. *)
  Eio_main.run (fun env ->
      let fs = Eio.Stdenv.fs env in
      let dir = Filename.temp_file "tessarium-settings" "" in
      Sys.remove dir;
      Unix.mkdir dir 0o755;
      let ops = Tessarium_server.Settings.ops ~fs ~basemap_dir:dir in
      let path = Filename.concat dir "settings.json" in
      (match ops.set ~days:(Some 30) ~browse:None with
      | Ok _ -> ()
      | Error e -> check ("the first write succeeds: " ^ e) false);
      (* Unreadable: the load inside the critical section now raises. Root
         ignores the mode and would make this prove nothing, so the failure
         is confirmed before anything is concluded from it rather than
         assumed from the chmod. *)
      Unix.chmod path 0o000;
      let readable =
        match open_in_bin path with
        | ic ->
            close_in ic;
            true
        | exception _ -> false
      in
      if readable then
        print_endline
          "  SKIP  settings lock poisoning (this user can read 0o000 files)"
      else begin
        let blocked = ops.set ~days:(Some 45) ~browse:None in
        check "a write over an unreadable settings file fails"
          (Result.is_error blocked);
        Unix.chmod path 0o644;
        match ops.set ~days:(Some 60) ~browse:None with
        | Ok json ->
            check "and the next write still works -- the lock is not poisoned"
              (Yojson.Safe.Util.member "update_reminder_days" json = `Int 60)
        | Error e ->
            check
              ("and the next write still works -- the lock is not poisoned ("
             ^ e ^ ")")
              false
      end);

  (* WHICH core the server answers from, asserted rather than assumed.

     The side-by-side wall proves the two cores AGREE, which is exactly why
     it cannot notice if serve.ml is rewired back to the extracted one. So
     probe a point where they deliberately disagree: a word index of 2048 is
     outside the proved core's domain, and the FFI stubs refuse it, while the
     extracted core computes over unbounded nats and answers. `address_of_string`
     cannot produce such a tuple, so this is unreachable through the API --
     it is a fingerprint, not a behaviour anyone depends on. *)
  let key = String.make 32 '\007' in
  let out_of_domain = (Z.of_int 2048, Z.zero, Z.zero, Z.zero) in
  check "the server's injected core is the C one, not the extracted one"
    (match Tessarium_server.Serve.core.Tessarium.decode ~key out_of_domain with
     | exception Invalid_argument _ -> true
     | _ -> false);
  check "and the extracted core is what it is being distinguished from"
    (match Tessarium.extracted_core.Tessarium.decode ~key out_of_domain with
     | exception Invalid_argument _ -> false
     | _ -> true);

  Printf.printf "\n%d checks, %d failures\n" !checks !failures;
  if !failures > 0 then exit 1 else print_endline "server decisions hold"
