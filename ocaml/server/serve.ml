(* The effectful edge: sockets, files, clocks and the session cache.

   Every decision this module makes has already been made by a pure function --
   [Route.of_request], [Http_range.parse], [Url_path.content_type]. What is
   left here is genuinely unavoidable IO, which is the only reason it is
   written in this style.

   Large files are streamed rather than read. A planet-scale PMTiles basemap is
   ~100 GB and is served entirely through range requests; loading a response
   body into memory would work for every asset in the UI build and then fall
   over on the one file that matters. *)

module Write = Eio.Buf_write

type config = {
  ui_dir : string;
  basemap_dir : string;
  api_enabled : bool;
  connect_src : string list;
      (** extra origins the page may talk to, beyond itself *)
  basemap_source : string;
      (** where the in-app downloader reads tiles: URL or local path.
          Configuration, never client input. *)
  basemap_assets : string;  (** the glyph+sprite tarball, likewise *)
  tile_budget : Basemap_download.budget;
      (** how much planning one download may cost; tests shrink it to force
          multi-part downloads against a tiny fixture *)
}

(* ------------------------------------------------------------- responses *)

(* A seed phrase is typed into this page. The CSP is what stops a compromised
   dependency from posting it somewhere -- with connect-src at 'self' there is
   nowhere to post it to. That is worth more here than in a typical app, so the
   default admits no remote origin at all and widening it takes a flag.

   blob: appears in worker-src because MapLibre GL builds its tile workers that
   way, and in img-src because it decodes glyph and sprite images through
   blobs. *)
let content_security_policy cfg =
  let connect = String.concat " " ("'self'" :: cfg.connect_src) in
  String.concat "; "
    [
      "default-src 'self'";
      (* 'wasm-unsafe-eval' admits WebAssembly.compile and nothing else --
         scripts stay 'self'-only. Both of the worker's wasm modules need it:
         the Argon2id KDF and, since the browser half of the switch, the map
         core that computes every address the UI shows. *)
      "script-src 'self' 'wasm-unsafe-eval'";
      "style-src 'self' 'unsafe-inline'";
      "img-src 'self' data: blob:";
      "worker-src 'self' blob:";
      "connect-src " ^ connect;
      "font-src 'self'";
      "object-src 'none'";
      "base-uri 'none'";
      "frame-ancestors 'none'";
      "form-action 'none'";
    ]

let security_headers cfg =
  [
    ("content-security-policy", content_security_policy cfg);
    ("x-content-type-options", "nosniff");
    ("referrer-policy", "no-referrer");
    (* The phrase must not survive a reload or reach a shared cache. *)
    ("cross-origin-opener-policy", "same-origin");
    ("cross-origin-resource-policy", "same-origin");
  ]

(* Paired with its length so the access log reports what was actually sent. A
   byte count that is always zero is worse than no byte count. *)
let respond_string ?etag cfg ~status ~content_type body =
  let validator =
    match etag with None -> [] | Some t -> [ ("etag", t) ]
  in
  let headers =
    Http.Header.of_list
      (("content-type", content_type)
      :: ("content-length", string_of_int (String.length body))
      :: (validator @ security_headers cfg))
  in
  ( `Response
      (Cohttp_eio.Server.respond ~headers ~status
         ~body:(Cohttp_eio.Body.of_string body) ()),
    String.length body )

let respond_json ?etag cfg ~status json =
  respond_string ?etag cfg ~status
    ~content_type:"application/json; charset=utf-8" (Yojson.Safe.to_string json)

let error cfg ~status message =
  respond_json cfg ~status (`Assoc [ ("error", `String message) ])

(* "You already have this." A 304 carries the validator and the freshness rule
   that produced it, and no body -- and so no content-length, because there is
   no representation here to describe. `Expert` for the same reason the 204
   below is: cohttp's string-body path would frame it as one. *)
let not_modified cfg ~etag ~cache_control ~vary =
  let headers =
    Http.Header.of_list
      (("etag", etag)
      :: ("cache-control", cache_control)
      :: (vary @ security_headers cfg))
  in
  let response = Http.Response.make ~status:`Not_modified ~headers () in
  (`Expert (response, fun _ic _oc -> ()), `Not_modified, 0, Http_range.Whole)

(* Repeated field lines are the comma-joined list (RFC 9110 5.3), and an
   intermediary is free to split one into several. [Http.Header.get] hands
   back only the last, so a client whose tag arrived first would be told to
   download what it already has. *)
let joined headers name =
  match Http.Header.get_multi headers name with
  | [] -> None
  | vs -> Some (String.concat ", " vs)

(* Used by tiles and embedded assets alike: gzip is served as-is to a client
   that accepts it and inflated for one that does not -- browsers all accept
   it, and the exceptions are curl and scripts, which should still work. *)
let accepts_gzip headers =
  match Http.Header.get headers "accept-encoding" with
  | None -> false
  | Some v ->
      let v = String.lowercase_ascii v in
      let rec contains i =
        i + 4 <= String.length v
        && (String.sub v i 4 = "gzip" || contains (i + 1))
      in
      contains 0

(* [Eio.Path.kind] answers [`Not_found] for a path that is simply absent, and
   RAISES for one the filesystem refuses to look at: a segment over NAME_MAX
   gives ENAMETOOLONG, a directory with no execute bit gives EACCES, a symlink
   loop gives ELOOP. Unhandled, that travels up as a connection error -- one
   unauthenticated request ended the connection instead of being answered.

   To the client they all mean the same thing and get the same answer: there is
   nothing here to send, and which kind of nothing is not a stranger's business.
   Not to the operator. A plain absence returns [`Not_found] without raising and
   stays silent; everything reaching the handler below is abnormal and says so,
   because "every asset went 404 at once" is what running out of file
   descriptors looks like from outside, and the fix that made this function
   necessary would otherwise have made that indistinguishable from a missing
   file.

   Through [Access_log.printable] because the exception text carries the path,
   and the path came from the request. *)
let path_kind ~what path =
  try Eio.Path.kind ~follow:true path
  with Eio.Io _ as e ->
    Logs.warn (fun m ->
        m "%s: not readable: %s" what
          (Access_log.printable (Printexc.to_string e)));
    `Not_found

(* ------------------------------------------------------------------ tiles *)

(* One tile archive by name. Opened per request and closed with it: the root
   directory is capped at 16 KB by the format, so this is a header and a
   handful of small reads against the page cache, and a rename cannot tear an
   open handle -- the fd pins whichever inode it opened. *)
let open_tile_archive ~basemap_root ~sw name =
  let path = Eio.Path.(basemap_root / name) in
  match path_kind ~what:("tile archive " ^ name) path with
  | `Regular_file -> (
      match
        Pmtiles.Archive.open_
          (Pmtiles_source.file_source (Eio.Path.open_in ~sw path))
      with
      | archive -> Some archive
      | exception e ->
          Logs.warn (fun m ->
              m "tile archive %s: unreadable: %s" name (Printexc.to_string e));
          None)
  | _ -> None

let open_tile_archives ~basemap_root ~sw names =
  List.filter_map
    (fun name ->
      Option.map (fun a -> (name, a)) (open_tile_archive ~basemap_root ~sw name))
    names

(* One TileJSON document. [query] is the style's ?v= cache-buster, threaded
   into the tile URLs so a swap changes them. *)
let tilejson_body cfg ~host ~query ~if_none_match ~min_zoom ~max_zoom ~bounds =
  let body =
    `Assoc
      [
        ("tilejson", `String "3.0.0");
        (* Absolute, as the TileJSON spec requires -- MapLibre substitutes
           tile URLs inside a blob-URL worker, where a relative one has no
           base to resolve against. The host is the client's own Host
           header; this server is loopback-only plain HTTP. *)
        ( "tiles",
          `List [ `String ("http://" ^ host ^ "/tiles/{z}/{x}/{y}.mvt" ^ query) ]
        );
        ("minzoom", `Int min_zoom);
        ("maxzoom", `Int max_zoom);
        ("bounds", `List (List.map (fun v -> `Float v) bounds));
      ]
  in
  (* Small, but these are the two GETs a session makes that would otherwise
     carry no validator, and "everything is revalidated" is a claim worth
     being true. Tagged over the rendered body: it restates the archive
     headers, so it changes exactly when a download changes them. *)
  let rendered = Yojson.Safe.to_string body in
  let etag = Http_cache.of_bytes ~encoding:None rendered in
  if Http_cache.is_fresh ~if_none_match ~etag then `Not_modified etag
  else `Body (respond_json ~etag cfg ~status:`OK body)

let whole_planet = [ -180.; -85.; 180.; 85. ]

(* The source metadata the pmtiles protocol used to hand MapLibre from the
   archive header, restated as TileJSON. The zoom range is load-bearing:
   MapLibre pins canonical tile requests at the source's maxzoom and
   overzooms past it, so a hardcoded 15 over a world-at-z6 archive asked for
   z15 tiles nobody holds and rendered blank at street zoom -- over data the
   archive had. The bounds keep it from asking about the rest of the planet
   at all.

   Two sources are described from here, over the same tile endpoint and the
   same archives, and between them they partition the pyramid.

   [`Floor] is the map underneath, and its one job is to have no holes -- a
   hole draws as an empty tile, an empty tile counts as data, and data
   replaces the coarse tile already on screen. So its depth is measured, not
   declared: the deepest zoom the archives cover the whole planet at. Bounds
   are the whole planet, because that is what "complete to this depth"
   means. Past that depth MapLibre overzooms rather than asking, and an
   overzoomed tile cannot be missing.

   [`Detail] is what was downloaded: deep, and full of holes, because the
   downloader takes any region to any depth into one archive. Its bounds are
   the union of what is held, so the map does not ask about a planet nobody
   fetched, and it starts one zoom below where the floor stops rather than
   at zero -- the shallow end is the floor's to draw, out of the very same
   tiles. *)
let serve_tilejson cfg ~basemap_root ~host ~query ~if_none_match ~which =
  Eio.Switch.run @@ fun sw ->
  let json = tilejson_body cfg ~host ~query ~if_none_match in
  (* Only archives whose data is actually on disk may be counted towards a
     floor -- see [Basemap_download.data_is_whole]. A file cut short after
     its directories were written answers every lookup and fails half the
     reads, which is exactly a floor full of holes. *)
  let floor_depth () =
    Basemap_download.floor_depth
      (List.filter_map
         (fun (name, a) ->
           (* The archive was open a moment ago -- the fd pins its inode -- but
              the NAME can be gone by now: the downloader renames over it under
              this same root. An archive we cannot size is not one we will
              certify a floor from, and it is not a reason to lose the
              connection. *)
           match Eio.Path.stat ~follow:true Eio.Path.(basemap_root / name) with
           | stat ->
               let size = Optint.Int63.to_int stat.Eio.File.Stat.size in
               if Basemap_download.data_is_whole ~size a then Some a else None
           | exception Eio.Io _ -> None)
         (open_tile_archives ~basemap_root ~sw Basemap_download.tile_files))
  in
  match which with
  | `Floor ->
      (* [max 0]: a depth of -1 means not even the zoom-0 tile is there, and
         a source cannot declare a negative range. It asks for one tile,
         gets the same 204 every other zoom would, and draws nothing -- which
         is the truth about an empty basemap directory. *)
      json ~min_zoom:0 ~max_zoom:(max 0 (floor_depth ())) ~bounds:whole_planet
  | `Detail ->
      let headers =
        List.map
          (fun (_, a) -> a.Pmtiles.Archive.header)
          (open_tile_archives ~basemap_root ~sw Basemap_download.detail_files)
      in
      let e7f v = float_of_int v /. 1e7 in
      let min_zoom, max_zoom, bounds =
        match headers with
        (* Nothing downloaded. The depth stated here is not only what
           MapLibre asks for: the coverage note clamps its question to it,
           to avoid calling a view blank when the source is overzooming
           tiles it really holds. Reporting 0 for an empty archive silences
           the note at every zoom -- in the one state where offering the
           download is the whole point. So the honest 15 stays, and the
           cost is a viewport of misses on every pan until something is
           downloaded. Roadmap: one field, two jobs. *)
        | [] -> (0, 15, whole_planet)
        | h :: t ->
            let fold f field =
              List.fold_left (fun acc h -> f acc (field h)) (field h) t
            in
            ( fold min (fun (h : Pmtiles.Header.t) -> h.Pmtiles.Header.min_zoom),
              fold max (fun h -> h.Pmtiles.Header.max_zoom),
              [
                e7f (fold min (fun h -> h.Pmtiles.Header.min_lon_e7));
                e7f (fold min (fun h -> h.Pmtiles.Header.min_lat_e7));
                e7f (fold max (fun h -> h.Pmtiles.Header.max_lon_e7));
                e7f (fold max (fun h -> h.Pmtiles.Header.max_lat_e7));
              ] )
      in
      (* The two documents describe one archive cut in two, and this is where
         the cut falls. Below it the floor is complete, and the tiles it
         would draw are the same bytes this source would draw -- so asking
         for them twice buys a duplicate of every tile in the viewport and
         nothing else.

         When the cut lands past this source's own depth there is nothing
         above the floor to draw, and the range comes out empty on purpose:
         MapLibre skips every tile shallower than [minzoom] and never looks
         deeper than [maxzoom], so an empty range is a source that requests
         nothing. Left overlapping instead, a world-overview-only archive
         would paint its coarsest tiles OVER the floor's finer ones -- the
         map getting worse inside the region you downloaded. *)
      let min_zoom = max min_zoom (floor_depth () + 1) in
      json ~min_zoom ~max_zoom ~bounds

(* One vector tile. Bytes go out exactly as stored when the client accepts
   the archive's compression, inflated for one that does not -- same policy
   as the embedded assets, for the same curl-and-scripts reason. A tile
   nobody holds is 204, not 404: past the edge of what was downloaded, an
   empty tile is a normal answer the map renders as nothing, where an error
   would be logged as one -- on every pan. *)
let serve_tile cfg ~basemap_root ~meth ~client_headers ~z ~x ~y =
  let id = Pmtiles.Tile_id.of_zxy ~z ~x ~y in
  let found =
    Eio.Switch.run @@ fun sw ->
    (* Opened one at a time and only as far as the answer: the list grew a
       third entry for the world floor, and a tile the browse cache already
       holds must not pay to open the two archives behind it. *)
    List.find_map
      (fun name ->
        match open_tile_archive ~basemap_root ~sw name with
        | None -> None
        | Some archive -> (
            match Pmtiles.Archive.tile archive id with
            | v -> Option.map (fun b -> (b, archive.Pmtiles.Archive.header)) v
            | exception e ->
                Logs.warn (fun m ->
                    m "tile %d/%d/%d: unreadable %s: %s" z x y name
                      (Printexc.to_string e));
                None))
      Basemap_download.tile_files
  in
  match found with
  | None ->
      (* No validator here, deliberately. A tag looks like the obvious
         saving -- past the edge of a download most of a viewport is this
         reply -- but it was measured to buy nothing: Chromium does not
         store a 204, so it never sends the tag back and the 304 never
         happens, while a control on the same origin revalidated a real tile
         correctly. A 204 has no body to re-send either way. It also has no
         representation, which makes an ETag on it a fiction (RFC 9110 8.8.3)
         and would turn `If-None-Match: *` into a 304 where the spec asks
         for the 204.

         No content-length on a 204 (RFC 9110), and nothing written --
         cohttp's string-body path would add the length back, so this is an
         Expert response like the found case. *)
      let headers =
        Http.Header.of_list
          (("cache-control", "no-cache") :: security_headers cfg)
      in
      let response = Http.Response.make ~status:`No_content ~headers () in
      (`Expert (response, fun _ic _oc -> ()), `No_content, 0, Http_range.Whole)
  | Some (bytes, header) ->
      (* Which encoding this client gets, and whether the stored bytes go out
         as they are. [inflate] is deferred: a request that ends in a 304 must
         not decompress a tile to say nothing changed. *)
      let enc, inflate =
        match header.Pmtiles.Header.tile_compression with
        | Pmtiles.Header.Gzip when accepts_gzip client_headers ->
            (Some "gzip", false)
        | Pmtiles.Header.Gzip -> (None, true)
        | Pmtiles.Header.Brotli -> (Some "br", false)
        | Pmtiles.Header.Zstd -> (Some "zstd", false)
        | Pmtiles.Header.None_ | Pmtiles.Header.Unknown -> (None, false)
      in
      let encoding =
        match enc with None -> [] | Some e -> [ ("content-encoding", e) ]
      in
      (* Hashed per request rather than derived from the archive, because the
         archive is exactly what changes underneath: a browse-cache download
         lands new tiles at URLs the browser already holds, and cache.pmtiles
         is then renamed into place. A tag over the bytes cannot miss that.

         Over the bytes AS STORED, with the encoding named alongside, so the
         two encodings of one tile are two tags without inflating anything to
         find that out. *)
      let etag = Http_cache.of_bytes ~encoding:enc bytes in
      let vary = [ ("vary", "accept-encoding") ] in
      if
        Http_cache.is_fresh
          ~if_none_match:(joined client_headers "if-none-match")
          ~etag
      then not_modified cfg ~etag ~cache_control:"no-cache" ~vary
      else
        let bytes = if inflate then Gzip.decompress bytes else bytes in
        let headers =
          Http.Header.of_list
            (("content-type", "application/x-protobuf")
            :: ("content-length", string_of_int (String.length bytes))
            (* Revalidate, never trust: an update or removal changes tiles
               under the same URL. The ETag above is what makes that cheap --
               the rule is unchanged, the answer is now an empty 304 rather
               than the tile again. MapLibre's own in-memory cache carries the
               session; the style's ?v= carries the swaps. *)
            :: ("cache-control", "no-cache")
            :: ("etag", etag)
            :: (vary @ encoding @ security_headers cfg))
        in
        let response = Http.Response.make ~status:`OK ~headers () in
        (* HEAD gets the headers and no body, or the tile bytes would be
           parsed as the start of the next response on this connection. *)
        let write _ic oc = if meth <> `HEAD then Write.string oc bytes in
        (`Expert (response, write), `OK, String.length bytes, Http_range.Whole)

(* ------------------------------------------------------- embedded assets *)

(* The built UI, compiled into the binary. This is what makes the desktop
   target one file rather than a file plus a directory that has to travel with
   it. Empty when the UI has not been built, in which case everything falls
   through to the directory named by --ui.

   Stored gzipped and normally served that way; [accepts_gzip] above decides
   whether a client takes them as stored. *)
let serve_embedded cfg ~segments ~meth ~headers =
  match Embedded_assets.find (String.concat "/" segments) with
  | None -> None
  | Some (digest, packed) ->
      let name = match List.rev segments with [] -> "" | n :: _ -> n in
      (* One answer to "which encoding is this", used for both the header and
         the tag. Deriving it twice is how a tag comes to describe the other
         representation. *)
      let enc = if accepts_gzip headers then Some "gzip" else None in
      let extra =
        match enc with None -> [] | Some e -> [ ("content-encoding", e) ]
      in
      (* Cached responses vary by whether the client took the gzip, so a
         shared cache must not hand one client the other's bytes -- and the
         two encodings are two representations, so they get two tags. *)
      let vary = [ ("vary", "accept-encoding") ] in
      let etag = Http_cache.of_digest ~encoding:enc digest in
      let cache_control = Url_path.cache_control segments in
      if
        Http_cache.is_fresh ~if_none_match:(joined headers "if-none-match")
          ~etag
      then Some (not_modified cfg ~etag ~cache_control ~vary)
      else
        (* Decompressed only once we know we are sending it. This is where
           the built UI lives, and a reload that ends in a 304 should not
           inflate it to say so. *)
        let body =
          if enc = Some "gzip" then packed else Gzip.decompress packed
        in
        let headers_out =
          Http.Header.of_list
            (("content-type", Url_path.content_type name)
            :: ("content-length", string_of_int (String.length body))
            :: ("cache-control", cache_control)
            :: ("etag", etag)
            :: (vary @ extra @ security_headers cfg))
        in
        let response = Http.Response.make ~status:`OK ~headers:headers_out () in
        let write _ic oc = if meth <> `HEAD then Write.string oc body in
        Some
          (`Expert (response, write), `OK, String.length body, Http_range.Whole)

(* ----------------------------------------------------------- file serving *)

(* A window onto an open file, so a range response never materialises in
   memory. Eio's File.pread fills from an explicit offset, which keeps this
   free of seek state shared with anything else. *)
let stream_region file ~offset ~length oc =
  let chunk = 64 * 1024 in
  let buf = Cstruct.create (min chunk length) in
  let rec go ~offset ~remaining =
    if remaining > 0 then begin
      let want = min (Cstruct.length buf) remaining in
      let n = Eio.File.pread file ~file_offset:offset [ Cstruct.sub buf 0 want ] in
      Write.cstruct oc (Cstruct.sub buf 0 n);
      go ~offset:(Optint.Int63.add offset (Optint.Int63.of_int n))
        ~remaining:(remaining - n)
    end
  in
  go ~offset:(Optint.Int63.of_int offset) ~remaining:length

(* Serving a file is `Expert` rather than `Response` because the body has to be
   written while the file is still open. cohttp-eio applies the response
   closure after the callback returns, so a `with_open_in` around a `Response`
   closes the file before a single byte is written. *)
let serve_file cfg ~what ~root ~segments ~meth ~range_header ~if_none_match
    ~if_range ~immutable =
  let path = List.fold_left Eio.Path.( / ) root segments in
  (* Probe and stat together, not one then the other. `Url_path.resolve`
     cannot prevent a 300-byte segment reaching here and is not wrong not to:
     it holds no separator and cannot leave the root, which is all
     `theorem_no_escape` claims and all that is needed here. Whether a
     filesystem will hold a name that long is a fact about the directory, and
     F* is never told about directories.

     Sharing one [path_kind] with the stat closes the window where the file
     was there for the probe and gone for the stat -- the downloader renames
     `map.pmtiles` into place under this very root, and this endpoint serves
     it. *)
  let probed =
    match path_kind ~what path with
    | `Regular_file -> (
        try Some (Eio.Path.stat ~follow:true path) with Eio.Io _ -> None)
    | _ -> None
  in
  match probed with
  | Some stat ->
      let size = Optint.Int63.to_int stat.Eio.File.Stat.size in
      let name = match List.rev segments with [] -> "" | n :: _ -> n in
      let cache_control =
        if immutable then Url_path.cache_control segments else "no-cache"
      in
      (* Size and mtime rather than a hash of the contents: these are the
         glyphs and sprites, and also map.pmtiles, which is a gigabyte served
         in ranges. Reading a file end to end to decide whether to send it
         would cost more than sending it. *)
      let etag =
        Http_cache.of_stamp
          ~key:(String.concat "/" segments)
          ~size ~mtime:stat.Eio.File.Stat.mtime
      in
      (* A Range against a validator that has moved on is answered with the
         whole thing, not with a window into different bytes. This endpoint
         serves map.pmtiles, which the downloader rewrites in place, so a
         client splicing a stale 206 into a partial copy would be joining two
         archives -- and it now has a tag to form that partial with. *)
      let range =
        if Http_cache.range_is_current ~if_range ~etag then
          Http_range.parse ~header:range_header ~length:size
        else Http_range.Whole
      in
      let base =
        ("content-type", Url_path.content_type name)
        :: ("accept-ranges", "bytes")
        :: ("cache-control", cache_control)
        :: ("etag", etag)
        :: security_headers cfg
      in
      (* Ahead of the range: If-None-Match is evaluated before Range (RFC 9110
         13.2.2), so a client holding the current bytes gets a 304 whether it
         asked for all of them or a window. *)
      if Http_cache.is_fresh ~if_none_match ~etag then
        not_modified cfg ~etag ~cache_control ~vary:[]
      else
      let status, offset, length, extra =
        match range with
        | Http_range.Whole -> (`OK, 0, size, [])
        | Http_range.Partial span ->
            ( `Partial_content,
              span.first,
              Http_range.length_of span,
              [ ("content-range", Http_range.content_range span ~length:size) ] )
        | Http_range.Unsatisfiable ->
            ( `Requested_range_not_satisfiable,
              0,
              0,
              [ ("content-range", Http_range.unsatisfiable_content_range ~length:size) ]
            )
      in
      let headers =
        Http.Header.of_list
          (("content-length", string_of_int length) :: (base @ extra))
      in
      let response = Http.Response.make ~status ~headers () in
      let body _ic oc =
        (* HEAD is the same response with the body withheld, not a different
           one -- the Content-Length must still describe what a GET returns. *)
        if meth <> `HEAD && length > 0 then
          Eio.Path.with_open_in path (fun file ->
              stream_region file ~offset ~length oc)
      in
      (`Expert (response, body), (status :> Http.Status.t), length, range)
  | None ->
      let response, bytes = error cfg ~status:`Not_found "not found" in
      (response, `Not_found, bytes, Http_range.Whole)

(* The arithmetic behind every answer the HTTP API gives: the C emitted by
   KaRaMeL from the F* proofs, over the FFI (ocaml/c_core). It replaced the
   extracted-OCaml core here once the side-by-side wall had run beside it
   long enough; that wall still runs on every `make test`, so the two are
   still compared, and only one of them serves.

   Scope, stated plainly: `/api/*` is off unless the server is started with
   --api, and no UI path uses it. So in the default and desktop
   configurations this core computes nothing, and every address a user sees
   still comes from the js_of_ocaml core in the browser -- until the browser
   half of the switch lands. *)
let core = Tessarium_c_core.C_core.core

(* ------------------------------------------------------------- session API *)

(* Off by default, and the README has to say which mode is running. Enabling it
   means a seed phrase crosses the network, which is exactly the property the
   client-side derivation exists to avoid. It survives because scripting and
   headless use need it, not because the UI does. *)
module Sessions = struct
  (* Derived keys expire. Without a TTL a long-running self-hosted instance
     accumulates them until it exits, which turns a convenience cache into a
     growing pile of key material in memory — the worst possible thing to keep
     indefinitely by accident. *)
  let ttl = 3600.0

  (* And a ceiling, because a TTL alone still admits unbounded growth inside
     one TTL window. Oldest goes first. *)
  let max_sessions = 1024

  type entry = { key : string; created : float }
  type t = { mutex : Eio.Mutex.t; table : (string, entry) Hashtbl.t }

  let create () = { mutex = Eio.Mutex.create (); table = Hashtbl.create 8 }

  let new_id random =
    let buf = Cstruct.create 18 in
    Eio.Flow.read_exact random buf;
    Base64.encode_string ~alphabet:Base64.uri_safe_alphabet
      (Cstruct.to_string buf)

  let expired ~now e = now -. e.created > ttl

  (* Swept on write rather than on a timer: there is no work to do when nothing
     is happening, and an idle server should not be waking up to tidy. *)
  let sweep t ~now =
    let dead =
      Hashtbl.fold (fun id e acc -> if expired ~now e then id :: acc else acc) t.table []
    in
    List.iter (Hashtbl.remove t.table) dead;
    if Hashtbl.length t.table >= max_sessions then begin
      let oldest =
        Hashtbl.fold
          (fun id e acc ->
            match acc with Some (_, c) when c <= e.created -> acc | _ -> Some (id, e.created))
          t.table None
      in
      match oldest with Some (id, _) -> Hashtbl.remove t.table id | None -> ()
    end

  let put t ~now id key =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        sweep t ~now;
        Hashtbl.replace t.table id { key; created = now })

  let get t ~now id =
    Eio.Mutex.use_ro t.mutex (fun () ->
        match Hashtbl.find_opt t.table id with
        | Some e when not (expired ~now e) -> Some e.key
        | _ -> None)

  let drop t id =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () -> Hashtbl.remove t.table id)
end

let json_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let string_field name json =
  match json_field name json with Some (`String s) -> Some s | _ -> None

(* Nanodegrees arrive as strings for the same reason they leave as strings:
   JSON numbers are IEEE-754 doubles, and 1.8e11 nanodegrees is past the point
   where every integer survives a round trip through one. *)
let z_of_string_opt s = try Some (Z.of_string s) with Invalid_argument _ -> None

let z_field name json =
  match json_field name json with
  | Some (`String s) -> z_of_string_opt s
  | Some (`Int i) -> Some (Z.of_int i)
  | Some (`Intlit s) -> z_of_string_opt s
  | _ -> None

(* The endpoints that spend or reveal key material share one token bucket.
   Session because Argon2id is deliberately expensive; encode and decode
   because each answer is a chosen plaintext/ciphertext pair, and the FE1
   write-up's oracle arithmetic (docs/fe1-security.md) leans on this ceiling
   -- an unthrottled encode oracle would answer a million queries in about a
   minute. The basemap endpoints stay outside: they touch tiles, never the
   key, and a download's status is polled every second. *)
let rate_limited_endpoint = function
  | "session" | "encode" | "decode" -> true
  | _ -> false

let handle_api cfg sessions limiter random ~endpoint ~body ~now =
  let bad = error cfg ~status:`Bad_request in
  match Yojson.Safe.from_string body with
  | exception _ -> bad "body is not valid JSON"
  | json -> (
      let with_key f =
        match string_field "session" json with
        | None -> bad "missing session"
        | Some id -> (
            match Sessions.get sessions ~now id with
            | None -> error cfg ~status:`Not_found "unknown or expired session"
            | Some key -> f key)
      in
      let limited f =
        if not (rate_limited_endpoint endpoint) then f ()
        else begin
          let allowed, limiter' =
            Rate_limit.take Rate_limit.default !limiter ~now
          in
          limiter := limiter';
          if not allowed then
            let wait =
              Rate_limit.retry_after Rate_limit.default !limiter ~now
            in
            respond_json cfg ~status:`Too_many_requests
              (`Assoc
                 [
                   ("error", `String "too many requests; slow down");
                   ("retry_after", `Int wait);
                 ])
          else f ()
        end
      in
      match endpoint with
      | "session" -> (
          limited @@ fun () ->
          match string_field "mnemonic" json with
            | None -> bad "missing mnemonic"
            | Some mnemonic -> (
                let passphrase =
                  Option.value (string_field "passphrase" json) ~default:""
                in
                match Tessarium.derive_key ~kdf:Tessarium_argon2.kdf ~mnemonic ~passphrase with
                | exception Tessarium.Bad_mnemonic e -> bad e.Tessarium.message
                | exception Tessarium.Bad_passphrase e -> bad e.Tessarium.message
                | key ->
                    let id = Sessions.new_id random in
                    Sessions.put sessions ~now id key;
                    respond_json cfg ~status:`OK (`Assoc [ ("session", `String id) ])))
      | "logout" -> (
          match string_field "session" json with
          | None -> bad "missing session"
          | Some id ->
              Sessions.drop sessions id;
              respond_json cfg ~status:`OK (`Assoc [ ("ok", `Bool true) ]))
      | "encode" ->
          limited @@ fun () ->
          with_key (fun key ->
              match (z_field "lat_ns" json, z_field "lon_ns" json) with
              | Some lat, Some lon -> (
                  match Tessarium.encode_z ~core ~key ~lat ~lon with
                  | exception Invalid_argument e -> bad e
                  | address ->
                      respond_json cfg ~status:`OK
                        (`Assoc [ ("address", `String address) ]))
              | _ -> bad "missing lat_ns or lon_ns")
      | "decode" ->
          limited @@ fun () ->
          with_key (fun key ->
              match string_field "address" json with
              | None -> bad "missing address"
              | Some address -> (
                  match Tessarium.decode ~core ~key address with
                  | exception Tessarium.Invalid_address e -> bad e.Tessarium.message
                  (* The C core refuses arguments outside its proved domain
                     rather than computing over them. address_of_string cannot
                     produce such a tuple, so this is unreachable today; it is
                     here so an unreachable case stays a 400 rather than a
                     dropped connection if that ever stops being true. *)
                  | exception Invalid_argument e -> bad e
                  | Error e -> error cfg ~status:`Not_found e
                  | Ok (lat, lon) ->
                      respond_json cfg ~status:`OK
                        (`Assoc
                           [
                             ("lat_ns", `String (string_of_int lat));
                             ("lon_ns", `String (string_of_int lon));
                           ])))
      | _ -> error cfg ~status:`Not_found "no such endpoint")

(* ----------------------------------------------------------- basemap API *)

(* Bounding boxes are plain JSON numbers. Floats are fine here: this is the
   tile-picking side of the codebase, which never touches an address. *)
let float_field name json =
  match json_field name json with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | _ -> None

let int_field name json =
  match json_field name json with Some (`Int i) -> Some i | _ -> None

(* A polygon arrives as rings of [lon,lat] pairs. Anything malformed is a
   parse error for the whole region; the size caps live in the validator. *)
let parse_polygon json =
  let num = function
    | `Float f -> Some f
    | `Int i -> Some (float_of_int i)
    | _ -> None
  in
  match json_field "polygon" json with
  | None | Some `Null -> Ok None
  | Some (`List rings) -> (
      let ring = function
        | `List points ->
            let parsed =
              List.map
                (function
                  (* GeoJSON positions may carry elevation; ignore it. *)
                  | `List (a :: b :: _) -> (
                      match (num a, num b) with
                      | Some lon, Some lat -> Some (lon, lat)
                      | _ -> None)
                  | _ -> None)
                points
            in
            if List.for_all Option.is_some parsed then
              Some (Array.of_list (List.filter_map Fun.id parsed))
            else None
        | _ -> None
      in
      match List.map ring rings with
      | parsed when List.for_all Option.is_some parsed ->
          Ok (Some (Array.of_list (List.filter_map Fun.id parsed)))
      | _ -> Error "polygon must be rings of [lon,lat] pairs")
  | Some _ -> Error "polygon must be rings of [lon,lat] pairs"

let parse_region json =
  match
    ( float_field "min_lon" json,
      float_field "min_lat" json,
      float_field "max_lon" json,
      float_field "max_lat" json,
      int_field "max_zoom" json )
  with
  | Some min_lon, Some min_lat, Some max_lon, Some max_lat, Some max_zoom -> (
      match parse_polygon json with
      | Error e -> Error e
      | Ok polygon ->
          Basemap_job.validate ?polygon ~min_lon ~min_lat ~max_lon ~max_lat ~max_zoom ())
  | _ -> Error "missing min_lon, min_lat, max_lon, max_lat or max_zoom"

(* One request names one or more regions -- the picker lets several countries,
   states and cities ride in a single download, merged and deduplicated
   server-side. The cap is a sanity bound far above anything the picker
   sends, not a promise. *)
let parse_regions json =
  match json_field "regions" json with
  | Some (`List []) -> Error "regions must not be empty"
  | Some (`List items) when List.length items > 64 ->
      Error "too many regions in one request"
  | Some (`List items) ->
      List.fold_left
        (fun acc item ->
          match acc with
          | Error _ -> acc
          | Ok regions -> (
              match parse_region item with
              | Ok r -> Ok (r :: regions)
              | Error e -> Error e))
        (Ok []) items
      |> Result.map List.rev
  | _ -> Error {|missing regions: expected {"regions": [...]}|}

(* The ledger id is a hex digest prefix the server itself handed out; the
   only thing to defend against is garbage. *)
let parse_id json =
  match json_field "id" json with
  | Some (`String s)
    when String.length s > 0 && String.length s <= 64
         && String.for_all
              (function 'a' .. 'f' | '0' .. '9' -> true | _ -> false)
              s ->
      Ok s
  | _ -> Error {|missing id: expected {"id": "..."}|}

(* Which failure a coverage query was. Separated from the handler because
   it is the whole decision and a Cohttp response cannot be read back:
   a viewport larger than one query allows is the caller asking for too
   much, and an archive this server cannot read is this server's own data
   gone wrong. Answering the second with a 400 blamed the page for it. *)
let coverage_status = function
  | Basemap_download.Too_large _ -> `Bad_request
  | Basemap_download.Unreadable _ -> `Internal_server_error

let coverage_message = function
  | Basemap_download.Too_large e | Basemap_download.Unreadable e -> e

let handle_basemap cfg (ops : Basemap_download.ops)
    (settings : Settings.ops) ~endpoint ~body =
  let bad = error cfg ~status:`Bad_request in
  (* A ledger or settings failure is this server's own data gone wrong, not
     the caller's request and not the upstream source. *)
  let broken = error cfg ~status:`Internal_server_error in
  let with_json body k =
    match Yojson.Safe.from_string body with
    | exception _ -> bad "body is not valid JSON"
    | json -> k json
  in
  let started = function
    | Ok () -> respond_json cfg ~status:`OK (`Assoc [ ("ok", `Bool true) ])
    | Error e -> error cfg ~status:`Conflict e
  in
  match endpoint with
  | "basemap-status" -> respond_json cfg ~status:`OK (ops.status ())
  | "basemap-cancel" ->
      let stopped = ops.cancel () in
      respond_json cfg ~status:`OK
        (`Assoc [ ("ok", `Bool true); ("stopped", `Bool stopped) ])
  | "basemap-ledger" -> (
      match ops.ledger () with
      | Ok payload -> respond_json cfg ~status:`OK payload
      | Error e -> broken e)
  | "basemap-update" ->
      with_json body (fun json ->
          match parse_id json with
          | Error e -> bad e
          | Ok id -> started (ops.update ~id))
  | "basemap-remove" ->
      with_json body (fun json ->
          match parse_id json with
          | Error e -> bad e
          | Ok id -> started (ops.remove ~id))
  | "basemap-browse" ->
      (* Gated on the opt-in setting server-side, not just in the UI: the
         page must not be able to make this server fetch from the network
         when the user has said no. *)
      if not (settings.browse_enabled ()) then
        error cfg ~status:`Forbidden "the browsing cache is off"
      else
        with_json body (fun json ->
            let num name =
              match json_field name json with
              | Some (`Int i) -> Some (float_of_int i)
              | Some (`Float f) -> Some f
              | _ -> None
            in
            (* 15.0 means 15: JSON has one number type, and a client's
               serializer choosing a decimal spelling is not a request for
               a fractional zoom level. Genuine fractions stay refused. *)
            let zoom =
              match json_field "zoom" json with
              | Some (`Int z) -> Some z
              | Some (`Float f)
                when Float.is_integer f && Float.abs f <= 32768. ->
                  Some (int_of_float f)
              | _ -> None
            in
            match
              ( num "min_lon",
                num "min_lat",
                num "max_lon",
                num "max_lat",
                zoom )
            with
            | ( Some min_lon,
                Some min_lat,
                Some max_lon,
                Some max_lat,
                Some zoom )
              when zoom >= 0 && zoom <= 15 -> (
                match
                  Basemap_job.validate ~min_lon ~min_lat ~max_lon ~max_lat
                    ~max_zoom:zoom ()
                with
                | Error e -> bad e
                | Ok req -> (
                    match ops.browse req with
                    | Ok (fetched, written_zoom) ->
                        (* The zoom actually written, which the source's own
                           depth may have clamped below the one asked for:
                           without it a client at a zoom the source cannot
                           reach keeps asking for tiles that will never
                           come. *)
                        respond_json cfg ~status:`OK
                          (`Assoc
                             [
                               ("ok", `Bool true);
                               ("fetched", `Int fetched);
                               ("zoom", `Int written_zoom);
                             ])
                    | Error e -> error cfg ~status:`Conflict e))
            | _ ->
                bad "expected min_lon, min_lat, max_lon, max_lat and zoom 0..15")
  | "basemap-coverage" ->
      (* Where the map goes blank. Reads the archives on disk and nothing
         else -- no network, no setting to gate, and no key material -- so
         it answers while a download runs and while browsing is off. *)
      with_json body (fun json ->
          let num name =
            match json_field name json with
            | Some (`Int i) -> Some (float_of_int i)
            | Some (`Float f) -> Some f
            | _ -> None
          in
          (* Integer-valued floats are accepted for the same reason browse
             accepts them: JSON has one number type, and a client whose
             serializer writes 12.0 is not asking for a fractional zoom. *)
          let zoom =
            match json_field "zoom" json with
            | Some (`Int z) -> Some z
            | Some (`Float f) when Float.is_integer f && Float.abs f <= 32768.
              ->
                Some (int_of_float f)
            | _ -> None
          in
          match (num "min_lon", num "min_lat", num "max_lon", num "max_lat", zoom)
          with
          | Some min_lon, Some min_lat, Some max_lon, Some max_lat, Some zoom
            -> (
              match
                Basemap_job.validate ~min_lon ~min_lat ~max_lon ~max_lat
                  ~max_zoom:zoom ()
              with
              | Error e -> bad e
              | Ok req -> (
                  match ops.coverage req with
                  | Ok payload -> respond_json cfg ~status:`OK payload
                  | Error e ->
                      error cfg ~status:(coverage_status e)
                        (coverage_message e)))
          | _ ->
              bad "expected min_lon, min_lat, max_lon, max_lat and zoom 0..15")
  | "basemap-search" ->
      (* Names out of the region already on disk. No network, by design: a
         search query names where the user is going, and handing that to a
         geocoder is the leak this whole product is arranged to avoid. *)
      with_json body (fun json ->
          match json_field "q" json with
          | Some (`String q)
            when String.trim q <> "" && String.length q <= 120 ->
              let limit =
                match json_field "limit" json with
                | Some (`Int n) when n > 0 && n <= 50 -> n
                | _ -> 10
              in
              (match ops.search ~query:q ~limit with
              | Ok payload -> respond_json cfg ~status:`OK payload
              | Error e -> broken e)
          | _ -> bad "expected q, a non-empty string of at most 120 bytes")
  | "basemap-settings" ->
      with_json body (fun json ->
          (* An empty body reads; either field alone writes just itself. *)
          match
            ( json_field "update_reminder_days" json,
              json_field "browse_cache" json )
          with
          | None, None -> (
              match settings.get () with
              | Ok payload -> respond_json cfg ~status:`OK payload
              | Error e -> broken e)
          | Some j, _ when (match j with `Int _ -> false | _ -> true) ->
              bad "update_reminder_days must be an integer"
          | _, Some j when (match j with `Bool _ -> false | _ -> true) ->
              bad "browse_cache must be a boolean"
          | days, browse -> (
              let days =
                match days with Some (`Int d) -> Some d | _ -> None
              in
              let browse =
                match browse with Some (`Bool b) -> Some b | _ -> None
              in
              match settings.set ~days ~browse with
              | Ok payload ->
                  (* Off means gone: the browse cache is a record of where
                     the user looked, so turning the setting off erases it
                     rather than leaving it dormant and still serving. This
                     returns at once whether or not a writer holds the file;
                     one that does erases it as it finishes, and browsing is
                     already off, so nothing new can arrive meanwhile. *)
                  if browse = Some false then ops.clear_cache ();
                  respond_json cfg ~status:`OK payload
              | Error e -> bad e))
  | "basemap-estimate" | "basemap-download" -> (
      match Yojson.Safe.from_string body with
      | exception _ -> bad "body is not valid JSON"
      | json -> (
          match parse_regions json with
          | Error e -> bad e
          | Ok reqs ->
              if String.equal endpoint "basemap-estimate" then
                match ops.estimate reqs with
                | Ok payload -> respond_json cfg ~status:`OK payload
                | Error e ->
                    (* The failure is upstream of this server -- the tile
                       source is unreachable or broken -- and the status code
                       should say so rather than blame the request. *)
                    error cfg ~status:`Bad_gateway e
              else
                (* The ledger displays whatever name the picker sends, so it
                   is bounded and printable or the request dies here. *)
                match json_field "name" json with
                | Some (`String s) when Ledger.valid_name s ->
                    started (ops.start ~name:(Some s) reqs)
                | Some _ -> bad "name must be 1-120 bytes of printable UTF-8"
                | None -> started (ops.start ~name:None reqs)))
  | _ -> error cfg ~status:`Not_found "no such endpoint"

(* Whether a request declared a body. Both mistakes around this are real and
   were both made here: reading a body that was never declared waits on a
   keep-alive connection for bytes that never come, and NOT draining one that
   was declared leaves its bytes in the connection to be parsed as the start
   of the next request -- every later request on that connection then fails.
   The headers decide; nothing else can. *)
let declares_body headers =
  Http.Header.get headers "content-length" <> None
  || Http.Header.get headers "transfer-encoding" <> None

(* ------------------------------------------------------- cross-origin writes

   Every /api/ endpoint DOES something: derives a key from a phrase, starts a
   multi-gigabyte download, deletes a downloaded map, turns on the cache that
   fetches over the network. The server listens on loopback and asks for no
   credentials, so "a program on this machine" is the whole of its access
   control -- and a page the user happens to have open is, to a socket, a
   program on this machine. Without this, that page can drive every one of
   them; it cannot read the answers back, but every side effect lands.

   Two headers decide it, and the BROWSER sets both -- a page cannot forge
   either. Sec-Fetch-Site says where the request came from; Origin names the
   page behind a cross-origin write. curl and scripts send neither, which is
   what --api exists for, so silence is allowed: this judges browsers.

   The content type is the third leg, for the shapes a page can post with no
   preflight at all -- text/plain, form-urlencoded, multipart. Requiring JSON
   means the browser has to ask permission first, and nothing here answers. *)
let same_origin_as_host origin host =
  let o = String.lowercase_ascii (String.trim origin) in
  (* Origin is scheme://host[:port]; Host is host[:port]. A null origin --
     a sandboxed frame, a data: URL -- has no host and matches nothing. *)
  let authority =
    match String.index_opt o '/' with
    | Some i when i + 1 < String.length o && o.[i + 1] = '/' ->
        String.sub o (i + 2) (String.length o - i - 2)
    | _ -> ""
  in
  authority <> "" && String.equal authority (String.lowercase_ascii host)

let from_another_site get =
  match get "sec-fetch-site" with
  | Some s -> (
      match String.lowercase_ascii (String.trim s) with
      | "same-origin" | "none" -> false
      | _ -> true)
  | None -> (
      match get "origin" with
      | None -> false
      | Some o ->
          let host = Option.value (get "host") ~default:"" in
          not (same_origin_as_host o host))

let is_json get =
  match get "content-type" with
  | None -> false
  | Some v ->
      let v = String.lowercase_ascii (String.trim v) in
      let base =
        match String.index_opt v ';' with
        | Some i -> String.trim (String.sub v 0 i)
        | None -> v
      in
      String.equal base "application/json"

(* ---------------------------------------------------------------- handler *)

let status_code s = Http.Status.to_int s

let handler cfg ~ui_root ~basemap_root ~sessions ~limiter ~clock ~random
    ~basemap_ops ~settings_ops =
  let simple (result, bytes) status = (result, status, bytes, Http_range.Whole) in
  fun _conn (request : Http.Request.t) body ->
    let meth = Http.Request.meth request in
    let header = Http.Header.get (Http.Request.headers request) in
    let target = Http.Request.resource request in
    let route = Route.of_request ~meth ~target in
    let range_header = Http.Header.get (Http.Request.headers request) "range" in
    let if_none_match = joined (Http.Request.headers request) "if-none-match" in
    let if_range = Http.Header.get (Http.Request.headers request) "if-range" in
    let result, status, bytes, range =
      match route with
      | Route.Health ->
          simple
            (respond_json cfg ~status:`OK
               (`Assoc
                  [
                    ("status", `String "ok");
                    ("grid", `String Tessarium.grid_version);
                    ("api", `Bool cfg.api_enabled);
                  ]))
            `OK
      (* Both guards sit above the --api gate on purpose: the basemap
         endpoints are reachable without it, and they are the ones that can
         spend a user's disk and bandwidth. *)
      | Route.Api _ when from_another_site header ->
          simple
            (error cfg ~status:`Forbidden
               "this endpoint cannot be called from another site")
            `Forbidden
      | Route.Api _ when not (is_json header) ->
          simple
            (error cfg ~status:`Unsupported_media_type
               "this endpoint takes application/json")
            `Unsupported_media_type
      | Route.Api endpoint when Route.is_basemap_api endpoint ->
          (* Reachable without --api: see [Route.is_basemap_api]. *)
          let body =
            if declares_body (Http.Request.headers request) then
              Eio.Flow.read_all body
            else ""
          in
          simple (handle_basemap cfg basemap_ops settings_ops ~endpoint ~body) `OK
      | Route.Api endpoint ->
          if not cfg.api_enabled then
            simple
              (error cfg ~status:`Not_found
                 "the encode/decode API is disabled; start with --api to enable it")
              `Not_found
          else
            let body =
              if declares_body (Http.Request.headers request) then
                Eio.Flow.read_all body
              else ""
            in
            let now = Eio.Time.now clock in
            simple (handle_api cfg sessions limiter random ~endpoint ~body ~now) `OK
      | Route.Tile { z; x; y } ->
          serve_tile cfg ~basemap_root ~meth
            ~client_headers:(Http.Request.headers request) ~z ~x ~y
      | Route.Tile_json { floor } ->
          (* Only the style's own ?v= cache-buster is reflected into the
             tile URLs; anything else is dropped rather than echoed. *)
          let query =
            match String.index_opt target '?' with
            | Some i ->
                let q = String.sub target i (String.length target - i) in
                let n = String.length q in
                if
                  n > 3 && n <= 24
                  && String.sub q 0 3 = "?v="
                  && String.for_all
                       (fun c -> c >= '0' && c <= '9')
                       (String.sub q 3 (n - 3))
                then q
                else ""
            | None -> ""
          in
          let host =
            match Http.Header.get (Http.Request.headers request) "host" with
            | Some h
              when String.length h <= 260
                   && String.for_all
                        (function
                          | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '-'
                          | ':' | '[' | ']' ->
                              true
                          | _ -> false)
                        h ->
                h
            | _ -> "127.0.0.1"
          in
          let which = if floor then `Floor else `Detail in
          (match
             serve_tilejson cfg ~basemap_root ~host ~query ~if_none_match ~which
           with
          | `Not_modified etag ->
              not_modified cfg ~etag ~cache_control:"no-cache" ~vary:[]
          | `Body body -> simple body `OK)
      | Route.Basemap segments ->
          serve_file cfg ~what:"basemap" ~root:basemap_root ~segments ~meth
            ~range_header
            ~if_none_match ~if_range ~immutable:false
      | Route.Asset segments -> (
          let headers = Http.Request.headers request in
          (* Embedded first, then the directory -- so when the binary carries
             a UI, that UI is what ships, and --ui only fills the gap in a
             binary built without one. The trap: after `npm run build`, a
             stale ocaml/server/ui_dist keeps serving the OLD interface no
             matter what --ui says. Refresh it (make ui) and rebuild. *)
          let from_disk () =
            let served =
              serve_file cfg ~what:"asset" ~root:ui_root ~segments ~meth
                ~range_header
                ~if_none_match ~if_range ~immutable:true
            in
            let _, status, _, _ = served in
            (* A single-page app owns its own routes: /somewhere must return
               the shell so a deep link survives a reload. A missing .js must
               not. *)
            if status = `Not_found && Route.is_spa_fallback segments then
              match
                serve_embedded cfg ~segments:[ "index.html" ] ~meth ~headers
              with
              | Some shell -> shell
              | None ->
                  serve_file cfg ~what:"asset" ~root:ui_root
                    ~segments:[ "index.html" ] ~meth ~range_header:None
                    ~if_none_match ~if_range ~immutable:false
            else served
          in
          match serve_embedded cfg ~segments ~meth ~headers with
          | Some served -> served
          | None -> from_disk ())
      | Route.Not_found ->
          simple (error cfg ~status:`Not_found "not found") `Not_found
      | Route.Method_not_allowed ->
          simple
            (error cfg ~status:`Method_not_allowed "method not allowed")
            `Method_not_allowed
    in
    Access_log.emit
      {
        Access_log.route;
        status = status_code status;
        bytes;
        partial = (match range with Http_range.Partial _ -> true | _ -> false);
      };
    result

let run env ~sw ~port cfg =
  let fs = Eio.Stdenv.fs env in
  let ui_root = Eio.Path.(fs / cfg.ui_dir) in
  let basemap_root = Eio.Path.(fs / cfg.basemap_dir) in
  let sessions = Sessions.create () in
  let limiter = ref (Rate_limit.create Rate_limit.default) in
  let clock = Eio.Stdenv.clock env in
  let random = Eio.Stdenv.secure_random env in
  let basemap_ops =
    Basemap_download.ops
      (Basemap_download.create ())
      ~sw ~fs ~net:(Eio.Stdenv.net env) ~source:cfg.basemap_source
      ~assets:cfg.basemap_assets ~basemap_dir:cfg.basemap_dir
      ~budget:cfg.tile_budget
      (* Epoch seconds for the ledger; the float is Eio's, the truncation
         deliberate -- sub-second precision on a download date is noise. *)
      ~now:(fun () -> int_of_float (Eio.Time.now clock))
  in
  let settings_ops = Settings.ops ~fs ~basemap_dir:cfg.basemap_dir in
  let callback =
    handler cfg ~ui_root ~basemap_root ~sessions ~limiter ~clock ~random
      ~basemap_ops ~settings_ops
  in
  let server = Cohttp_eio.Server.make_response_action ~callback () in
  (* Loopback only. This binary is the desktop app as well as the self-hosted
     server, and a desktop app that listens on every interface is a mistake
     that is invisible until it is not. *)
  let socket =
    Eio.Net.listen (Eio.Stdenv.net env) ~sw ~backlog:128 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  Cohttp_eio.Server.run socket server ~on_error:(fun exn ->
      Logs.warn (fun m -> m "connection error: %s" (Printexc.to_string exn)))
