(* `tessarium-server` -- the self-hosted server and the desktop app, which
   are the same binary.

   The desktop story is deliberately unglamorous: serve localhost, open the
   system browser, done. No Electron, no Tauri, no webkit2gtk to match against
   whatever the distribution shipped. It also means self-hosted and desktop are
   one code path rather than two that drift. *)

module Serve = Tessarium_server.Serve

let default_port = 7373

(* xdg-open is the freedesktop standard and is what every desktop environment
   on Linux routes through. Failing to open a browser is not fatal -- the URL
   is on stdout, and a headless or self-hosted run has no browser to open. *)
let open_browser proc_mgr url =
  let candidates = [ "xdg-open"; "gio"; "sensible-browser"; "www-browser" ] in
  let args = function "gio" -> [ "gio"; "open"; url ] | exe -> [ exe; url ] in
  let rec try_each = function
    | [] ->
        Logs.info (fun m -> m "no browser opener found; open the URL yourself")
    | exe :: rest -> (
        match Eio.Process.run proc_mgr (args exe) with
        | () -> ()
        | exception _ -> try_each rest)
  in
  try_each candidates

let setup_log level =
  Fmt_tty.setup_std_outputs ();
  Logs.set_level level;
  Logs.set_reporter (Logs_fmt.reporter ())

let serve port ui basemap api connect_src no_open log_level =
  setup_log log_level;
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let cfg = { Serve.ui_dir = ui; basemap_dir = basemap; api_enabled = api; connect_src } in
  let url = Printf.sprintf "http://127.0.0.1:%d/" port in
  if api then
    Logs.warn (fun m ->
        m
          "the encode/decode API is ENABLED: seed phrases sent to it cross the \
           network and are held in memory. The UI never uses it.");
  Logs.app (fun m -> m "tessarium serving %s" url);
  Logs.app (fun m -> m "  ui      %s" ui);
  Logs.app (fun m -> m "  basemap %s" basemap);
  if not no_open then
    Eio.Fiber.fork ~sw (fun () -> open_browser (Eio.Stdenv.process_mgr env) url);
  Serve.run env ~sw ~port cfg

open Cmdliner

let port =
  let doc = "Port to listen on. Loopback only; this never binds a public interface." in
  Arg.(value & opt int default_port & info [ "p"; "port" ] ~docv:"PORT" ~doc)

let ui =
  let doc = "Directory holding the built web UI." in
  Arg.(value & opt string "ui/dist" & info [ "ui" ] ~docv:"DIR" ~doc)

let basemap =
  let doc = "Directory holding .pmtiles basemaps and the map style." in
  Arg.(value & opt string "basemap" & info [ "basemap" ] ~docv:"DIR" ~doc)

let api =
  let doc =
    "Enable the encode/decode HTTP API. OFF by default. Enabling it means a \
     seed phrase is sent to this process; the UI does not use it and derives \
     keys in the browser."
  in
  Arg.(value & flag & info [ "api" ] ~doc)

let connect_src =
  let doc =
    "Extra origin the page may connect to, for a remotely hosted basemap. \
     Repeatable. The default Content-Security-Policy allows none, which is \
     what stops a compromised dependency from exfiltrating a seed phrase."
  in
  Arg.(value & opt_all string [] & info [ "allow-origin" ] ~docv:"ORIGIN" ~doc)

let no_open =
  let doc = "Do not open a browser. Implied for self-hosted and headless use." in
  Arg.(value & flag & info [ "no-open" ] ~doc)

let cmd =
  let doc = "serve the Tessarium map on localhost" in
  let info = Cmd.info "tessarium-server" ~version:"0.1.0" ~doc in
  Cmd.v info
    Term.(
      const serve $ port $ ui $ basemap $ api $ connect_src $ no_open
      $ Logs_cli.level ())

let () = exit (Cmd.eval cmd)
