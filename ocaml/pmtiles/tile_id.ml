(* PMTiles orders tiles along a Hilbert curve.

   The point of a Hilbert order is locality: tiles that are near each other on
   the ground are near each other in the file, so a map panning across a city
   reads a few contiguous stretches rather than scattering reads across a
   hundred gigabytes. It is also why an extract of a region comes out as a
   small number of runs.

   The tile ID is the count of all tiles at shallower zooms, plus the Hilbert
   index within this zoom. Zoom 0 is 1 tile, zoom 1 is 4, so the accumulator
   is (4^z - 1) / 3. *)

let max_zoom = 26

let tiles_before z =
  (* (4^z - 1) / 3, without overflow risk: z <= 26 keeps this under 2^53. *)
  ((1 lsl (2 * z)) - 1) / 3

(* (z, x, y) -> tile id *)
let of_zxy ~z ~x ~y =
  if z < 0 || z > max_zoom then invalid_arg "tile_id: zoom out of range";
  let n = 1 lsl z in
  if x < 0 || y < 0 || x >= n || y >= n then
    invalid_arg "tile_id: coordinate outside zoom";
  let rec go s x y d =
    if s = 0 then d
    else
      let rx = if x land s > 0 then 1 else 0 in
      let ry = if y land s > 0 then 1 else 0 in
      let d = d + (s * s * ((3 * rx) lxor ry)) in
      (* Rotate the quadrant so the curve stays continuous across it. *)
      let x, y =
        if ry = 0 then
          let x, y = if rx = 1 then (s - 1 - x, s - 1 - y) else (x, y) in
          (y, x)
        else (x, y)
      in
      go (s / 2) x y d
  in
  tiles_before z + go (n / 2) x y 0

(* tile id -> (z, x, y) *)
let to_zxy id =
  if id < 0 then invalid_arg "tile_id: negative";
  let rec find_zoom z =
    if z > max_zoom then invalid_arg "tile_id: beyond zoom 26"
    else if id < tiles_before (z + 1) then z
    else find_zoom (z + 1)
  in
  let z = find_zoom 0 in
  let rec go s t x y =
    if s >= 1 lsl z then (x, y)
    else
      let rx = 1 land (t / 2) in
      let ry = 1 land (t lxor rx) in
      let x, y =
        if ry = 0 then
          let x, y = if rx = 1 then (s - 1 - x, s - 1 - y) else (x, y) in
          (y, x)
        else (x, y)
      in
      go (s * 2) (t / 4) (x + (s * rx)) (y + (s * ry))
  in
  let x, y = go 1 (id - tiles_before z) 0 0 in
  (z, x, y)

(* ------------------------------------------------------- tiles for a bbox *)

(* Web Mercator, which is where floating point legitimately lives: this picks
   which tiles to download, not where a cell boundary falls. Nothing in the
   addressing path goes through here. *)
let clamp lo hi v = if v < lo then lo else if v > hi then hi else v

let tile_x ~z ~lon =
  let n = float_of_int (1 lsl z) in
  int_of_float (Float.floor ((lon +. 180.) /. 360. *. n))

let tile_y ~z ~lat =
  let n = float_of_int (1 lsl z) in
  let lat = clamp (-85.0511287798) 85.0511287798 lat in
  let r = lat *. Float.pi /. 180. in
  int_of_float
    (Float.floor ((1. -. Float.log (Float.tan r +. (1. /. Float.cos r)) /. Float.pi) /. 2. *. n))

(* Every tile id covering a bounding box between two zooms, ascending.

   Ascending matters: PMTiles requires directory entries in tile-id order, and
   sorting later would mean holding the whole list twice. *)
let covering ~min_zoom ~max_zoom ~min_lon ~min_lat ~max_lon ~max_lat =
  let ids = ref [] in
  for z = max_zoom downto min_zoom do
    let n = 1 lsl z in
    let last = n - 1 in
    let x0 = clamp 0 last (tile_x ~z ~lon:min_lon) in
    let x1 = clamp 0 last (tile_x ~z ~lon:max_lon) in
    (* y grows southward, so the northern edge gives the smaller index. *)
    let y0 = clamp 0 last (tile_y ~z ~lat:max_lat) in
    let y1 = clamp 0 last (tile_y ~z ~lat:min_lat) in
    for x = x1 downto x0 do
      for y = y1 downto y0 do
        ids := of_zxy ~z ~x ~y :: !ids
      done
    done
  done;
  List.sort_uniq compare !ids

(* The deepest zoom whose cumulative tile count over the box stays within
   [limit], never less than [min_zoom].

   This is the guard between "download this view" and a request that means
   forty million tiles: a viewport showing half a continent, asked for at
   street level. Planning that many ids is minutes of grinding -- during
   which a single-domain server answers nothing -- and the archive it
   describes would be tens of gigabytes. Depth follows area instead: a city
   box affords street level within the same budget that stops a continent
   at regional detail. Pure arithmetic; no tile is touched. *)
let ids_in_box ~z ~min_lon ~min_lat ~max_lon ~max_lat =
  let n = 1 lsl z in
  let last = n - 1 in
  let x0 = clamp 0 last (tile_x ~z ~lon:min_lon) in
  let x1 = clamp 0 last (tile_x ~z ~lon:max_lon) in
  let y0 = clamp 0 last (tile_y ~z ~lat:max_lat) in
  let y1 = clamp 0 last (tile_y ~z ~lat:min_lat) in
  (x1 - x0 + 1) * (y1 - y0 + 1)

let count_ids ~min_zoom ~max_zoom ~min_lon ~min_lat ~max_lon ~max_lat =
  let total = ref 0 in
  for z = min_zoom to max_zoom do
    total := !total + ids_in_box ~z ~min_lon ~min_lat ~max_lon ~max_lat
  done;
  !total

let depth_for ~min_zoom ~max_zoom ~min_lon ~min_lat ~max_lon ~max_lat ~limit =
  let count z = ids_in_box ~z ~min_lon ~min_lat ~max_lon ~max_lat in
  let rec go z total best =
    if z > max_zoom then best
    else
      let total = total + count z in
      if total > limit && z > min_zoom then best else go (z + 1) total z
  in
  go min_zoom 0 min_zoom

(* Latitude of the northern edge of tile row [y] at zoom [z] -- the inverse
   of [tile_y]. Splitting a box along the tile grid rather than in degrees is
   what keeps both halves holding similar tile counts at every latitude. *)
let lat_of_row ~z ~y =
  let n = float_of_int (1 lsl z) in
  let t = Float.pi *. (1. -. (2. *. float_of_int y /. n)) in
  Float.atan (Float.sinh t) *. 180. /. Float.pi

(* Split a box into at most [max_parts] boxes, each planning within [limit]
   ids up to [max_zoom]. Repeatedly bisects the worst offender along its
   longer tile axis. Seams land on tile edges only by luck, so neighbouring
   parts may share an edge row or column of tiles; the merge dedups shared
   ids, so overlap costs a sliver of re-planning, never correctness. None
   when [max_parts] pieces are not enough or a piece stops being divisible. *)
let split ~min_zoom ~max_zoom ~min_lon ~min_lat ~max_lon ~max_lat ~limit
    ~max_parts =
  let count (a, b, c, d) =
    count_ids ~min_zoom ~max_zoom ~min_lon:a ~min_lat:b ~max_lon:c ~max_lat:d
  in
  let bisect (a, b, c, d) =
    let z = max_zoom in
    let last = (1 lsl z) - 1 in
    let x0 = clamp 0 last (tile_x ~z ~lon:a)
    and x1 = clamp 0 last (tile_x ~z ~lon:c) in
    let y0 = clamp 0 last (tile_y ~z ~lat:d)
    and y1 = clamp 0 last (tile_y ~z ~lat:b) in
    if x1 - x0 >= y1 - y0 then
      let xm = (x0 + x1 + 1) / 2 in
      let lon = (float_of_int xm /. float_of_int (1 lsl z) *. 360.) -. 180. in
      if lon <= a || lon >= c then None
      else Some ((a, b, lon, d), (lon, b, c, d))
    else
      let ym = (y0 + y1 + 1) / 2 in
      let lat = lat_of_row ~z ~y:ym in
      if lat <= b || lat >= d then None
      else Some ((a, lat, c, d), (a, b, c, lat))
  in
  let rec go parts =
    match List.find_opt (fun box -> count box > limit) parts with
    | None -> Some parts
    | Some worst ->
        if List.length parts >= max_parts then None
        else (
          match bisect worst with
          | None -> None
          | Some (first, second) ->
              (* In place, first half before second: parts keep a stable
                 west-to-east, north-to-south order for progress display. *)
              go
                (List.concat_map
                   (fun box ->
                     if box == worst then [ first; second ] else [ box ])
                   parts))
  in
  go [ (min_lon, min_lat, max_lon, max_lat) ]

(* Which boxes a download fetches, and how deep. One box at the full ask
   when it fits [full_limit]; several when splitting affords the full ask
   within [max_parts] pieces -- how a Brazil-sized pick gets street level;
   otherwise the single box at a quick regional depth, flagged so the
   caller can say so.

   Two limits on purpose. An explicit "give me France" is ~2.3 million tile
   ids -- minutes of fetching but a plan a machine handles, so it gets
   street level in one piece. All of Brazil is ~18 million and splits into
   a handful of pieces that each fit. A near-planetary box would need more
   pieces than [max_parts] allows; pretending otherwise would grind the
   server for hours, so it falls back to a depth that plans in a couple of
   seconds, and the caller says "pick a state" instead. *)
let download_parts ~min_zoom ~requested ~min_lon ~min_lat ~max_lon ~max_lat
    ~full_limit ~quick_limit ~max_parts =
  match
    split ~min_zoom ~max_zoom:requested ~min_lon ~min_lat ~max_lon ~max_lat
      ~limit:full_limit ~max_parts
  with
  | Some parts -> (parts, requested, false)
  | None ->
      let depth =
        depth_for ~min_zoom ~max_zoom:requested ~min_lon ~min_lat ~max_lon
          ~max_lat ~limit:quick_limit
      in
      ([ (min_lon, min_lat, max_lon, max_lat) ], depth, true)
