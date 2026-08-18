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
  check "a download may restart after done" (J.can_start (J.Done { total_bytes = 9 }));
  check "a download may retry after failure" (J.can_start (J.Failed "x"));
  check "a download may restart after cancel" (J.can_start J.Cancelled);
  check "no second download while planning" (not (J.can_start J.Planning));
  check "no second download while fetching"
    (not (J.can_start (J.Fetching { done_bytes = 0; total_bytes = 9 })));
  check "no second download while assets fetch" (not (J.can_start J.Assets));
  check "progress is clamped to the total"
    (J.progress ~done_bytes:120 ~total_bytes:100
     = J.Fetching { done_bytes = 100; total_bytes = 100 });
  check "progress cannot be negative"
    (J.progress ~done_bytes:(-5) ~total_bytes:100
     = J.Fetching { done_bytes = 0; total_bytes = 100 });
  check "a reversed box is refused"
    (Result.is_error (J.validate ~min_lon:1. ~min_lat:0. ~max_lon:0. ~max_lat:1. ~max_zoom:15));
  check "an out-of-range box is refused"
    (Result.is_error (J.validate ~min_lon:(-181.) ~min_lat:0. ~max_lon:0. ~max_lat:1. ~max_zoom:15));
  check "a NaN is refused"
    (Result.is_error (J.validate ~min_lon:Float.nan ~min_lat:0. ~max_lon:1. ~max_lat:1. ~max_zoom:15));
  check "zoom 16 is refused"
    (Result.is_error (J.validate ~min_lon:0. ~min_lat:0. ~max_lon:1. ~max_lat:1. ~max_zoom:16));
  check "an honest box is accepted"
    (Result.is_ok (J.validate ~min_lon:(-0.25) ~min_lat:51.45 ~max_lon:0. ~max_lat:51.55 ~max_zoom:15));

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
        (fun req ->
          calls := `Start req :: !calls;
          Ok ());
      cancel =
        (fun () ->
          calls := `Cancel :: !calls;
          true);
      status =
        (fun () ->
          calls := `Status :: !calls;
          `Assoc []);
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
    ignore (S.handle_basemap scfg ops ~endpoint ~body);
    !calls
  in
  check "status asks the job and needs no body"
    (run ~endpoint:"basemap-status" ~body:"" = [ `Status ]);
  check "cancel reaches the job"
    (run ~endpoint:"basemap-cancel" ~body:"" = [ `Cancel ]);
  let box = {|{"min_lon":-0.25,"min_lat":51.45,"max_lon":0,"max_lat":51.55,"max_zoom":15}|} in
  let wrap boxes = {|{"regions":[|} ^ String.concat "," boxes ^ "]}" in
  (match run ~endpoint:"basemap-download" ~body:(wrap [ box ]) with
  | [ `Start [ (req : Tessarium_server.Basemap_job.request) ] ] ->
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
  | [ `Start [ (a : Tessarium_server.Basemap_job.request); b ] ] ->
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
  check "a missing field reaches nothing"
    (run ~endpoint:"basemap-download"
       ~body:(wrap [ {|{"min_lon":1,"min_lat":0,"max_lon":2,"max_zoom":15}|} ])
     = []);

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

  Printf.printf "\n%d checks, %d failures\n" !checks !failures;
  if !failures > 0 then exit 1 else print_endline "server decisions hold"
