module Tessarium.Check.Table

/// The band table and the module constants, as extracted, recomputed by
/// F*. See Tessarium.Check.Round for what these modules are.

module L = FStar.List.Tot
module T = Tessarium.Table
module D = Tessarium.Table.Data
module E = Tessarium.Check.Expected

open Tessarium.Spec

/// `Tessarium.Table.Data` hides its 4097 literals behind an interface
/// so no SMT query downstream ever swallows them. This module must
/// EVALUATE them, which is exactly what `friend` grants: the
/// implementation becomes visible here -- and only here -- while every
/// chunk keeps its `opaque_to_smt`, so the solver stays protected even
/// in this module. Without this, the table is an opaque `val` and every
/// assertion below is a stuck term, not a comparison.
friend Tessarium.Table.Data

(* ------------------------------------------------------------ constants *)

let _ = assert_norm (T.rows = E.rows)
let _ = assert_norm (T.bands = E.bands)
let _ = assert_norm (T.rows_per_band = E.rows_per_band)
let _ = assert_norm (T.total_cells = E.total_cells)
let _ = assert_norm (T.max_col_count = E.max_col_count)
let _ = assert_norm (T.grid_version = E.grid_version)

(* ------------------------------------------------------------ the table *)

/// All 4097 cumulative counts at once. Two thirds of the extracted lines
/// are this table, and a single mangled digit moves a band seam.
///
/// Pointwise, not `==` on the lists: the proved table is `list nat`, the
/// expected literal is `list int`, and F*'s type parameters are invariant
/// -- there is no widening one list to the other's type. Elements widen
/// fine, and elementwise is what "the same table" means anyway.
let rec table_ok (a: list nat) (b: list int) : Tot bool (decreases a) =
  match a, b with
  | [], [] -> true
  | x :: a', y :: b' -> x = y && table_ok a' b'
  | _, _ -> false

let _ = assert_norm (table_ok D.cumcols_list E.cumcols)

