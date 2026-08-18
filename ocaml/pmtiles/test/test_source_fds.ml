(* The HTTP byte source must not hold a socket per read.

   Each range request opens its own connection, and a connection scoped to
   the download's switch stays open until the whole download ends -- so a
   6 GB country, at one request per megabyte window, held ~6,400 sockets
   and died at the default 4,096-fd limit at about 86% ("Too many open
   files", looking up the tile host). France, live, was the failing case.

   This drives the real [Pmtiles_source.http_source] against a loopback
   server for 80 window-missing reads and counts this process's open file
   descriptors before and after: leak-free means flat, and the pre-fix code
   fails with ~80 extra fds. *)

let fd_count () = Array.length (Sys.readdir "/proc/self/fd")

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  (* Answers every request with exactly the bytes its Range asked for. *)
  let callback _conn (request : Http.Request.t) _body =
    let length =
      match Http.Header.get (Http.Request.headers request) "range" with
      | Some r -> (
          try Scanf.sscanf r "bytes=%d-%d" (fun a b -> b - a + 1)
          with _ -> 16)
      | None -> 16
    in
    let body = String.make length 'x' in
    let headers =
      Http.Header.of_list
        [ ("content-length", string_of_int (String.length body)) ]
    in
    `Response
      (Cohttp_eio.Server.respond ~headers ~status:`Partial_content
         ~body:(Cohttp_eio.Body.of_string body)
         ())
  in
  let server = Cohttp_eio.Server.make_response_action ~callback () in
  let socket =
    Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | _ -> assert false
  in
  (* A daemon, so the switch can end while the server still listens. *)
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));

  let failures = ref 0 in
  let check name ok =
    if not ok then begin
      incr failures;
      Printf.printf "  FAIL  %s\n" name
    end
  in
  Eio.Switch.run (fun dsw ->
      let src =
        Pmtiles_source.open_url ~sw:dsw ~fs:(Eio.Stdenv.fs env) ~net
          (Printf.sprintf "http://127.0.0.1:%d/planet.pmtiles" port)
      in
      let before = fd_count () in
      (* Each read lands a megabyte past the last, so the readahead window
         never serves it and every read is a real request -- the giant
         download's access pattern in miniature. *)
      for i = 0 to 79 do
        ignore (src.Pmtiles.Archive.read ~offset:(i * (1 lsl 20)) ~length:8)
      done;
      let after = fd_count () in
      check
        (Printf.sprintf
           "80 range requests hold no sockets (%d fds before, %d after)"
           before after)
        (after - before < 10));
  Printf.printf "\n%s\n"
    (if !failures > 0 then "source leaks connections"
     else "source connections closed");
  if !failures > 0 then exit 1
