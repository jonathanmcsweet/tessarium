module Tessarium.Table

/// The band table as the grid consumes it.
///
/// One cumulative table underneath, two derived views on top: `col_counts b`
/// is a difference and `offsets b` is a product. Band-offset contiguity is
/// therefore an algebraic identity rather than a fact about data, which is why
/// nothing here has to inspect 4096 literals.

module L  = FStar.List.Tot
module IA = FStar.ImmutableArray
module M  = FStar.Math.Lemmas
module D  = Tessarium.Table.Data

open Tessarium.Scan
open Tessarium.Spec

let rows          : pos    = D.rows
let bands         : pos    = D.bands
let rows_per_band : pos    = D.rows_per_band
let total_cells   : pos    = D.total_cells
let max_col_count : pos    = D.max_col_count
let grid_version  : string = D.grid_version

(* --------------------------------------------------------------- lookup *)

/// The list is the proof vehicle; the array is the runtime one. `cell_to_point`
/// binary-searches this table, and list indexing is linear.
let cum_arr : (a: IA.t nat{IA.length a == bands + 1}) = IA.of_list D.cumcols_list

let cum (b: nat{b <= bands}) : nat = IA.index cum_arr b

val lemma_cum_spec (b: nat{b <= bands}) : Lemma (cum b == L.index D.cumcols_list b)
let lemma_cum_spec b = ()

val lemma_cum_base : unit -> Lemma (cum 0 == 0)
let lemma_cum_base () = D.lemma_base (); lemma_cum_spec 0

/// Strictly increasing, with every step inside the width bound. This is the
/// single fact the generated table had to establish, and everything below is
/// arithmetic on top of it.
val lemma_cum_mono (b: nat{b < bands})
  : Lemma (cum b < cum (b + 1) /\ cum (b + 1) - cum b <= max_col_count)
let lemma_cum_mono b =
  D.lemma_diffs ();
  lemma_cum_spec b;
  lemma_cum_spec (b + 1);
  lemma_diffs_index D.cumcols_list max_col_count b

(* -------------------------------------------------------- derived views *)

let col_counts (b: nat{b < bands}) : (c: pos{c <= max_col_count}) =
  lemma_cum_mono b;
  cum (b + 1) - cum b

let offsets (b: nat{b <= bands}) : nat = cum b * rows_per_band

(* ------------------------------------------------------ well-formedness *)

val lemma_rows_divide : unit -> Lemma (rows == bands * rows_per_band)
let lemma_rows_divide () = assert_norm (D.rows == D.bands * D.rows_per_band)

val lemma_offsets_base : unit -> Lemma (offsets 0 == 0)
let lemma_offsets_base () = lemma_cum_base ()

/// Contiguity, by algebra rather than by inspection:
///   cum(b+1) * rpb == cum b * rpb + (cum(b+1) - cum b) * rpb
val lemma_offsets_contiguous (b: nat{b < bands})
  : Lemma (offsets (b + 1) == offsets b + col_counts b * rows_per_band)
let lemma_offsets_contiguous b = lemma_cum_mono b

val lemma_offsets_mono (b: nat{b < bands}) : Lemma (offsets b < offsets (b + 1))
let lemma_offsets_mono b =
  lemma_cum_mono b;
  M.lemma_mult_lt_right rows_per_band (cum b) (cum (b + 1))

/// Monotone across any span of bands, which is what bounds an encoded index
/// by total_cells and what makes the inverse binary search sound.
val lemma_offsets_le (b1 b2: nat)
  : Lemma (requires b1 <= b2 /\ b2 <= bands) (ensures offsets b1 <= offsets b2)
          (decreases b2 - b1)
let rec lemma_offsets_le b1 b2 =
  if b1 = b2 then () else (lemma_offsets_mono b1; lemma_offsets_le (b1 + 1) b2)

val lemma_total : unit -> Lemma (offsets bands == total_cells)
let lemma_total () = D.lemma_total (); lemma_cum_spec bands

/// The grid must fit inside the address space, or encode could produce an
/// index the Feistel cannot represent.
val lemma_fits : unit -> Lemma (total_cells < addr_space)
let lemma_fits () = assert_norm (D.total_cells < addr_space)

/// Needed for lemma_midpoint_interior at every band.
val lemma_cells_wide (b: nat{b < bands})
  : Lemma (lon_span >= 2 * col_counts b /\ lat_span >= 2 * rows)
let lemma_cells_wide b =
  assert_norm (lon_span >= 2 * D.max_col_count);
  assert_norm (lat_span >= 2 * D.rows);
  M.lemma_mult_le_left 2 (col_counts b) max_col_count

/// No intermediate product exceeds 64 bits. The widest is
/// lon_span * max(col_counts) = 4.80e18, which fits signed int64 with 1.92x
/// headroom. Tight enough to be worth proving rather than assuming.
val theorem_no_overflow (b: nat{b < bands})
  : Lemma (lon_span * col_counts b < pow2 63 /\ lat_span * rows < pow2 63)
let theorem_no_overflow b =
  assert_norm (lon_span * D.max_col_count < pow2 63);
  assert_norm (lat_span * D.rows < pow2 63);
  M.lemma_mult_le_left lon_span (col_counts b) max_col_count
