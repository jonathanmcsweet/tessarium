(* `tessarium-basemap` -- fetch a region of a PMTiles archive for offline use.

   The archive is read where it lives, over HTTP range requests, and only the
   tiles covering the requested box are pulled down. A city at zoom 15 is tens
   of megabytes out of a planet build of about a hundred gigabytes. *)

let ( let* ) = Result.bind

(* ------------------------------------------------------------ byte sources *)

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

(* ------------------------------------------------------------------ output *)

let human bytes =
  let units = [| "B"; "KB"; "MB"; "GB" |] in
  let rec go v i =
    if v >= 1024. && i < Array.length units - 1 then go (v /. 1024.) (i + 1)
    else Printf.sprintf "%.1f %s" v units.(i)
  in
  go (float_of_int bytes) 0

let parse_bbox s =
  match String.split_on_char ',' s |> List.map String.trim with
  | [ a; b; c; d ] -> (
      match List.map float_of_string_opt [ a; b; c; d ] with
      | [ Some min_lon; Some min_lat; Some max_lon; Some max_lat ] ->
          if min_lon >= max_lon || min_lat >= max_lat then
            Error "bbox must be min_lon,min_lat,max_lon,max_lat"
          else Ok (min_lon, min_lat, max_lon, max_lat)
      | _ -> Error "bbox values must be numbers")
  | _ -> Error "bbox must have four comma-separated values"

let run source_desc url output bbox max_zoom min_zoom =
  let* min_lon, min_lat, max_lon, max_lat = parse_bbox bbox in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let fs = Eio.Stdenv.fs env in

  let src =
    if String.length url > 4 && String.sub url 0 4 = "http" then begin
      (* TLS needs a seeded RNG, and nothing else in this binary does, so it is
         set up here rather than at startup. *)
      Mirage_crypto_rng_unix.use_default ();
      let https =
        (* Trust anchors from Mozilla's NSS bundle, compiled in rather than
           read from the host: the desktop build is one binary and cannot
           assume a system certificate store exists where it lands. *)
        let authenticator = Result.get_ok (Ca_certs_nss.authenticator ()) in
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
      let client = Cohttp_eio.Client.make ~https (Eio.Stdenv.net env) in
      (* Eio resolves a portless URI by service name, which needs an
         /etc/services entry that a minimal container image does not
         necessarily have. Naming the port avoids depending on one. *)
      let uri = Uri.of_string url in
      let uri =
        match Uri.port uri with
        | Some _ -> uri
        | None ->
            Uri.with_port uri
              (Some (if Uri.scheme uri = Some "https" then 443 else 80))
      in
      http_source ~client ~sw ~uri
    end
    else file_source (Eio.Path.open_in ~sw Eio.Path.(fs / url))
  in

  Printf.printf "reading %s\n%!" source_desc;
  let archive = Pmtiles.Archive.open_ src in
  let h = archive.Pmtiles.Archive.header in
  Printf.printf "  zooms %d-%d, %d tiles, %s\n%!" h.Pmtiles.Header.min_zoom
    h.Pmtiles.Header.max_zoom h.Pmtiles.Header.addressed_tiles
    (human h.Pmtiles.Header.data_length);

  let max_zoom = min max_zoom h.Pmtiles.Header.max_zoom in
  let min_zoom = max min_zoom h.Pmtiles.Header.min_zoom in

  Printf.printf "planning %g,%g..%g,%g at zooms %d-%d\n%!" min_lon min_lat
    max_lon max_lat min_zoom max_zoom;
  let plan =
    Pmtiles.Extract.plan archive ~min_zoom ~max_zoom ~min_lon ~min_lat ~max_lon
      ~max_lat
  in
  let total = Pmtiles.Extract.planned_bytes plan in
  Printf.printf "  %d tiles, %d distinct, %s to fetch\n%!"
    (Array.length plan.Pmtiles.Extract.tiles)
    (Array.length plan.Pmtiles.Extract.blobs)
    (human total);

  if Array.length plan.Pmtiles.Extract.tiles = 0 then
    Error "no tiles in that box -- check the order: min_lon,min_lat,max_lon,max_lat"
  else begin
    Eio.Path.with_open_out ~create:(`Or_truncate 0o644)
      Eio.Path.(fs / output)
    @@ fun out ->
    let written = ref 0 in
    let append s = Eio.Flow.copy_string s out in
    let copy ~offset ~length =
      Eio.Flow.copy_string (src.Pmtiles.Archive.read ~offset ~length) out;
      written := !written + length;
      (* Progress on one line. A region fetch is minutes, and silence for
         minutes reads as a hang. *)
      Printf.printf "\r  %s / %s (%.0f%%)%!" (human !written) (human total)
        (100. *. float_of_int !written /. float_of_int (max 1 total))
    in
    let header =
      Pmtiles.Extract.write plan h ~min_zoom ~max_zoom ~min_lon ~min_lat
        ~max_lon ~max_lat ~append ~copy
    in
    Printf.printf "\nwrote %s (%s)\n" output
      (human (header.Pmtiles.Header.data_offset + header.Pmtiles.Header.data_length));
    Ok ()
  end

(* -------------------------------------------------------------------- cli *)

open Cmdliner

let url =
  let doc = "Source PMTiles archive: an https:// URL or a local path." in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"SOURCE" ~doc)

let output =
  let doc = "Where to write the extract." in
  Arg.(value & opt string "basemap/map.pmtiles" & info [ "o"; "out" ] ~docv:"FILE" ~doc)

let bbox =
  let doc = "Region as min_lon,min_lat,max_lon,max_lat." in
  Arg.(required & opt (some string) None & info [ "bbox" ] ~docv:"BBOX" ~doc)

let max_zoom =
  let doc =
    "Deepest zoom to fetch. Vector tiles overzoom, so 15 still renders \
     crisply at 20 and beyond; each extra level is roughly four times the \
     bytes."
  in
  Arg.(value & opt int 15 & info [ "max-zoom" ] ~docv:"Z" ~doc)

let min_zoom =
  let doc = "Shallowest zoom to fetch." in
  Arg.(value & opt int 0 & info [ "min-zoom" ] ~docv:"Z" ~doc)

let cmd =
  let doc = "fetch a region of a PMTiles basemap for offline use" in
  let info = Cmd.info "tessarium-basemap" ~version:"0.1.0" ~doc in
  Cmd.v info
    Term.(
      const (fun url out bbox maxz minz ->
          match run url url out bbox maxz minz with
          | Ok () -> 0
          | Error e ->
              prerr_endline ("error: " ^ e);
              1)
      $ url $ output $ bbox $ max_zoom $ min_zoom)

let () = exit (Cmd.eval' cmd)
