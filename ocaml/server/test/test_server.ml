(* Tests for the server's pure decisions. No socket, no filesystem, no clock.

   Range parsing and path resolution are here because both fail silently. A
   wrong range hands back the wrong bytes and the map renders as garbage; a
   path that escapes the asset root serves whatever is above it. Neither
   produces an error the way a crash would. *)

module C = Tessarium_server.Http_cache
module R = Tessarium_server.Http_range
module U = Tessarium_server.Url_path
(* The proved resolver itself, so the runtime checks below can hold its
   answers to its own statement of what a safe segment is. *)
module Proved = Tessarium_UrlPath
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

  (* The trusted half of Url_path: everything else in it is extracted from
     proved F*, and these two conversions are what the proof is carried
     across. Every byte, not a sample -- the interesting ones are 0 and the
     high half, which is where Char.chr and Z.to_int would part company. *)
  let all_bytes = String.init 256 Char.chr in
  check "bytes_of_string round-trips every byte"
    (U.string_of_bytes (U.bytes_of_string all_bytes) = all_bytes);
  check "and the byte list is the code points, in order"
    (List.map Z.to_int (U.bytes_of_string "A/\000\255")
     = [ 65; 47; 0; 255 ]);

  (* The theorems, re-asserted at runtime.
     `Tessarium.UrlPath.theorem_no_escape` and `theorem_no_dotfile` say that
     every segment `resolve` accepts satisfies `opens_under_root` and
     `names_no_dotfile`. That is proved of the F*; this runs the EXTRACTED
     resolver over a product of hostile fragments and holds its answers to the
     EXTRACTED statements of the claims. It cannot re-prove either theorem --
     both sides come out of the same extraction -- but it does catch the two
     ways the proof could stop applying: the claim drifting from the code it
     is about, and this file's conversion mangling a byte on the way through.

     The fragments are in two groups on purpose. The first group is refused,
     and a corpus of only those would run the claims over an empty set: what
     it proves is that they were refused, not that the claims hold. The second
     group is the interesting one -- names that come CLOSE to the rules
     without breaking them, and encodings that decode into something
     legitimate -- so that accepted segments carry dots, decoded bytes and
     separators-turned-boundaries rather than being three literals. The check
     below reports how many distinct segments actually reached it, because
     that, not the number of targets, is what it covered. *)
  let refused =
    [ "."; ".."; "%2e"; "%2E%2E"; "%2f"; "%2F"; ".git"; ".env"; "a%00b";
      "a\\b"; "%"; "%2"; "%zz"; "..%2f.."; "....//"; "%2e%2e%2f" ]
  in
  let accepted_ish =
    [ ""; "a"; "assets"; "index.html"; "a.b"; "a."; "..a"; "a..b"; "a...";
      "%61%2e%2e"; "a%2eb"; "%252e%252e"; "a%2fb"; "%41"; "a-b_c.d";
      "index-D4ipvZ4X.js"; "%7e"; "sprite@2x.png" ]
  in
  let fragments = refused @ accepted_ish in
  let hostile =
    let one = List.map (fun a -> "/" ^ a) fragments in
    let two =
      List.concat_map
        (fun a -> List.map (fun b -> "/" ^ a ^ "/" ^ b) fragments)
        fragments
    in
    let three =
      List.concat_map
        (fun a ->
          List.concat_map
            (fun b -> List.map (fun c -> "/" ^ a ^ "/" ^ b ^ "/" ^ c) fragments)
            fragments)
        fragments
    in
    let queried = List.map (fun t -> t ^ "?v=..%2f..") one in
    let fragged = List.map (fun t -> t ^ "#..%2f..") one in
    one @ two @ three @ queried @ fragged
  in
  let escaped = ref None in
  let dotfile = ref None in
  let seen = Hashtbl.create 64 in
  List.iter
    (fun target ->
      match U.resolve target with
      | None -> ()
      | Some segs ->
          List.iter
            (fun seg ->
              Hashtbl.replace seen seg ();
              let b = U.bytes_of_string seg in
              if (not (Proved.opens_under_root b)) && !escaped = None then
                escaped := Some (target, seg);
              if (not (Proved.names_no_dotfile b)) && !dotfile = None then
                dotfile := Some (target, seg))
            segs)
    hostile;
  let distinct = Hashtbl.length seen in
  let accepted =
    List.length (List.filter (fun t -> U.resolve t <> None) hostile)
  in
  (* Printed, not only asserted. The number of targets says how hard the
     resolver was pushed; the other two say how much the CLAIMS were actually
     run over, and a corpus can grow without either of them moving. *)
  Printf.printf "  path safety: %d targets, %d accepted, %d distinct segments\n"
    (List.length hostile) accepted distinct;
  check
    (Printf.sprintf
       "every segment accepted from %d hostile targets opens under the root%s"
       (List.length hostile)
       (match !escaped with
       | None -> ""
       | Some (t, s) -> Printf.sprintf " (%S gave %S)" t s))
    (!escaped = None);
  check
    (Printf.sprintf "and none of them names a dotfile%s"
       (match !dotfile with
       | None -> ""
       | Some (t, s) -> Printf.sprintf " (%S gave %S)" t s))
    (!dotfile = None);

  (* Without accepted targets the two checks above pass over an empty set, and
     without VARIED ones they pass over three literals. Both numbers are
     asserted rather than printed, because both were once much smaller than
     the corpus size suggested. *)
  check
    (Printf.sprintf "%d targets were accepted, so the claims had something to \
                     hold" accepted)
    (accepted > 1000);
  check
    (Printf.sprintf "and they carried %d distinct segments, not a handful"
       distinct)
    (distinct >= 12);

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
  routes `GET "/tiles.json" (Route.Tile_json { floor = false });
  routes `GET "/tiles.json?v=4" (Route.Tile_json { floor = false });
  routes `POST "/tiles.json" Route.Method_not_allowed;
  (* The floor's metadata is a separate document because it describes a
     different depth over different bounds -- the same tiles, cut to what is
     everywhere rather than to what is deepest. *)
  routes `GET "/world.json" (Route.Tile_json { floor = true });
  routes `GET "/world.json?v=4" (Route.Tile_json { floor = true });
  routes `POST "/world.json" Route.Method_not_allowed;
  (* Normalised the same way /tiles.json is -- one document, not two. *)
  routes `GET "/world.json/" (Route.Tile_json { floor = true });

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
          (J.Fetching
             { done_bytes = 0; total_bytes = 9; part = 1; parts = 1; regions = [] })));
  check "no second download while assets fetch" (not (J.can_start J.Assets));
  check "progress is clamped to the total"
    (J.progress ~done_bytes:120 ~total_bytes:100 ~part:1 ~parts:1 ()
     = J.Fetching
         { done_bytes = 100; total_bytes = 100; part = 1; parts = 1; regions = [] });
  check "progress cannot be negative"
    (J.progress ~done_bytes:(-5) ~total_bytes:100 ~part:1 ~parts:1 ()
     = J.Fetching
         { done_bytes = 0; total_bytes = 100; part = 1; parts = 1; regions = [] });
  check "part is clamped into 1..parts"
    (J.progress ~done_bytes:0 ~total_bytes:1 ~part:9 ~parts:4 ()
     = J.Fetching
         { done_bytes = 0; total_bytes = 1; part = 4; parts = 4; regions = [] }
    && J.progress ~done_bytes:0 ~total_bytes:1 ~part:0 ~parts:0 ()
       = J.Fetching
           { done_bytes = 0; total_bytes = 1; part = 1; parts = 1; regions = [] });
  (* Per-region rows get the same clamping as the aggregate: the download
     credits regions from a raw counter, and a row reading past its own total
     is the same bug as a bar past 100%. *)
  check "a region's progress is clamped to its own total"
    (J.progress ~done_bytes:0 ~total_bytes:100 ~part:1 ~parts:1
       ~regions:
         [
           { J.label = "France"; done_bytes = 90; total_bytes = 40; planned = true };
           { J.label = "Tokyo"; done_bytes = -3; total_bytes = 60; planned = false };
         ]
       ()
     = J.Fetching
         {
           done_bytes = 0;
           total_bytes = 100;
           part = 1;
           parts = 1;
           regions =
             [
               { J.label = "France"; done_bytes = 40; total_bytes = 40; planned = true };
               { J.label = "Tokyo"; done_bytes = 0; total_bytes = 60; planned = false };
             ];
         });
  check "region rows survive into the status JSON in request order"
    (match
       J.to_json
         (J.progress ~done_bytes:1 ~total_bytes:2 ~part:1 ~parts:1
            ~regions:
              [
                { J.label = "France"; done_bytes = 1; total_bytes = 2; planned = true };
                { J.label = "Tokyo"; done_bytes = 0; total_bytes = 5; planned = false };
              ]
            ())
     with
    | `Assoc fields -> (
        match List.assoc_opt "regions" fields with
        | Some (`List [ `Assoc a; `Assoc b ]) ->
            List.assoc_opt "label" a = Some (`String "France")
            && List.assoc_opt "label" b = Some (`String "Tokyo")
            && List.assoc_opt "planned" b = Some (`Bool false)
        | _ -> false)
    | _ -> false);
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

  (* What a dropped connection leaves behind. Every one of these reached a
     String.sub or an int_of_string that raised, so the download job reported
     an OCaml exception rather than saying the archive was incomplete. *)
  let rejects a =
    match Tessarium_server.Untar.list a with
    | _ -> false
    | exception Failure _ -> true
  in
  let whole = tar_entry "fonts/a.pbf" (String.make 600 'g') in
  check "the archive it is cut from parses" (not (rejects whole));
  check "an entry cut short is refused"
    (rejects (String.sub whole 0 700));
  check "a header cut short is simply the end"
    (not (rejects (String.sub whole 0 300)));
  (* GNU writes sizes over 8 GB in base 256, high bit set. Nothing in a glyph
     tarball is that size, so here it is indistinguishable from garbage. *)
  let clobber at bytes =
    let b = Bytes.of_string whole in
    Bytes.blit_string bytes 0 b at (String.length bytes);
    Bytes.to_string b
  in
  check "a base-256 size field is refused" (rejects (clobber 124 "\x80\x00\x00\x00"));
  check "a size field of letters is refused" (rejects (clobber 124 "nonsense    "));
  (* A pax record whose length covers nothing, which made String.sub negative. *)
  let pax r =
    tar_entry ~typeflag:'x' "pax" r ^ tar_entry "next" "body"
    ^ String.make 1024 '\000'
  in
  check "a zero-length pax record is refused, not crashed on"
    (not (rejects (pax "0 path=x\n")));
  check "a pax length past the payload is refused, not crashed on"
    (not (rejects (pax "9999 path=x\n")));
  check "and a well-formed one still renames"
    (List.assoc_opt "renamed"
       (Tessarium_server.Untar.list (pax "16 path=renamed\n"))
     = Some "body");

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

  (* Who may call them. The server listens on loopback and asks for no
     credentials, so a page the user happens to have open can reach every
     endpoint the UI can -- and start a download, delete a map, or switch on
     the network cache. A page cannot set either header below; the browser
     does. So what is asserted here is what a browser will send, and the two
     clients that send neither -- curl and a script -- stay welcome, which is
     what --api is for. *)
  let hdr l name = List.assoc_opt name l in
  let module G = Tessarium_server.Api_guard in
  let foreign l = G.from_another_site (hdr l) in
  check "a cross-site fetch is foreign"
    (foreign [ ("sec-fetch-site", "cross-site"); ("host", "127.0.0.1:7373") ]);
  check "so is same-site -- another port is another origin"
    (foreign [ ("sec-fetch-site", "same-site") ]);
  check "our own page is not" (not (foreign [ ("sec-fetch-site", "same-origin") ]));
  check "nor is an address bar" (not (foreign [ ("sec-fetch-site", "none") ]));
  check "nor curl, which sends neither header" (not (foreign []));
  (* Browsers without Sec-Fetch-Site still send Origin on a cross-origin write. *)
  check "an origin naming another host is foreign"
    (foreign [ ("origin", "http://evil.example"); ("host", "127.0.0.1:7373") ]);
  check "an origin naming us is not"
    (not
       (foreign
          [ ("origin", "http://127.0.0.1:7373"); ("host", "127.0.0.1:7373") ]));
  check "a null origin -- a sandboxed frame, a data: URL -- is foreign"
    (foreign [ ("origin", "null"); ("host", "127.0.0.1:7373") ]);
  (* The last leg: the three body types a page can post with NO preflight.
     Requiring JSON means the browser has to ask first, and we never answer. *)
  let json l = G.is_json (hdr l) in
  (* ------------------------------------------------- accept-encoding *)
  (* Tiles and embedded assets are STORED gzipped, so this decides whether a
     client gets the stored bytes or an inflated copy. Getting it wrong in
     the generous direction hands gzip to something that said it cannot read
     it -- and the clients that spell this carefully are curl and scripts,
     the exact ones the inflating path exists for. *)
  let gz v = S.accepts_gzip (hdr [ ("accept-encoding", v) ]) in
  check "a browser's header accepts gzip" (gz "gzip, deflate, br, zstd");
  check "so does a bare gzip" (gz "gzip");
  check "and a weighted one" (gz "gzip;q=0.8, identity;q=0.5");
  check "and the wildcard" (gz "*");
  check "q=0 means it cannot read gzip" (not (gz "gzip;q=0"));
  check "however many zeroes it writes"
    (not (gz "gzip;q=0.000") && not (gz "gzip;q=0.0"));
  check "a coding that merely contains the word is not gzip"
    (not (gz "identity, notgzip"));
  check "x-gzip is the same coding" (gz "x-gzip");
  check "an empty field accepts nothing" (not (gz ""));
  check "no field at all accepts nothing" (not (S.accepts_gzip (hdr [])));
  (* Naming a coding outright is more specific than the wildcard. *)
  check "an explicit refusal beats a permissive wildcard"
    (not (gz "*, gzip;q=0"));
  check "and an explicit accept beats a refusing wildcard"
    (gz "*;q=0, gzip");

  check "text/plain is not json" (not (json [ ("content-type", "text/plain") ]));
  check "a form post is not json"
    (not (json [ ("content-type", "application/x-www-form-urlencoded") ]));
  check "a file upload is not json"
    (not (json [ ("content-type", "multipart/form-data; boundary=x") ]));
  check "and neither is nothing at all" (not (json []));
  check "json is" (json [ ("content-type", "application/json") ]);
  check "json with a charset still is"
    (json [ ("content-type", "application/json; charset=utf-8") ]);

  (* And the guard itself, which is the thing a handler cannot be reached
     without. What matters is not that these predicates are right but that
     nothing gets an Api_guard.t unless they all are. *)
  let ok = [ ("content-type", "application/json"); ("host", "127.0.0.1:7373") ] in
  let run ?(declares = true) ?(read = fun () -> Some "{}") l =
    G.check ~header:(hdr l) ~declares_body:declares ~read
  in
  let allowed o = match o with G.Allowed _ -> true | G.Refused _ -> false in
  let refused_with r o =
    match o with G.Refused (r', _) -> r' = r | G.Allowed _ -> false
  in
  let closes o =
    match o with
    | G.Refused (_, G.Connection_must_close) -> true
    | _ -> false
  in
  check "a well-formed same-origin call is allowed" (allowed (run ok));
  check "the body survives the guard"
    (match run ok ~read:(fun () -> Some {|{"a":1}|}) with
     | G.Allowed t -> String.equal (G.body t) {|{"a":1}|}
     | G.Refused _ -> false);
  check "a call declaring no body has an empty one, not a missing one"
    (match run ok ~declares:false ~read:(fun () -> assert false) with
     | G.Allowed t -> String.equal (G.body t) ""
     | G.Refused _ -> false);
  check "another site is refused"
    (refused_with G.From_another_site
       (run (("sec-fetch-site", "cross-site") :: ok)));
  check "a non-json body is refused"
    (refused_with G.Not_json (run [ ("content-type", "text/plain") ]));
  check "a body over the bound is refused"
    (refused_with G.Too_large (run ok ~read:(fun () -> None)));
  (* The half that was got wrong twice: a refusal has to clear the socket,
     and when it cannot, the connection has to end. *)
  check "a refusal drains a body it can"
    (not (closes (run (("sec-fetch-site", "cross-site") :: ok))));
  check "and closes the connection when it cannot"
    (closes (run (("sec-fetch-site", "cross-site") :: ok) ~read:(fun () -> None)));
  check "the size refusal always closes"
    (closes (run ok ~read:(fun () -> None)));
  (* Read at most once, whatever the answer: reading twice on one flow would
     block on a socket that has nothing more to give. *)
  check "the body is read exactly once"
    (let reads = ref 0 in
     let read () = incr reads; Some "{}" in
     ignore (run ok ~read);
     ignore (run [ ("content-type", "text/plain") ] ~read);
     !reads = 2);

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
        (fun ~world req ->
          calls := `Estimate (world, req) :: !calls;
          Ok (`Assoc []));
      start =
        (fun ~name ~labels ~world req ->
          calls := `Start (name, labels, world, req) :: !calls;
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
      export =
        (fun ~id ->
          calls := `Export id :: !calls;
          Ok ());
      exports =
        (fun () ->
          calls := `Exports :: !calls;
          `List []);
      delete_export =
        (fun ~file ->
          calls := `Delete_export file :: !calls;
          Ok ());
      staged =
        (fun () ->
          calls := `Staged :: !calls;
          `Assoc [ ("staged", `Bool false) ]);
      import =
        (fun () ->
          calls := `Import :: !calls;
          Ok ());
      discard_import =
        (fun () ->
          calls := `Discard_import :: !calls;
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

  (* The handlers demand a request that has passed the guard, and this is the
     only way to make one -- the tests go through it exactly as the server
     does. *)
  let checked body =
    match
      G.check
        ~header:(function
          | "content-type" -> Some "application/json"
          | _ -> None)
        ~declares_body:true
        ~read:(fun () -> Some body)
    with
    | G.Allowed t -> t
    | G.Refused _ -> failwith "the test's own request did not pass the guard"
  in
  let run ~endpoint ~body =
    calls := [];
    ignore (S.handle_basemap scfg ops settings ~endpoint ~request:(checked body));
    !calls
  in

  check "status asks the job and needs no body"
    (run ~endpoint:"basemap-status" ~body:"" = [ `Status ]);
  check "cancel reaches the job"
    (run ~endpoint:"basemap-cancel" ~body:"" = [ `Cancel ]);
  let box = {|{"min_lon":-0.25,"min_lat":51.45,"max_lon":0,"max_lat":51.55,"max_zoom":15}|} in
  let wrap boxes = {|{"regions":[|} ^ String.concat "," boxes ^ "]}" in
  (match run ~endpoint:"basemap-download" ~body:(wrap [ box ]) with
  | [ `Start (_, _, _, [ (req : Tessarium_server.Basemap_job.request) ]) ] ->
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
  | [ `Start (_, _, _, [ (a : Tessarium_server.Basemap_job.request); b ]) ] ->
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
  | [ `Start (_, _, _, [ (req : Tessarium_server.Basemap_job.request) ]) ] ->
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
      (* The status travels with the response now, so this asks for it
         rather than inferring a 429 from the body being longer than a 404 --
         which is what it had to do while the status was a literal chosen by
         the caller three frames away. *)
      let status_of endpoint body =
        let _, status, _ =
          S.handle_api scfg sessions limiter random ~endpoint
            ~request:(checked body) ~now:1000.
        in
        status
      in
      let body = {|{"session":"nope","lat_ns":"1","lon_ns":"1"}|} in
      check "an unthrottled call answers for itself"
        (status_of "encode" body <> `Too_many_requests);
      let rec drain n last =
        if n = 0 then last else drain (n - 1) (status_of "encode" body)
      in
      check "encode shares the key api's rate ceiling"
        (drain 10 `OK = `Too_many_requests);
      check "decode shares it too"
        (status_of "decode" {|{"session":"nope","address":"a.b.c.1"}|}
        = `Too_many_requests));
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
    | [ `Start (Some "France", _, false, _) ] -> true
    | _ -> false);
  check "a download without a name still starts"
    (match run ~endpoint:"basemap-download" ~body:(wrap [ box ]) with
    | [ `Start (None, _, false, _) ] -> true
    | _ -> false);
  check "a name with control characters reaches nothing"
    (run ~endpoint:"basemap-download"
       ~body:({|{"name":"a\nb","regions":[|} ^ box ^ "]}")
     = []);
  (* Which archive a download joins is the client's to say and the server's
     to check: the overview is a separate file, and asking for one has to be
     distinguishable from asking for a region that happens to be large. *)
  check "a download says which archive it is for"
    (match
       run ~endpoint:"basemap-download"
         ~body:({|{"world":true,"regions":[|} ^ box ^ "]}")
     with
    | [ `Start (_, _, true, _) ] -> true
    | _ -> false);
  (* And its estimate is quoted against the same one. A quote taken against
     the detail archive would price a world overview the user mostly has. *)
  check "an estimate is asked for the same archive the download joins"
    (match
       run ~endpoint:"basemap-estimate"
         ~body:({|{"world":true,"regions":[|} ^ box ^ "]}")
     with
    | [ `Estimate (true, _) ] -> true
    | _ -> false);
  (* Per-region labels. They exist so the progress view can name its bars,
     which means a labels array that does not line up with the regions is
     worse than none: every bar would carry its neighbour's name. Refused,
     not trimmed. *)
  check "labels ride along with the regions they name"
    (match
       run ~endpoint:"basemap-download"
         ~body:({|{"labels":["France"],"regions":[|} ^ box ^ "]}")
     with
    | [ `Start (_, Some [ "France" ], false, _) ] -> true
    | _ -> false);
  check "a download without labels still starts"
    (match run ~endpoint:"basemap-download" ~body:(wrap [ box ]) with
    | [ `Start (_, None, false, _) ] -> true
    | _ -> false);
  check "labels that do not match the regions reach nothing"
    (run ~endpoint:"basemap-download"
       ~body:({|{"labels":["France","Spain"],"regions":[|} ^ box ^ "]}")
     = []
    && run ~endpoint:"basemap-download"
         ~body:({|{"labels":[7],"regions":[|} ^ box ^ "]}")
       = []
    && run ~endpoint:"basemap-download"
         ~body:({|{"labels":"France","regions":[|} ^ box ^ "]}")
       = []);
  check "a label with control characters reaches nothing"
    (run ~endpoint:"basemap-download"
       ~body:({|{"labels":["a\nb"],"regions":[|} ^ box ^ "]}")
     = []);

  (* Carrying maps by hand. Export names its entry the same way remove does;
     an export file name is checked downstream against the directory, so what
     matters here is that a request without one reaches nothing. *)
  check "export names its entry by id"
    (run ~endpoint:"basemap-export" ~body:{|{"id":"abc123"}|}
    = [ `Export "abc123" ]);
  check "an export without a usable id reaches nothing"
    (run ~endpoint:"basemap-export" ~body:"{}" = []
    && run ~endpoint:"basemap-export" ~body:{|{"id":""}|} = []);
  check "the export list needs no arguments"
    (run ~endpoint:"basemap-exports" ~body:"{}" = [ `Exports ]);
  check "deleting an export names the file"
    (run ~endpoint:"basemap-export-delete" ~body:{|{"file":"France-ab12.pmtiles"}|}
    = [ `Delete_export "France-ab12.pmtiles" ]);
  check "deleting an export without a name reaches nothing"
    (run ~endpoint:"basemap-export-delete" ~body:"{}" = []
    && run ~endpoint:"basemap-export-delete" ~body:{|{"file":42}|} = []);
  check "the staged import is asked for plainly"
    (run ~endpoint:"basemap-staged" ~body:"{}" = [ `Staged ]);
  check "committing and discarding an import take no arguments"
    (run ~endpoint:"basemap-import" ~body:"{}" = [ `Import ]
    && run ~endpoint:"basemap-import-discard" ~body:"{}" = [ `Discard_import ]);

  check "and is a region download unless it says otherwise"
    (match
       run ~endpoint:"basemap-download"
         ~body:({|{"world":"yes","regions":[|} ^ box ^ "]}")
     with
    | [ `Start (_, _, false, _) ] -> true
    | _ -> false);

  (* And what the server does with that claim. A box that does not reach the
     edges is a region however large it is: writing it to world.pmtiles
     would leave a partial planet in the file every later reader takes for
     the whole one. *)
  let region ~min_lon ~min_lat ~max_lon ~max_lat =
    match
      Tessarium_server.Basemap_job.validate ~min_lon ~min_lat ~max_lon ~max_lat
        ~max_zoom:6 ()
    with
    | Ok r -> r
    | Error e -> failwith e
  in
  let whole = region ~min_lon:(-180.) ~min_lat:(-85.) ~max_lon:180. ~max_lat:85. in
  check "the whole planet is a world overview"
    (D.covers_the_planet [ whole ]);
  check "a box short of the edges is not, however large"
    (not
       (D.covers_the_planet
          [ region ~min_lon:(-179.9) ~min_lat:(-84.) ~max_lon:179.9 ~max_lat:84. ]));
  check "and neither are two halves that between them would cover it"
    (not
       (D.covers_the_planet
          [
            region ~min_lon:(-180.) ~min_lat:(-85.) ~max_lon:0. ~max_lat:85.;
            region ~min_lon:0. ~min_lat:(-85.) ~max_lon:180. ~max_lat:85.;
          ]));

  (* Settings: an empty body reads, a value writes, junk reaches nothing. *)
  let run_settings ~body =
    settings_calls := [];
    ignore
      (S.handle_basemap scfg ops settings ~endpoint:"basemap-settings"
         ~request:(checked body));
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

  (* [outside] is what an export prunes with, and it has to be the EXACT
     complement of the entry's own covering. Too eager and the file arrives
     on the other machine with holes in the middle of the country; too shy
     and it carries tiles belonging to regions the user did not export. With
     [kept] empty, [drops] is precisely "this tile is in the entry", so the
     two must disagree on every tile in the universe and agree on none. *)
  let complements ?polygon ~z:max_zoom (a, b, c, d) =
    let e = entry [ reg ?polygon ~z:max_zoom (a, b, c, d) ] in
    let drops = L.drops ~removed:e ~kept:[] in
    let outside = L.outside ~entry:e in
    universe (fun ~z ~x ~y -> outside ~z ~x ~y = not (drops ~z ~x ~y))
  in
  check "outside is exactly the complement of what an entry covers"
    (complements ~z:4 (-5.1, 41.3, 9.6, 51.1));
  check "outside complements a polygon-clipped entry too"
    (complements ~polygon:quad ~z:4
       (tl -. pad, tb -. pad, tr +. pad, tt +. pad));

  (* Export file names. The string reaches a filesystem, a URL path and a
     save dialog, so it is deliberately narrow -- and the real name is not
     lost by that, it rides inside the file's own ledger. *)
  let module D = Tessarium_server.Basemap_download in
  let fname ?name id =
    D.export_filename
      ~entry:(entry ?name [ france ])
      ~id
  in
  check "an ordinary name slugs to itself"
    (fname "abcdef0123456789" = "France-abcdef01.pmtiles");
  check "spaces and punctuation collapse to single dashes"
    (fname ~name:"Cote d'Ivoire (north)" "abcdef0123456789"
    = "Cote-d-Ivoire-north-abcdef01.pmtiles");
  check "a name with nothing safe in it falls back rather than emptying"
    (fname ~name:"東京" "abcdef0123456789" = "map-abcdef01.pmtiles");
  check "the same entry exports to the same file, so a repeat replaces"
    (fname "abcdef0123456789" = fname "abcdef0123456789");
  check "different entries do not collide on a shared name"
    (fname "aaaaaaaa1111" <> fname "bbbbbbbb2222");
  check "a short id is used whole rather than read past its end"
    (fname "abc" = "France-abc.pmtiles");

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

  (* A record written under a name this version does not use. Reading it as
     "no downloads" is the destructive answer: the next download rewrites the
     archive with a ledger naming only itself, and the removal after that
     prunes every tile the forgotten regions were holding. *)
  let older = {|{"name":"a map","someoneelse_ledger":{"v":1,"entries":[]}}|} in
  check "a ledger under another name is refused on read"
    (unreadable (L.of_metadata older));
  check "a ledger under another name is refused on write"
    (unreadable (L.to_metadata [ e1 ] ~previous:older));
  (* And the two cases it must not swallow. *)
  check "an archive with no ledger at all still reads as empty"
    (L.of_metadata {|{"name":"a map"}|} = Ok []);
  check "a key that merely contains the word is not a ledger"
    (L.of_metadata {|{"ledger_notes":"hi"}|} = Ok []);

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

  (* Progress has to be able to ARRIVE. A run is one blob shared by
     consecutive tile ids, and an empty ocean tile is byte-identical either
     side of a zoom boundary, so one run can span it. Counting the whole run
     whenever its FIRST id is in range then counts ids the walk skips, and
     what the UI is shown stops short of its own total and stays there.

     Ids 20..23 are the last tile of zoom 2 and the first three of zoom 3, so
     at max_zoom 2 the walk visits exactly one of the four. *)
  let run_archive ?(reads = ref 0) ~tile_id ~run_length () =
    let module H = Pmtiles.Header in
    let module D = Pmtiles.Directory in
    let payload = "not-a-tile" in
    let root =
      D.serialize
        [| { D.tile_id = tile_id; offset = 0;
             length = String.length payload; run_length } |]
    in
    let header =
      {
        H.root_offset = H.size;
        root_length = String.length root;
        metadata_offset = H.size + String.length root;
        metadata_length = 0;
        leaf_offset = H.size + String.length root;
        leaf_length = 0;
        data_offset = H.size + String.length root;
        data_length = String.length payload;
        addressed_tiles = 4;
        tile_entries = 1;
        tile_contents = 1;
        clustered = true;
        internal_compression = H.None_;
        tile_compression = H.None_;
        tile_type = H.Mvt;
        min_zoom = 2;
        max_zoom = 3;
        min_lon_e7 = -1800000000;
        min_lat_e7 = -850000000;
        max_lon_e7 = 1800000000;
        max_lat_e7 = 850000000;
        center_zoom = 2;
        center_lon_e7 = 0;
        center_lat_e7 = 0;
      }
    in
    let bytes = H.serialize header ^ root ^ payload in
    Pmtiles.Archive.open_
      {
        Pmtiles.Archive.read =
          (fun ~offset ~length ->
            incr reads;
            String.sub bytes offset (min length (String.length bytes - offset)));
      }
  in
  let seen_progress = ref (0, 0) in
  ignore
    (P.build ~max_zoom:2
       ~on_tile:(fun done_ total -> seen_progress := (done_, total))
       (run_archive ~tile_id:20 ~run_length:4 ()));
  check "a run spanning the zoom edge does not leave the total unreachable"
    (fst !seen_progress = snd !seen_progress && fst !seen_progress = 1);

  (* And the blob behind a run is read ONCE. Ids 21..24 are all zoom 3, so
     the walk visits four of them; fetching per id re-ran the directory
     search, the source read and the inflate for each, on bytes that cannot
     differ. Only the reprojection varies with the id. Counted at the source,
     because that is where the cost is. *)
  let reads = ref 0 in
  let archive = run_archive ~reads ~tile_id:21 ~run_length:4 () in
  let visited = ref 0 in
  reads := 0;
  ignore (P.build ~max_zoom:3 ~on_tile:(fun d _ -> visited := d) archive);
  check "the walk visited every id in the run" (!visited = 4);
  check "and read the run's blob once, not once per id" (!reads = 1);

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

  (* The rank leaves the server with the row.

     The browser re-orders these on evidence this index does not have and
     never will -- which country and which state the point falls in, out of
     the border data the download picker already ships. It can only refine
     a ranking it can see: without the number it would have to guess where
     the boundaries between equally good answers fall, and "Jasper, GA"
     would answer with Jasper County Landfill for being in Georgia. *)
  check "how well the name was answered beats how big the place is"
    (P.compare_hit { P.entry = big; score = 5 } { P.entry = small; score = 4 }
    > 0);
  check "and settles by population only within one rank"
    (P.compare_hit { P.entry = big; score = 4 } { P.entry = small; score = 4 }
    < 0);
  (match P.to_json [ { P.entry = big; score = 42 } ] with
  | `Assoc [ ("results", `List [ `Assoc fields ]) ] ->
      check "the rank is published with the row"
        (List.assoc_opt "score" fields = Some (`Int 42))
  | _ -> check "the rank is published with the row" false);

  (* One town, sighted twice.

     The same label is drawn in every tile that touches it and at every
     zoom above it, and those repeats collapse by name, layer and position.
     Position was a grid square alone, so whether two sightings collapsed
     depended on where the lines fell: Jasper, Alberta sits twenty metres
     from one, and the real index carried it TWICE -- two of the eight rows
     a search for "Jasper" had to spend. *)
  let seen = Hashtbl.create 8 in
  let key lon lat =
    P.cluster_key seen ~folded:"jasper" ~layer:"places" ~lon ~lat
  in
  let file lon lat =
    let k = key lon lat in
    Hashtbl.replace seen k
      (12, { P.name = "Jasper"; kind = "town"; layer = "places";
             weight = 4590.; lon; lat });
    k
  in
  (* The real pair, either side of a twentieth-degree line. *)
  let alberta = file (-118.082428) 52.874932 in
  check "one town sighted twice across a grid line is one row"
    (key (-118.082428) 52.875139 = alberta);
  check "and a different town of the same name is not"
    (key (-84.429095) 34.467876 <> alberta);
  (* A cluster is joined wherever it was first filed, so the fix cannot
     depend on which of the two sightings arrived first. *)
  let seen2 = Hashtbl.create 8 in
  let key2 lon lat =
    P.cluster_key seen2 ~folded:"jasper" ~layer:"places" ~lon ~lat
  in
  let first2 = key2 (-118.082428) 52.875139 in
  Hashtbl.replace seen2 first2
    (12, { P.name = "Jasper"; kind = "town"; layer = "places";
           weight = 4590.; lon = -118.082428; lat = 52.875139 });
  check "whichever of the two arrives first"
    (key2 (-118.082428) 52.874932 = first2);
  (* Layer is still part of the identity: a road named after the town it
     runs through is a different row, at the same point. *)
  check "and a road of the same name at the same point stays separate"
    (P.cluster_key seen ~folded:"jasper" ~layer:"roads" ~lon:(-118.082428)
       ~lat:52.874932
    <> alberta);

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

  (* ------------------------------------------- addresses vs place names

     One search box takes both, and the classifier decides which one was
     typed BEFORE anything is sent. Getting it wrong in the "place" direction
     puts a user's address in a request to the place index -- so these cases
     are about the boundary, not about happy paths.

     Pinned in OCaml because the rule belongs to the address format, which
     lives here; the browser reaches it through a js_of_ocaml export rather
     than through a second parser of its own. *)
  let shape s = Tessarium.address_shape_string s in
  List.iter
    (fun (input, want) ->
      check
        (Printf.sprintf "address_shape %S is %s (got %s)" input want
           (shape input))
        (String.equal (shape input) want))
    [
      (* the format, in every spelling address_of_string accepts *)
      ("dream.tourist.creek.2703", "complete");
      ("dream tourist creek 2703", "complete");
      ("DREAM.TOURIST.CREEK.2703", "complete");
      ("dream-tourist-creek-2703", "complete");
      ("drea tour cree 2703", "complete");
      ("  dream.tourist.creek.2703  ", "complete");
      (* not BIP-39 words, and still an address attempt: answering this with a
         place is the bug the classifier exists to prevent *)
      ("paper.later.curve.0851", "complete");
      ("zzzz.yyyy.xxxx.0000", "complete");
      (* on the way to being one -- nothing may be sent *)
      ("dream.tourist.creek", "partial");
      ("dream.tourist.creek.27", "partial");
      ("dream.tourist.", "partial");
      (* the first third, which the first version of this rule sent to the
         index because it counted parts rather than punctuation *)
      ("dream.", "partial");
      ("dream.tourist", "partial");
      (* Trailing whitespace must not turn a trailing dot into an
         abbreviation. It did: the scan walked the TRIMMED string while
         measuring the untrimmed one, so the last index never matched and
         "dream. " was read as "dream" plus a space -- a word of someone's
         address, sent to the place index. *)
      ("dream. ", "partial");
      ("dream.  ", "partial");
      ("dream.tourist. ", "partial");
      (".", "partial");
      (* Every separator address_of_string accepts, mid-typing. An earlier
         rule looked only at the dot, so all five of the others sent three
         words and three of four digits to the place index. *)
      ("vacuum penalty health", "partial");
      ("vacuum penalty health 347", "partial");
      ("vacuum-penalty-health-347", "partial");
      ("vacuum_penalty_health_347", "partial");
      ("vacuum,penalty,health,347", "partial");
      ("vacuum/penalty/health/347", "partial");
      ("vacuum.penalty.health.347", "partial");
      (* two words is enough to say it is not a place *)
      ("vacuum penalty", "partial");
      ("dream tourist", "partial");
      (* and the word being typed counts once only one word can finish it *)
      ("vacuum pena", "partial");
      (* place names, which must still be searched *)
      ("atlanta", "no");
      ("new york city", "no");
      (* a dot followed by a space is an abbreviation, not a separator *)
      ("st. louis", "no");
      ("mt. fuji", "no");
      ("st. louis ", "no");
      ("Fixtureville, ZZ", "no");
      ("fixture ville", "no");
      ("", "no");
      (* four space-separated parts ending in a short number is a place, not a
         half-typed address: "highway 4 exit 12" must reach the index *)
      ("highway 4 exit 12", "no");
      (* One BIP-39 word does not make a place an address: "city", "upon" and
         "orange" are all in the wordlist. The match is exact rather than by
         four-letter prefix, or "county" resolving to "country" would take
         "orange county" off the index. *)
      ("Stratford-upon-Avon", "no");
      ("orange county", "no");
      ("orange", "no");
      ("Baden-Baden", "no");
      ("los angeles", "no");
    ];
  (* And the direction the bias runs: a place name shaped exactly like an
     address is read as an address and refused, rather than searched. Stated
     as a check so the tradeoff is recorded rather than discovered. *)
  check "a place name shaped like an address is treated as one"
    (String.equal (shape "route 66 exit 1234") "complete");

  (* What an abbreviation IS. The prefix rule exists so "slic" can stand for
     "slice"; it must not also make a word the user typed stand for a
     different one. Comparing only the first four letters of the INPUT does
     exactly that, and the result is the worst answer this program can give:
     a valid-looking address for a square nobody asked about, with no error.
     "cannot" is not a BIP-39 word; "cannon" is, and they share four letters. *)
  let parsed s =
    match Tessarium.address_of_string s with
    | a -> Some a
    | exception Tessarium.Invalid_address _ -> None
  in
  check "a four-letter abbreviation resolves to its word"
    (parsed "slic.pena.abando.0001" <> None
     && parsed "slic.pena.abando.0001" = parsed "slice.penalty.abandon.0001");
  check "a non-word sharing four letters with a word is refused"
    (parsed "cannot.slice.artist.0001" = None);
  check "a word extended past its end is refused"
    (parsed "artistic.slice.cannon.0001" = None);

  (* ------------------------------------------- conditional requests

     Every response is `no-cache`, which means "ask before reusing", and until
     these tags existed there was nothing to ask about, so asking cost the
     whole body. The two mistakes available here both fail silently: a tag
     that never matches costs what it was meant to save, and a tag that
     matches when it should not serves a stale body forever. *)
  let tag ?encoding b = C.of_bytes ~encoding b in
  let fresh ?(hdr = "") etag =
    C.is_fresh ~if_none_match:(if hdr = "" then None else Some hdr) ~etag
  in
  check "a tag is quoted, or a browser will not echo it back"
    (let t = tag "hello" in
     String.length t > 2 && t.[0] = '"' && t.[String.length t - 1] = '"');
  check "the same bytes get the same tag"
    (String.equal (tag "hello") (tag "hello"));
  check "different bytes get different tags"
    (not (String.equal (tag "hello") (tag "hellp")));
  (* The one that would corrupt a page rather than slow it down: gzip and
     identity are two representations, and telling a client holding one that
     its copy of the other is current hands it gzip to parse as UTF-8. *)
  check "an encoding is part of the tag"
    (not (String.equal (tag "hello") (tag ~encoding:"gzip" "hello")));
  check "and two encodings of the same bytes still differ"
    (not
       (String.equal
          (tag ~encoding:"br" "hello")
          (tag ~encoding:"gzip" "hello")));
  let stamp ?(key = "a/b.pbf") ?(size = 10) ?(mtime = 1.0) () =
    C.of_stamp ~key ~size ~mtime
  in
  check "a stamp changes when the file grows"
    (not (String.equal (stamp ()) (stamp ~size:11 ())));
  check "a stamp changes when the file is rewritten within the same second"
    (not (String.equal (stamp ~mtime:1.25 ()) (stamp ~mtime:1.5 ())));
  (* Two files written in one instant at one length are still two files. The
     glyph directory is where this happens: a tarball extracted in one go,
     several of them empty. *)
  check "two files with the same size and time still differ"
    (not (String.equal (stamp ~key:"fonts/a/0-255.pbf" ())
            (stamp ~key:"fonts/b/0-255.pbf" ())));
  check "no header, nothing to be fresh against" (not (fresh (tag "x")));
  check "the tag it holds" (fresh ~hdr:(tag "x") (tag "x"));
  check "a tag for something else" (not (fresh ~hdr:(tag "y") (tag "x")));
  check "* matches whatever we have" (fresh ~hdr:"*" (tag "x"));
  check "one of a list"
    (fresh ~hdr:(Printf.sprintf "%s, %s, %s" (tag "a") (tag "x") (tag "b"))
       (tag "x"));
  check "none of a list"
    (not (fresh ~hdr:(Printf.sprintf "%s, %s" (tag "a") (tag "b")) (tag "x")));
  (* Weak comparison is what If-None-Match specifies: a cache that downgraded
     the tag on the way in still holds the same entry. *)
  check "a weak echo of our tag is still our tag"
    (fresh ~hdr:("W/" ^ tag "x") (tag "x"));
  check "whitespace around the entries"
    (fresh ~hdr:(Printf.sprintf "  %s ,  %s  " (tag "a") (tag "x")) (tag "x"));
  (* A comma is legal inside a quoted entity-tag. Ours never contain one, but
     a client echoing a tag from elsewhere can, and splitting on the character
     would tear it into two tags that match nothing -- or, worse, into a
     prefix that matches something. *)
  check "a comma inside a tag is not a separator"
    (fresh ~hdr:"\"a,b\"" "\"a,b\"");
  check "and does not make its halves match"
    (not (fresh ~hdr:"\"a,b\"" "\"a\""));
  check "an unparseable header matches nothing"
    (not (fresh ~hdr:"not a tag" (tag "x")));

  (* [If-Range] guards a Range against the bytes having moved, and compares
     STRONGLY -- map.pmtiles is rewritten in place, so a window handed to a
     client holding a partial copy of the old archive would splice two
     archives together. *)
  let current ?hdr etag =
    C.range_is_current ~if_range:hdr ~etag
  in
  check "no If-Range, the range stands" (current (tag "x"));
  check "an If-Range naming what we have" (current ~hdr:(tag "x") (tag "x"));
  check "an If-Range naming something else"
    (not (current ~hdr:(tag "y") (tag "x")));
  (* A weak tag says the bytes may have moved without the tag changing, which
     is exactly the admission a partial response cannot survive. *)
  check "a weak If-Range never stands"
    (not (current ~hdr:("W/" ^ tag "x") (tag "x")));
  (* An HTTP-date is a validator this server never issues. *)
  check "an If-Range date never stands"
    (not (current ~hdr:"Wed, 21 Oct 2026 07:28:00 GMT" (tag "x")));

  Printf.printf "\n%d checks, %d failures\n" !checks !failures;
  if !failures > 0 then exit 1 else print_endline "server decisions hold"
