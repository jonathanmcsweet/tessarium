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
      "script-src 'self'";
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
let respond_string cfg ~status ~content_type body =
  let headers =
    Http.Header.of_list
      (("content-type", content_type)
      :: ("content-length", string_of_int (String.length body))
      :: security_headers cfg)
  in
  ( `Response
      (Cohttp_eio.Server.respond ~headers ~status
         ~body:(Cohttp_eio.Body.of_string body) ()),
    String.length body )

let respond_json cfg ~status json =
  respond_string cfg ~status ~content_type:"application/json; charset=utf-8"
    (Yojson.Safe.to_string json)

let error cfg ~status message =
  respond_json cfg ~status (`Assoc [ ("error", `String message) ])

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

(* ------------------------------------------------------------------ tiles *)

(* Tile archives in lookup order: the browse cache first when it exists
   (newer wins), then the main archive. Opened per request and closed with
   it: the root directory is capped at 16 KB by the format, so this is a
   header and a handful of small reads against the page cache, and a rename
   cannot tear an open handle -- the fd pins whichever inode it opened. *)
let tile_files = [ "cache.pmtiles"; "map.pmtiles" ]

let open_tile_archives ~basemap_root ~sw =
  List.filter_map
    (fun name ->
      let path = Eio.Path.(basemap_root / name) in
      match Eio.Path.kind ~follow:true path with
      | `Regular_file -> (
          match
            Pmtiles.Archive.open_
              (Pmtiles_source.file_source (Eio.Path.open_in ~sw path))
          with
          | archive -> Some (name, archive)
          | exception e ->
              Logs.warn (fun m ->
                  m "tile archive %s: unreadable: %s" name
                    (Printexc.to_string e));
              None)
      | _ -> None)
    tile_files

(* The source metadata the pmtiles protocol used to hand MapLibre from the
   archive header, restated as TileJSON. The zoom range is load-bearing:
   MapLibre pins canonical tile requests at the source's maxzoom and
   overzooms past it, so a hardcoded 15 over a world-at-z6 archive asked
   for z15 tiles nobody holds and rendered blank at street zoom -- over
   data the archive had. The bounds keep it from asking about the rest of
   the planet at all. [query] is the style's ?v= cache-buster, threaded
   into the tile URLs so a swap changes them. *)
let serve_tilejson cfg ~basemap_root ~host ~query =
  Eio.Switch.run @@ fun sw ->
  let headers =
    List.map
      (fun (_, a) -> a.Pmtiles.Archive.header)
      (open_tile_archives ~basemap_root ~sw)
  in
  let e7f v = float_of_int v /. 1e7 in
  let min_zoom, max_zoom, bounds =
    match headers with
    | [] -> (0, 15, [ -180.; -85.; 180.; 85. ])
    | h :: t ->
        let fold f field = List.fold_left (fun acc h -> f acc (field h)) (field h) t in
        ( fold min (fun (h : Pmtiles.Header.t) -> h.Pmtiles.Header.min_zoom),
          fold max (fun h -> h.Pmtiles.Header.max_zoom),
          [
            e7f (fold min (fun h -> h.Pmtiles.Header.min_lon_e7));
            e7f (fold min (fun h -> h.Pmtiles.Header.min_lat_e7));
            e7f (fold max (fun h -> h.Pmtiles.Header.max_lon_e7));
            e7f (fold max (fun h -> h.Pmtiles.Header.max_lat_e7));
          ] )
  in
  respond_json cfg ~status:`OK
    (`Assoc
       [
         ("tilejson", `String "3.0.0");
         (* Absolute, as the TileJSON spec requires -- MapLibre substitutes
            tile URLs inside a blob-URL worker, where a relative one has no
            base to resolve against. The host is the client's own Host
            header; this server is loopback-only plain HTTP. *)
         ( "tiles",
           `List
             [ `String ("http://" ^ host ^ "/tiles/{z}/{x}/{y}.mvt" ^ query) ]
         );
         ("minzoom", `Int min_zoom);
         ("maxzoom", `Int max_zoom);
         ("bounds", `List (List.map (fun v -> `Float v) bounds));
       ])

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
    List.find_map
      (fun (name, archive) ->
        match Pmtiles.Archive.tile archive id with
        | v -> Option.map (fun b -> (b, archive.Pmtiles.Archive.header)) v
        | exception e ->
            Logs.warn (fun m ->
                m "tile %d/%d/%d: unreadable %s: %s" z x y name
                  (Printexc.to_string e));
            None)
      (open_tile_archives ~basemap_root ~sw)
  in
  match found with
  | None ->
      (* No content-length on a 204 (RFC 9110), and nothing written --
         cohttp's string-body path would add the length back, so this is an
         Expert response like the found case. *)
      let headers =
        Http.Header.of_list
          (("cache-control", "no-cache") :: security_headers cfg)
      in
      let response = Http.Response.make ~status:`No_content ~headers () in
      (`Expert (response, fun _ic _oc -> ()), `No_content, 0, Http_range.Whole)
  | Some (bytes, header) ->
      let bytes, encoding =
        match header.Pmtiles.Header.tile_compression with
        | Pmtiles.Header.Gzip when accepts_gzip client_headers ->
            (bytes, [ ("content-encoding", "gzip") ])
        | Pmtiles.Header.Gzip -> (Gzip.decompress bytes, [])
        | Pmtiles.Header.Brotli -> (bytes, [ ("content-encoding", "br") ])
        | Pmtiles.Header.Zstd -> (bytes, [ ("content-encoding", "zstd") ])
        | Pmtiles.Header.None_ | Pmtiles.Header.Unknown -> (bytes, [])
      in
      let headers =
        Http.Header.of_list
          (("content-type", "application/x-protobuf")
          :: ("content-length", string_of_int (String.length bytes))
          (* Revalidate, never trust: an update or removal changes tiles
             under the same URL. MapLibre's own in-memory cache carries the
             session; the style's ?v= carries the swaps. *)
          :: ("cache-control", "no-cache")
          :: ("vary", "accept-encoding")
          :: (encoding @ security_headers cfg))
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
  | Some packed ->
      let gzipped = accepts_gzip headers in
      let body = if gzipped then packed else Gzip.decompress packed in
      let name = match List.rev segments with [] -> "" | n :: _ -> n in
      let extra =
        if gzipped then [ ("content-encoding", "gzip") ] else []
      in
      let headers_out =
        Http.Header.of_list
          (("content-type", Url_path.content_type name)
          :: ("content-length", string_of_int (String.length body))
          :: ("cache-control", Url_path.cache_control segments)
          (* Cached responses vary by whether the client took the gzip, so a
             shared cache must not hand one client the other's bytes. *)
          :: ("vary", "accept-encoding")
          :: (extra @ security_headers cfg))
      in
      let response = Http.Response.make ~status:`OK ~headers:headers_out () in
      let write _ic oc = if meth <> `HEAD then Write.string oc body in
      Some (`Expert (response, write), `OK, String.length body, Http_range.Whole)

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

let file_size file =
  Optint.Int63.to_int (Eio.File.size file)

(* Serving a file is `Expert` rather than `Response` because the body has to be
   written while the file is still open. cohttp-eio applies the response
   closure after the callback returns, so a `with_open_in` around a `Response`
   closes the file before a single byte is written. *)
let serve_file cfg ~root ~segments ~meth ~range_header ~immutable =
  let path = List.fold_left Eio.Path.( / ) root segments in
  match Eio.Path.kind ~follow:true path with
  | `Regular_file ->
      let size = Eio.Path.with_open_in path file_size in
      let range = Http_range.parse ~header:range_header ~length:size in
      let name = match List.rev segments with [] -> "" | n :: _ -> n in
      let base =
        ("content-type", Url_path.content_type name)
        :: ("accept-ranges", "bytes")
        :: ( "cache-control",
             if immutable then Url_path.cache_control segments else "no-cache" )
        :: security_headers cfg
      in
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
  | _ ->
      let response, bytes = error cfg ~status:`Not_found "not found" in
      (response, `Not_found, bytes, Http_range.Whole)

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
   Session because PBKDF2 is deliberately expensive; encode and decode
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
                match Tessarium.derive_key ~mnemonic ~passphrase with
                | exception Tessarium.Bad_mnemonic e -> bad e
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
                  match Tessarium.encode_z ~key ~lat ~lon with
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
                  match Tessarium.decode ~key address with
                  | exception Tessarium.Invalid_address e -> bad e
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
                     the user looked, so turning the setting off deletes it
                     rather than leaving it dormant and still serving. The
                     answer says whether that happened -- a download or a
                     compaction holds the writer's seat and keeps the file
                     alive for now, and claiming otherwise would be a lie
                     about the user's browsing history. *)
                  let payload =
                    if browse <> Some false then payload
                    else
                      let cleared = ops.clear_cache () in
                      match payload with
                      | `Assoc fields ->
                          `Assoc (fields @ [ ("cleared", `Bool cleared) ])
                      | other -> other
                  in
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

(* ---------------------------------------------------------------- handler *)

let status_code s = Http.Status.to_int s

let handler cfg ~ui_root ~basemap_root ~sessions ~limiter ~clock ~random
    ~basemap_ops ~settings_ops =
  let simple (result, bytes) status = (result, status, bytes, Http_range.Whole) in
  fun _conn (request : Http.Request.t) body ->
    let meth = Http.Request.meth request in
    let target = Http.Request.resource request in
    let route = Route.of_request ~meth ~target in
    let range_header = Http.Header.get (Http.Request.headers request) "range" in
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
      | Route.Tile_json ->
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
          simple (serve_tilejson cfg ~basemap_root ~host ~query) `OK
      | Route.Basemap segments ->
          serve_file cfg ~root:basemap_root ~segments ~meth ~range_header
            ~immutable:false
      | Route.Asset segments -> (
          let headers = Http.Request.headers request in
          (* Embedded first, then the directory -- so when the binary carries
             a UI, that UI is what ships, and --ui only fills the gap in a
             binary built without one. The trap: after `npm run build`, a
             stale ocaml/server/ui_dist keeps serving the OLD interface no
             matter what --ui says. Refresh it (make ui) and rebuild. *)
          let from_disk () =
            let served =
              serve_file cfg ~root:ui_root ~segments ~meth ~range_header
                ~immutable:true
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
                  serve_file cfg ~root:ui_root ~segments:[ "index.html" ] ~meth
                    ~range_header:None ~immutable:false
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
