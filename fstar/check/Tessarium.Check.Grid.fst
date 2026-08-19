module Tessarium.Check.Grid

/// The grid and the end-to-end composition, as extracted, recomputed by
/// F*. The expensive leg: every point below walks the band table inside
/// the normalizer. See Tessarium.Check.Round for what these modules
/// are, and Tessarium.Check.Table for why `friend`.

module F = Tessarium.Feistel
module A = Tessarium.Api
module E = Tessarium.Check.Expected

open Tessarium.Spec
open Tessarium.Check.Round

friend Tessarium.Table.Data

(* ----------------------------------------------------------- end to end *)

let rec e2e_ok (l: list (int & int & int & int & int & int & int & int))
  : bool =
  match l with
  | [] -> true
  | (la, lo, w1, w2, w3, n, cla, clo) :: tl ->
      lat_min <= la && la <= lat_min + lat_span
      && lon_min <= lo && lo <= lon_min + lon_span
      && (let (a1, a2, a3, an) = A.encode rf ck ct la lo in
          a1 = w1 && a2 = w2 && a3 = w3 && an = n
          && (match A.decode rf ck ct (a1, a2, a3, an) with
              | Some (cla', clo') -> cla' = cla && clo' = clo
              | None -> false))
      && e2e_ok tl

let _ = assert_norm (e2e_ok E.e2e)

(* --------------------------------------------------------------- bounds *)

let _ = assert_norm (
  let (la, lo) = E.bounds_in in
  lat_min <= la && la <= lat_min + lat_span
  && lon_min <= lo && lo <= lon_min + lon_span
  && A.bounds_of_point la lo = E.bounds_out)
