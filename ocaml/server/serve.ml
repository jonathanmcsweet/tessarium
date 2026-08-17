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

(* ------------------------------------------------------- embedded assets *)

(* The built UI, compiled into the binary. This is what makes the desktop
   target one file rather than a file plus a directory that has to travel with
   it. Empty when the UI has not been built, in which case everything falls
   through to the directory named by --ui.

   Stored gzipped and normally served that way. A client that will not accept
   gzip gets it decompressed rather than a 406: browsers all accept it, and the
   exceptions are curl and scripts, which should still work. *)
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
      match endpoint with
      | "session" -> (
          (* The only rate-limited endpoint, because it is the only expensive
             one: PBKDF2 is deliberately slow, which is what makes calling it
             without limit a way to exhaust the host. *)
          let allowed, limiter' = Rate_limit.take Rate_limit.default !limiter ~now in
          limiter := limiter';
          if not allowed then
            let wait = Rate_limit.retry_after Rate_limit.default !limiter ~now in
            respond_json cfg ~status:`Too_many_requests
              (`Assoc
                 [
                   ("error", `String "too many key derivations; slow down");
                   ("retry_after", `Int wait);
                 ])
          else
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

let parse_region json =
  match
    ( float_field "min_lon" json,
      float_field "min_lat" json,
      float_field "max_lon" json,
      float_field "max_lat" json,
      int_field "max_zoom" json )
  with
  | Some min_lon, Some min_lat, Some max_lon, Some max_lat, Some max_zoom ->
      Basemap_job.validate ~min_lon ~min_lat ~max_lon ~max_lat ~max_zoom
  | _ -> Error "missing min_lon, min_lat, max_lon, max_lat or max_zoom"

(* [body] is a thunk: status and cancel take no input, and reading a body a
   bodyless POST never declared blocks the connection until its timeout. Only
   the endpoints that need one force it. *)
let handle_basemap cfg (ops : Basemap_download.ops) ~endpoint ~body =
  let bad = error cfg ~status:`Bad_request in
  match endpoint with
  | "basemap-status" -> respond_json cfg ~status:`OK (ops.status ())
  | "basemap-cancel" ->
      let stopped = ops.cancel () in
      respond_json cfg ~status:`OK
        (`Assoc [ ("ok", `Bool true); ("stopped", `Bool stopped) ])
  | "basemap-estimate" | "basemap-download" -> (
      match Yojson.Safe.from_string (body ()) with
      | exception _ -> bad "body is not valid JSON"
      | json -> (
          match parse_region json with
          | Error e -> bad e
          | Ok req ->
              if String.equal endpoint "basemap-estimate" then
                match ops.estimate req with
                | Ok payload -> respond_json cfg ~status:`OK payload
                | Error e ->
                    (* The failure is upstream of this server -- the tile
                       source is unreachable or broken -- and the status code
                       should say so rather than blame the request. *)
                    error cfg ~status:`Bad_gateway e
              else
                match ops.start req with
                | Ok () ->
                    respond_json cfg ~status:`OK (`Assoc [ ("ok", `Bool true) ])
                | Error e -> error cfg ~status:`Conflict e))
  | _ -> error cfg ~status:`Not_found "no such endpoint"

(* ---------------------------------------------------------------- handler *)

let status_code s = Http.Status.to_int s

let handler cfg ~ui_root ~basemap_root ~sessions ~limiter ~clock ~random
    ~basemap_ops =
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
          simple
            (handle_basemap cfg basemap_ops ~endpoint
               ~body:(fun () -> Eio.Flow.read_all body))
            `OK
      | Route.Api endpoint ->
          if not cfg.api_enabled then
            simple
              (error cfg ~status:`Not_found
                 "the encode/decode API is disabled; start with --api to enable it")
              `Not_found
          else
            let body = Eio.Flow.read_all body in
            let now = Eio.Time.now clock in
            simple (handle_api cfg sessions limiter random ~endpoint ~body ~now) `OK
      | Route.Basemap segments ->
          serve_file cfg ~root:basemap_root ~segments ~meth ~range_header
            ~immutable:false
      | Route.Asset segments -> (
          let headers = Http.Request.headers request in
          (* Embedded first, then the directory. A --ui directory therefore
             overrides the built-in copy, which is what makes `npm run dev`
             against this server work without rebuilding the binary. *)
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
  in
  let callback =
    handler cfg ~ui_root ~basemap_root ~sessions ~limiter ~clock ~random
      ~basemap_ops
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
