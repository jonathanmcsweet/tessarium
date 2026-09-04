(* Request target -> what to do about it. Pure, so the routing table is
   testable without binding a socket.

   The effectful layer resolves [Asset] and [Basemap] against the filesystem;
   this module only decides which root a target belongs to and whether the
   segments are safe to open. *)

type t =
  | Health
  | Asset of string list  (** under the UI root *)
  | Basemap of string list  (** under the basemap root *)
  | Tile of { z : int; x : int; y : int }
      (** one vector tile, looked up across the tile archives *)
  | Tile_json of { floor : bool }
      (** the source metadata MapLibre needs -- zoom range and bounds,
          derived from the archive headers. Two of them: the detail the user
          downloaded, and the floor underneath it, which is cut shallow so
          that it is never asked for a tile it has not got *)
  | Api of string  (** the API sub-path, e.g. "session" *)
  | Import
      (** a map file being uploaded to be merged in. Its own route rather
          than an [Api] endpoint because the body is gigabytes of tiles
          streamed to disk, and every /api/ body is read whole into memory
          under a 4 MiB bound -- which is the right bound for every other
          endpoint and the wrong one for exactly this. *)
  | Not_found
  | Method_not_allowed

(* Under the mount prefix [p], the remaining segments, if the target is under
   it at all. *)
let strip_prefix p segments =
  match segments with
  | first :: rest when String.equal first p -> Some rest
  | _ -> None

(* /tiles/{z}/{x}/{y}.mvt. Strict: leading zeros, signs and out-of-grid
   coordinates are Not_found, so every accepted tile names exactly one id. *)
let tile_route segments =
  let plain_int s =
    if s = "" || (String.length s > 1 && s.[0] = '0') then None
    else if String.for_all (fun c -> c >= '0' && c <= '9') s then
      int_of_string_opt s
    else None
  in
  match segments with
  | [ zs; xs; ys ] -> (
      match (plain_int zs, plain_int xs, Filename.chop_suffix_opt ~suffix:".mvt" ys) with
      | Some z, Some x, Some ys when z <= Pmtiles.Tile_id.max_zoom -> (
          match plain_int ys with
          | Some y when x < 1 lsl z && y < 1 lsl z -> Some (Tile { z; x; y })
          | _ -> None)
      | _ -> None)
  | _ -> None

let of_request ~meth ~target =
  let readable = match meth with `GET | `HEAD -> true | _ -> false in
  match Url_path.resolve target with
  | None -> Not_found
  | Some segments -> (
      match strip_prefix "healthz" segments with
      | Some [] -> if readable then Health else Method_not_allowed
      | Some _ -> Not_found
      | None -> (
          match segments with
          | [ "import" ] -> if meth = `POST then Import else Method_not_allowed
          | [ "tiles.json" ] ->
              if readable then Tile_json { floor = false }
              else Method_not_allowed
          | [ "world.json" ] ->
              if readable then Tile_json { floor = true }
              else Method_not_allowed
          | _ -> (
          match strip_prefix "api" segments with
          | Some [ endpoint ] ->
              if meth = `POST then Api endpoint else Method_not_allowed
          | Some _ -> Not_found
          | None -> (
              match strip_prefix "tiles" segments with
              | Some rest -> (
                  if not readable then Method_not_allowed
                  else
                    match tile_route rest with
                    | Some t -> t
                    | None -> Not_found)
              | None -> (
                  match strip_prefix "basemap" segments with
                  | Some [] -> Not_found
                  | Some rest ->
                      if readable then Basemap rest else Method_not_allowed
                  | None ->
                      if readable then Asset segments
                      else Method_not_allowed)))))

(* The basemap endpoints are part of the UI, not the opt-in encode/decode API:
   they carry a bounding box and no key material, so they stay reachable when
   --api is off. Decided here so the gate in the effectful layer is one
   pattern match away from this comment. *)
let is_basemap_api endpoint = String.starts_with ~prefix:"basemap-" endpoint

(* A path with no extension is a client-side route -- the UI is a single-page
   app, so `/about` must return index.html rather than 404, or a reload of any
   deep link breaks. A missing `.js` is a genuine 404 and must stay one. *)
let is_spa_fallback segments =
  match List.rev segments with
  | [] -> true
  | last :: _ -> String.equal (Url_path.extension last) ""
