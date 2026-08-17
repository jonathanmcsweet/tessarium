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
