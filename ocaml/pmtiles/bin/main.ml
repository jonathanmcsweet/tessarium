(* `tessarium-basemap` -- fetch a region of a PMTiles archive for offline use.

   The archive is read where it lives, over HTTP range requests, and only the
   tiles covering the requested box are pulled down. A city at zoom 15 is tens
   of megabytes out of a planet build of about a hundred gigabytes. *)

let ( let* ) = Result.bind

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

  let net = Eio.Stdenv.net env in
  let resolved = Pmtiles_source.resolve ~sw ~net url in
  let src = Pmtiles_source.open_url ~sw ~fs ~net resolved in

  if resolved <> url then Printf.printf "%s is %s\n%!" source_desc resolved;
  Printf.printf "reading %s\n%!" resolved;
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
    (* Written beside the target and renamed at the end, never in place. An
       interrupted fetch -- Ctrl-C, a dropped connection, a full disk --
       otherwise leaves a file whose header and directories are complete and
       whose tile data stops early. Every lookup in it succeeds and half the
       reads fail, which is indistinguishable from an archive that simply
       does not hold those tiles. The server stands the map on the deepest
       zoom an archive covers the whole planet at, so such a file claims a
       floor it cannot draw -- the exact failure the floor exists to
       prevent. A rename is atomic; a partial write is left as .part. *)
    let part = output ^ ".part" in
    let header =
      Eio.Path.with_open_out ~create:(`Or_truncate 0o644)
        Eio.Path.(fs / part)
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
      Pmtiles.Extract.write plan h ~min_zoom ~max_zoom ~min_lon ~min_lat
        ~max_lon ~max_lat ~append ~copy
    in
    (* After the close, not inside it: renaming an open file succeeds and
       would publish whatever had reached the kernel so far. *)
    Eio.Path.rename Eio.Path.(fs / part) Eio.Path.(fs / output);
    Printf.printf "\nwrote %s (%s)\n" output
      (human (header.Pmtiles.Header.data_offset + header.Pmtiles.Header.data_length));
    Ok ()
  end

(* -------------------------------------------------------------------- cli *)

open Cmdliner

let url =
  let doc =
    "Source PMTiles archive: an https:// URL, a local path, or 'latest' for \
     the newest Protomaps daily planet build."
  in
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
