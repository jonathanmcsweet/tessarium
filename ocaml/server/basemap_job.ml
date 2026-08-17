(* The state of the one in-app basemap download, as data.

   Pure: transitions are functions from state to state, so every rule about
   what may happen when -- one download at a time, cancel only while running,
   progress never exceeding the total -- is testable with no network, no
   filesystem and no clock, which is where decisions live in this codebase. *)

type t =
  | Idle
  | Planning
  | Fetching of { done_bytes : int; total_bytes : int }
  | Assets  (** tiles written; glyphs and sprites downloading *)
  | Done of { total_bytes : int }
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
let progress ~done_bytes ~total_bytes =
  Fetching
    {
      done_bytes = max 0 (min done_bytes total_bytes);
      total_bytes = max 0 total_bytes;
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
}

let validate ~min_lon ~min_lat ~max_lon ~max_lat ~max_zoom =
  let finite v = Float.is_finite v in
  if not (finite min_lon && finite min_lat && finite max_lon && finite max_lat)
  then Error "bounds must be numbers"
  else if min_lon >= max_lon || min_lat >= max_lat then
    Error "bounds must be min_lon,min_lat,max_lon,max_lat with min < max"
  else if min_lat < -90. || max_lat > 90. || min_lon < -180. || max_lon > 180.
  then Error "bounds must be within -180..180 and -90..90"
  else if max_zoom < 0 || max_zoom > 15 then
    Error "max_zoom must be between 0 and 15"
  else Ok { min_lon; min_lat; max_lon; max_lat; max_zoom }

let to_json = function
  | Idle -> `Assoc [ ("state", `String "idle") ]
  | Planning -> `Assoc [ ("state", `String "planning") ]
  | Fetching { done_bytes; total_bytes } ->
      `Assoc
        [
          ("state", `String "fetching");
          ("done_bytes", `Int done_bytes);
          ("total_bytes", `Int total_bytes);
        ]
  | Assets -> `Assoc [ ("state", `String "assets") ]
  | Done { total_bytes } ->
      `Assoc [ ("state", `String "done"); ("total_bytes", `Int total_bytes) ]
  | Failed reason ->
      `Assoc [ ("state", `String "failed"); ("reason", `String reason) ]
  | Cancelled -> `Assoc [ ("state", `String "cancelled") ]
