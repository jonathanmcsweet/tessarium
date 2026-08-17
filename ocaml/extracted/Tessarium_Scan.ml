open Prims
let rec diffs_ok (l : Prims.nat Prims.list) (max : Prims.pos) : Prims.bool=
  match l with
  | [] -> true
  | uu___::[] -> true
  | a::b::tl -> ((a < b) && ((b - a) <= max)) && (diffs_ok (b :: tl) max)
