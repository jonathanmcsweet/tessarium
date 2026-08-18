(* `tessarium-server` -- the self-hosted server and the desktop app, which
   are the same binary.

   The desktop story is deliberately unglamorous: serve localhost, open the
   system browser, done. No Electron, no Tauri, no webkit2gtk to match against
   whatever the distribution shipped. It also means self-hosted and desktop are
   one code path rather than two that drift. *)

module Serve = Tessarium_server.Serve
module Basemap_download = Tessarium_server.Basemap_download

let default_port = 7373

(* xdg-open is the freedesktop standard and is what every desktop environment
   on Linux routes through. Failing to open a browser is not fatal -- the URL
   is on stdout, and a headless or self-hosted run has no browser to open. *)
let open_browser proc_mgr url =
  (* $BROWSER first. It is the long-standing convention, and it is what makes
     this work inside a container or VM where there is no local browser at all:
     editors and remote-development tools set it to a helper that forwards the
     URL to wherever the human actually is. Falling straight through to
     xdg-open there opens nothing, or opens it on the wrong machine. *)
  let candidates =
    (match Sys.getenv_opt "BROWSER" with
    | Some b when String.trim b <> "" -> [ b ]
    | _ -> [])
    @ [ "xdg-open"; "gio"; "sensible-browser"; "www-browser" ]
  in
  let args exe =
    if Filename.basename exe = "gio" then [ exe; "open"; url ] else [ exe; url ]
  in
  let rec try_each = function
    | [] ->
        Logs.info (fun m ->
            m "no way to open a browser found; open %s yourself" url)
    | exe :: rest -> (
        match Eio.Process.run proc_mgr (args exe) with
        | () -> Logs.info (fun m -> m "opened via %s" (Filename.basename exe))
        | exception e ->
            Logs.debug (fun m ->
                m "%s failed: %s" exe (Printexc.to_string e));
            try_each rest)
  in
  try_each candidates

let setup_log level =
  Fmt_tty.setup_std_outputs ();
  Logs.set_level level;
  Logs.set_reporter (Logs_fmt.reporter ())

let serve port ui basemap api connect_src basemap_source basemap_assets
    budget no_open log_level =
  setup_log log_level;
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let cfg =
    {
      Serve.ui_dir = ui;
      basemap_dir = basemap;
      api_enabled = api;
      connect_src;
      basemap_source;
      basemap_assets;
      tile_budget = budget;
    }
  in
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

(* The in-app downloader's sources. Command-line configuration on purpose:
   the browser asks for a region of the world, never for a URL, so a page
   cannot point this server at an attacker's archive. *)
let basemap_source =
  let doc =
    "Where the in-app downloader reads tiles: a PMTiles URL or local path. \
     The browser never supplies this."
  in
  Arg.(
    value
    & opt string "https://demo-bucket.protomaps.com/v4.pmtiles"
    & info [ "basemap-source" ] ~docv:"URL" ~doc)

let basemap_assets =
  let doc = "The glyph and sprite tarball (.tar.gz) for the map style." in
  Arg.(
    value
    & opt string
        "https://codeload.github.com/protomaps/basemaps-assets/tar.gz/refs/heads/main"
    & info [ "basemap-assets" ] ~docv:"URL" ~doc)

let no_open =
  let doc = "Do not open a browser. Implied for self-hosted and headless use." in
  Arg.(value & flag & info [ "no-open" ] ~doc)

let tile_budget =
  let doc =
    "Planning budget as FULL,QUICK,PARTS tile-id counts. Advanced: the \
     default suits real hardware; tests shrink it to force multi-part \
     downloads against a small fixture."
  in
  (* A converter rather than an in-band parse: bad input earns cmdliner's
     usage diagnostic, not an uncaught exception, and nonpositive values are
     refused here -- downstream they silently degrade every download to the
     minimum zoom. *)
  let budget_conv =
    let parse s =
      try
        Scanf.sscanf s "%d,%d,%d%!" (fun full quick max_parts ->
            if full > 0 && quick > 0 && max_parts > 0 then
              Ok Basemap_download.{ full; quick; max_parts }
            else Error (`Msg "tile budget values must all be positive"))
      with _ -> Error (`Msg "expected FULL,QUICK,PARTS as three integers")
    in
    let print ppf (b : Basemap_download.budget) =
      Format.fprintf ppf "%d,%d,%d" b.full b.quick b.max_parts
    in
    Arg.conv ~docv:"F,Q,P" (parse, print)
  in
  Arg.(
    value
    & opt budget_conv Basemap_download.default_budget
    & info [ "tile-budget" ] ~docv:"F,Q,P" ~doc)

let cmd =
  let doc = "serve the Tessarium map on localhost" in
  let info = Cmd.info "tessarium-server" ~version:"0.1.0" ~doc in
  Cmd.v info
    Term.(
      const serve $ port $ ui $ basemap $ api $ connect_src $ basemap_source
      $ basemap_assets $ tile_budget $ no_open $ Logs_cli.level ())

let () = exit (Cmd.eval cmd)
