(* The state of the one in-app basemap download, as data.

   Pure: transitions are functions from state to state, so every rule about
   what may happen when -- one download at a time, cancel only while running,
   progress never exceeding the total -- is testable with no network, no
   filesystem and no clock, which is where decisions live in this codebase. *)

type t =
  | Idle
  | Planning
  | Fetching of {
      done_bytes : int;
      total_bytes : int;
      part : int;  (** 1-based; a single-box download is part 1 of 1 *)
      parts : int;
    }
  | Assets  (** tiles written; glyphs and sprites downloading *)
  | Done of { total_bytes : int; parts : int }
  | Failed of string
  | Cancelled

(* A new download may begin from any resting state. Never from a running one:
   two fibers writing one map.pmtiles is corruption with extra steps. *)
let can_start = function
  | Idle | Done _ | Failed _ | Cancelled -> true
  | Planning | Fetching _ | Assets -> false

let is_running = function
  | Planning | Fetching _ | Assets -> true
  | Idle | Done _ | Failed _ | Cancelled -> false

(* Progress is clamped rather than trusted. The copier reports raw byte
   counts; gzip framing can push the last report past the planned total, and a
   progress bar at 101% reads as a bug because it is one. *)
let progress ~done_bytes ~total_bytes ~part ~parts =
  let parts = max 1 parts in
  Fetching
    {
      done_bytes = max 0 (min done_bytes total_bytes);
      total_bytes = max 0 total_bytes;
      part = max 1 (min part parts);
      parts;
    }

(* The request the UI sends, validated. Server-side, because the server does
   the fetching: a malformed box must die here, not 40,000 range requests
   later. *)
type request = {
  min_lon : float;
  min_lat : float;
  max_lon : float;
  max_lat : float;
  max_zoom : int;
  (* Outer rings of the region's polygon, when the picker knows one: the
     download is clipped to it, so a country stops at its border instead of
     its bounding box. Optional -- a viewport is honestly a box. *)
  polygon : (float * float) array array option;
}

(* Bounded, because the server walks every ring segment per quadtree node:
   a pathological polygon must die at the door, not in the planner. The
   catalogue's simplified countries sit far under both caps. *)
let max_polygon_rings = 64
let max_polygon_points = 2048

let valid_polygon = function
  | None -> true
  | Some rings ->
      Array.length rings >= 1
      && Array.length rings <= max_polygon_rings
      && Array.fold_left (fun acc r -> acc + Array.length r) 0 rings
         <= max_polygon_points
      && Array.for_all
           (fun ring ->
             Array.length ring >= 3
             && Array.for_all
                  (fun (lon, lat) ->
                    Float.is_finite lon && Float.is_finite lat
                    && lon >= -180. && lon <= 180. && lat >= -90. && lat <= 90.)
                  ring)
           rings

let validate ?polygon ~min_lon ~min_lat ~max_lon ~max_lat ~max_zoom () =
  let finite v = Float.is_finite v in
  if not (finite min_lon && finite min_lat && finite max_lon && finite max_lat)
  then Error "bounds must be numbers"
  else if min_lon >= max_lon || min_lat >= max_lat then
    Error "bounds must be min_lon,min_lat,max_lon,max_lat with min < max"
  else if min_lat < -90. || max_lat > 90. || min_lon < -180. || max_lon > 180.
  then Error "bounds must be within -180..180 and -90..90"
  else if max_zoom < 0 || max_zoom > 15 then
    Error "max_zoom must be between 0 and 15"
  else if not (valid_polygon polygon) then
    Error "polygon must be 1..64 rings of 3+ in-range points, 2048 total"
  else Ok { min_lon; min_lat; max_lon; max_lat; max_zoom; polygon }

let to_json = function
  | Idle -> `Assoc [ ("state", `String "idle") ]
  | Planning -> `Assoc [ ("state", `String "planning") ]
  | Fetching { done_bytes; total_bytes; part; parts } ->
      `Assoc
        [
          ("state", `String "fetching");
          ("done_bytes", `Int done_bytes);
          ("total_bytes", `Int total_bytes);
          ("part", `Int part);
          ("parts", `Int parts);
        ]
  | Assets -> `Assoc [ ("state", `String "assets") ]
  | Done { total_bytes; parts } ->
      `Assoc
        [
          ("state", `String "done");
          ("total_bytes", `Int total_bytes);
          ("parts", `Int parts);
        ]
  | Failed reason ->
      `Assoc [ ("state", `String "failed"); ("reason", `String reason) ]
  | Cancelled -> `Assoc [ ("state", `String "cancelled") ]
