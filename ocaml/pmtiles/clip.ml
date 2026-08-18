(* Point-in-polygon and box-vs-polygon tests for tile clipping.

   Floats are fine here for the same reason as [Tile_id]: this decides which
   map tiles a download fetches and never touches an address. A borderline
   tile misjudged by a rounding error is a tile more or fewer at a coastline,
   not a wrong answer.

   Rings are treated even-odd, so a list of disjoint outer rings is their
   union -- which is what a country's multipolygon is. Holes are deliberately
   not modelled: treating South Africa as including the Lesotho-shaped hole
   downloads a sliver more than the border says, and a download that
   includes slightly too much is harmless where one that misses an enclave
   would not be. *)

type t = { rings : (float * float) array array }

let of_rings rings = { rings }

(* Even-odd ray cast, rightward from [p]. The half-open comparison on the
   segment's y-interval is what keeps a ray through a shared vertex from
   counting the crossing twice. *)
let point_inside t (x, y) =
  let inside = ref false in
  Array.iter
    (fun ring ->
      let n = Array.length ring in
      for i = 0 to n - 1 do
        let x1, y1 = ring.(i) in
        let x2, y2 = ring.((i + 1) mod n) in
        if y1 > y <> (y2 > y) then begin
          let cross = ((x2 -. x1) *. (y -. y1) /. (y2 -. y1)) +. x1 in
          if x < cross then inside := not !inside
        end
      done)
    t.rings;
  !inside

(* Whether segment (a,b) intersects the axis-aligned box, borders included.
   Liang-Barsky in boolean form: shrink the parameter interval by each of the
   four half-planes and see whether anything survives. *)
let segment_meets_box (ax, ay) (bx, by) ~min_x ~min_y ~max_x ~max_y =
  let dx = bx -. ax and dy = by -. ay in
  let t0 = ref 0. and t1 = ref 1. and ok = ref true in
  let clip p q =
    if p = 0. then begin if q < 0. then ok := false end
    else
      let r = q /. p in
      if p < 0. then begin if r > !t1 then ok := false else if r > !t0 then t0 := r end
      else if r < !t0 then ok := false
      else if r < !t1 then t1 := r
  in
  clip (-.dx) (ax -. min_x);
  clip dx (max_x -. ax);
  clip (-.dy) (ay -. min_y);
  clip dy (max_y -. ay);
  !ok

type relation = Outside | Inside | Boundary

(* How a box relates to the polygon: [Inside] means wholly within, so every
   sub-box is too and no descendant needs another test; [Outside] means no
   overlap at all, so the whole subtree can be pruned; [Boundary] means the
   border passes through. The box edges count as touching. *)
let classify t ~min_x ~min_y ~max_x ~max_y =
  let edge_meets =
    Array.exists
      (fun ring ->
        let n = Array.length ring in
        let hit = ref false in
        for i = 0 to n - 1 do
          if
            (not !hit)
            && segment_meets_box ring.(i) ring.((i + 1) mod n) ~min_x ~min_y
                 ~max_x ~max_y
          then hit := true
        done;
        !hit)
      t.rings
  in
  if edge_meets then Boundary
  else if
    (* No border crosses the box: it is wholly inside or wholly outside,
       and any interior point says which. *)
    point_inside t ((min_x +. max_x) /. 2., (min_y +. max_y) /. 2.)
  then Inside
  else Outside
