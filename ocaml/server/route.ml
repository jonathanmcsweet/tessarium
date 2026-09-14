(* Request target -> what to do about it. Pure, so the routing table is
   testable without a socket.

   This module picks which root a target belongs to and whether its segments
   are safe to open. The effectful layer does the opening. *)

type t =
  | Health
  | Asset of string list  (** under the UI root *)
  | Basemap of string list  (** under the basemap root *)
  | Tile of {
      z : int;
      x : int;
      y : int;
    }  (** one vector tile, looked up across the tile archives *)
  | Tile_json of { floor : bool }
      (** the source metadata MapLibre needs -- zoom range and bounds, read from
          the archive headers. Two of them: the detail the user downloaded, and
          the shallow floor underneath it, cut so it is never asked for a tile
          it does not have *)
  | Api of string  (** the API sub-path, e.g. "session" *)
  | Import
      (** a map file uploaded to be merged in. Not an [Api] endpoint: the body
          is gigabytes of tiles streamed to disk, and every /api/ body is read
          into memory under a 4 MiB bound *)
  | Not_found
  | Method_not_allowed

(* /tiles/{z}/{x}/{y}.mvt. Strict on purpose: leading zeros, signs and
   coordinates off the grid are Not_found, so an accepted path names exactly
   one tile id. *)
let tile_route segments =
  let plain_int s =
    if s = "" || (String.length s > 1 && s.[0] = '0') then None
    else if String.for_all (fun c -> c >= '0' && c <= '9') s then
      int_of_string_opt s
    else None
  in
  match segments with
  | [ zs; xs; ys ] -> (
      match
        (plain_int zs, plain_int xs, Filename.chop_suffix_opt ~suffix:".mvt" ys)
      with
      | Some z, Some x, Some ys when z <= Pmtiles.Tile_id.max_zoom -> (
          match plain_int ys with
          | Some y when x < 1 lsl z && y < 1 lsl z -> Some (Tile { z; x; y })
          | _ -> None)
      | _ -> None)
  | _ -> None

let of_request ~meth ~target =
  let readable = match meth with `GET | `HEAD -> true | _ -> false in
  let read t = if readable then t else Method_not_allowed in
  match Url_path.resolve target with
  | None -> Not_found
  | Some segments -> (
      match segments with
      | [ "healthz" ] -> read Health
      | "healthz" :: _ -> Not_found
      | [ "import" ] -> if meth = `POST then Import else Method_not_allowed
      | [ "tiles.json" ] -> read (Tile_json { floor = false })
      | [ "world.json" ] -> read (Tile_json { floor = true })
      | [ "api"; endpoint ] ->
          if meth = `POST then Api endpoint else Method_not_allowed
      | "api" :: _ -> Not_found
      | "tiles" :: rest ->
          if not readable then Method_not_allowed
          else Option.value ~default:Not_found (tile_route rest)
      | [ "basemap" ] -> Not_found
      | "basemap" :: rest -> read (Basemap rest)
      | _ -> read (Asset segments))

(* The basemap endpoints belong to the UI, not to the opt-in encode/decode
   API: they carry a bounding box and no key material, so they stay reachable
   with --api off. *)
let is_basemap_api endpoint = String.starts_with ~prefix:"basemap-" endpoint

(* A path with no extension is a client-side route. The UI is a single-page
   app, so `/about` must return index.html or reloading a deep link breaks. A
   missing `.js` is a real 404 and stays one. *)
let is_spa_fallback segments =
  match List.rev segments with
  | [] -> true
  | last :: _ -> String.equal (Url_path.extension last) ""
