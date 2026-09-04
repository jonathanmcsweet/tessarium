(* The state of the one in-app basemap download, as data.

   Pure: transitions are functions from state to state, so every rule about
   what may happen when -- one download at a time, cancel only while running,
   progress never exceeding the total -- is testable with no network, no
   filesystem and no clock, which is where decisions live in this codebase. *)

(* One picked region's share of a download that may be carrying several.

   The bytes are FETCHED bytes -- what the network delivered for this region
   -- not archive bytes written. A merge copies the whole base archive
   forward, and crediting a region with the gigabyte of London already on
   disk because Tokyo was being added would read as Tokyo downloading a
   gigabyte it never asked for.

   [total_bytes] is what is known so far, not a promise. Small regions ride
   in one batch, so all their totals are settled the moment that batch is
   planned; a region large enough to be split across parts learns the rest
   of its total as later parts are planned, and [planned] is false until it
   has. A bar whose denominator can still grow must say so rather than
   quietly appearing to lose ground. *)
type region_progress = {
  label : string;
  done_bytes : int;
  total_bytes : int;
  planned : bool;
      (** every part that can add to this region has been planned, so
          [total_bytes] will not grow again *)
}

type t =
  | Idle
  | Planning
  | Fetching of {
      done_bytes : int;
      total_bytes : int;
      part : int;  (** 1-based; a single-box download is part 1 of 1 *)
      parts : int;
      regions : region_progress list;
          (** per-region breakdown, in the order the client asked for them.
              Empty when there is nothing useful to say -- a world overview
              belongs to no region, and neither does a compaction. *)
    }
  | Assets  (** tiles written; glyphs and sprites downloading *)
  | Removing of { done_bytes : int; total_bytes : int }
      (** the archive is being rewritten without one ledger entry's tiles *)
  | Compacting of { done_bytes : int; total_bytes : int }
      (** browsed tiles are being folded into the main archive *)
  | Indexing of { done_tiles : int; total_tiles : int }
      (** the archive's own labels are being read into the search index *)
  | Exporting of { done_bytes : int; total_bytes : int }
      (** one region is being written out as a file to carry elsewhere *)
  | Done of { total_bytes : int; parts : int }
  | Removed of { freed_bytes : int }
      (** a removal finished; its own terminal state so the UI can say
          "removed" rather than pretending a download completed *)
  | Exported of { file : string; bytes : int }
      (** an export finished and is sitting in the export directory. Its own
          terminal state because the UI has somewhere to send the user --
          the file -- which "done" alone could not say. *)
  | Failed of string
  | Cancelled

(* A new download may begin from any resting state. Never from a running one:
   two fibers writing one map.pmtiles is corruption with extra steps. *)
let can_start = function
  | Idle | Done _ | Removed _ | Exported _ | Failed _ | Cancelled -> true
  | Planning | Fetching _ | Assets | Removing _ | Compacting _ | Indexing _
  | Exporting _ ->
      false

let is_running = function
  | Planning | Fetching _ | Assets | Removing _ | Compacting _ | Indexing _
  | Exporting _ ->
      true
  | Idle | Done _ | Removed _ | Exported _ | Failed _ | Cancelled -> false

(* Progress is clamped rather than trusted. The copier reports raw byte
   counts; gzip framing can push the last report past the planned total, and a
   progress bar at 101% reads as a bug because it is one. *)
(* Regions are clamped exactly as the aggregate is, and for the same reason:
   the caller reports raw counters, and a row reading 3.1 / 3.0 GB reads as a
   bug because it is one. *)
let clamp_region (r : region_progress) =
  {
    r with
    done_bytes = max 0 (min r.done_bytes r.total_bytes);
    total_bytes = max 0 r.total_bytes;
  }

let progress ?(regions = []) ~done_bytes ~total_bytes ~part ~parts () =
  let parts = max 1 parts in
  Fetching
    {
      done_bytes = max 0 (min done_bytes total_bytes);
      total_bytes = max 0 total_bytes;
      part = max 1 (min part parts);
      parts;
      regions = List.map clamp_region regions;
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
  | Fetching { done_bytes; total_bytes; part; parts; regions } ->
      `Assoc
        [
          ("state", `String "fetching");
          ("done_bytes", `Int done_bytes);
          ("total_bytes", `Int total_bytes);
          ("part", `Int part);
          ("parts", `Int parts);
          ( "regions",
            `List
              (List.map
                 (fun r ->
                   `Assoc
                     [
                       ("label", `String r.label);
                       ("done_bytes", `Int r.done_bytes);
                       ("total_bytes", `Int r.total_bytes);
                       ("planned", `Bool r.planned);
                     ])
                 regions) );
        ]
  | Assets -> `Assoc [ ("state", `String "assets") ]
  | Removing { done_bytes; total_bytes } ->
      `Assoc
        [
          ("state", `String "removing");
          ("done_bytes", `Int done_bytes);
          ("total_bytes", `Int total_bytes);
        ]
  | Compacting { done_bytes; total_bytes } ->
      `Assoc
        [
          ("state", `String "compacting");
          ("done_bytes", `Int done_bytes);
          ("total_bytes", `Int total_bytes);
        ]
  | Indexing { done_tiles; total_tiles } ->
      `Assoc
        [
          ("state", `String "indexing");
          ("done_tiles", `Int done_tiles);
          ("total_tiles", `Int total_tiles);
        ]
  | Done { total_bytes; parts } ->
      `Assoc
        [
          ("state", `String "done");
          ("total_bytes", `Int total_bytes);
          ("parts", `Int parts);
        ]
  | Exporting { done_bytes; total_bytes } ->
      `Assoc
        [
          ("state", `String "exporting");
          ("done_bytes", `Int done_bytes);
          ("total_bytes", `Int total_bytes);
        ]
  | Removed { freed_bytes } ->
      `Assoc
        [ ("state", `String "removed"); ("freed_bytes", `Int freed_bytes) ]
  | Exported { file; bytes } ->
      `Assoc
        [
          ("state", `String "exported");
          ("file", `String file);
          ("bytes", `Int bytes);
        ]
  | Failed reason ->
      `Assoc [ ("state", `String "failed"); ("reason", `String reason) ]
  | Cancelled -> `Assoc [ ("state", `String "cancelled") ]
