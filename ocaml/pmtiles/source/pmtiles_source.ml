(* Byte sources for PMTiles archives.

   The archive reader takes an injected [read] function; these are the two
   implementations. Shared by the CLI and the server's in-app downloader, so
   there is one piece of code that knows how to speak Range. *)

let file_source path =
  {
    Pmtiles.Archive.read =
      (fun ~offset ~length ->
        let buf = Cstruct.create length in
        let got =
          Eio.File.pread path ~file_offset:(Optint.Int63.of_int offset) [ buf ]
        in
        Cstruct.to_string (Cstruct.sub buf 0 got));
  }

(* Range requests, with a small amount of coalescing left to the caller: this
   issues exactly the reads it is asked for, and the extract planner is what
   keeps that number sane by resolving directories before tiles. *)
let http_source ~client ~sw ~uri =
  let fetch ~offset ~length =
    let headers =
      Http.Header.of_list
        [
          ("range", Printf.sprintf "bytes=%d-%d" offset (offset + length - 1));
          ("user-agent", "tessarium-basemap/0.1");
        ]
    in
    let response, body = Cohttp_eio.Client.get ~headers ~sw client uri in
    let status = Http.Response.status response in
    match status with
    | `Partial_content | `OK ->
        let data = Eio.Flow.read_all body in
        (* A server that ignores Range hands back the whole archive. Truncating
           silently would produce a corrupt extract; this is a hundred
           gigabytes arriving where sixteen kilobytes were asked for. *)
        if String.length data > length then
          failwith
            (Printf.sprintf
               "server ignored Range: asked for %d bytes, got %d. It must \
                support byte ranges."
               length (String.length data))
        else data
    | s ->
        failwith
          (Printf.sprintf "HTTP %d fetching bytes %d-%d"
             (Http.Status.to_int s) offset (offset + length - 1))
  in
  { Pmtiles.Archive.read = (fun ~offset ~length -> fetch ~offset ~length) }

(* TLS needs a seeded RNG and trust anchors. The anchors come from Mozilla's
   NSS bundle, compiled in rather than read from the host: the desktop build
   is one binary and cannot assume a system certificate store exists where it
   lands. *)
let https_client net =
  Mirage_crypto_rng_unix.use_default ();
  let authenticator = Result.get_ok (Ca_certs_nss.authenticator ()) in
  let https =
    Some
      (fun uri raw ->
        let host =
          Uri.host uri
          |> Option.map (fun h ->
                 Domain_name.of_string_exn h |> Domain_name.host_exn)
        in
        Tls_eio.client_of_flow
          (Result.get_ok (Tls.Config.client ~authenticator ()))
          ?host raw)
  in
  Cohttp_eio.Client.make ~https net

(* Eio resolves a portless URI by service name, which needs an /etc/services
   entry that a minimal container image does not necessarily have. Naming the
   port avoids depending on one. *)
let with_default_port uri =
  match Uri.port uri with
  | Some _ -> uri
  | None ->
      Uri.with_port uri
        (Some (if Uri.scheme uri = Some "https" then 443 else 80))

let is_url s = String.length s > 4 && String.sub s 0 4 = "http"

(* One fetched window serves many reads. The reads an extract makes are
   small and mostly ascending -- header, directories, then clustered tile
   blobs -- and over HTTPS each read is otherwise its own connection and its
   own TLS handshake, which is what made a city download take thousands of
   round trips. A miss simply fetches a fresh window at the asked offset;
   nothing is ever refetched byte by byte. *)
let with_readahead ?(window = 1 lsl 20) (src : Pmtiles.Archive.source) =
  let cache = ref ("", 0) in
  {
    Pmtiles.Archive.read =
      (fun ~offset ~length ->
        let data, start = !cache in
        if offset >= start && offset + length <= start + String.length data
        then String.sub data (offset - start) length
        else begin
          let got =
            src.Pmtiles.Archive.read ~offset ~length:(max length window)
          in
          cache := (got, offset);
          (* The archive may end inside the window; hand back what exists,
             exactly as the underlying source would. *)
          String.sub got 0 (min length (String.length got))
        end);
  }

(* URL or path in, source out. [sw] scopes the connections; [fs] and [net]
   come from the caller's environment. *)
let open_url ~sw ~fs ~net url =
  if is_url url then
    let client = https_client net in
    with_readahead
      (http_source ~client ~sw ~uri:(with_default_port (Uri.of_string url)))
  else file_source (Eio.Path.open_in ~sw Eio.Path.(fs / url))

(* A GET of a whole body, for the glyph/sprite tarball, which is one download
   rather than many ranges. *)
let get_body ~sw ~net url =
  let client = https_client net in
  let uri = with_default_port (Uri.of_string url) in
  let response, body = Cohttp_eio.Client.get ~sw client uri in
  match Http.Response.status response with
  | `OK -> Eio.Flow.read_all body
  | s -> failwith (Printf.sprintf "HTTP %d fetching %s" (Http.Status.to_int s) url)
