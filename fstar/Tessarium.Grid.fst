module Tessarium.Grid

/// Banded grid: point <-> cell index, in exact integer nanodegrees.
///
/// Latitude is bucketed uniformly into `rows`. Each band of `rows_per_band`
/// consecutive rows carries its own column count, so cell width tracks
/// cos(latitude) instead of collapsing at the poles. The cell index is the
/// band's offset plus the row-within-band and column, laid out contiguously.

module M = FStar.Math.Lemmas
module T = Tessarium.Table

open Tessarium.Spec

type cell = c: nat{c < T.total_cells}

(* ------------------------------------------------------------ decomposition *)

/// Latitude does not wrap: exactly +90 is clamped into the final row rather
/// than becoming row `rows`, which is the one value bucketing puts out of range.
let row_of (lat: lat_ns) : (r: nat{r < T.rows}) =
  if lat = lat_min + lat_span then T.rows - 1
  else begin
    lemma_bucket_range lat lat_min lat_span T.rows;
    bucket lat lat_min lat_span T.rows
  end

/// Longitude wraps: +180 is the same meridian as -180 and folds onto it.
let lon_fold (lon: lon_ns) : (v: int{lon_min <= v /\ v < lon_min + lon_span}) =
  if lon = lon_min + lon_span then lon_min else lon

let col_of (lon: lon_ns) (k: pos) : (c: nat{c < k}) =
  let v = lon_fold lon in
  lemma_bucket_range v lon_min lon_span k;
  bucket v lon_min lon_span k

let band_of_row (r: nat{r < T.rows}) : (b: nat{b < T.bands}) =
  T.lemma_rows_divide ();
  lemma_div_bound r T.rows_per_band T.bands;
  r / T.rows_per_band

/// Row index within its band, in [0, rows_per_band).
let row_in_band (r: nat{r < T.rows}) : (i: nat{i < T.rows_per_band}) =
  let b = band_of_row r in
  M.lemma_div_mod r T.rows_per_band;
  M.lemma_mod_lt r T.rows_per_band;
  r - b * T.rows_per_band

(* ---------------------------------------------------------------- forward *)

val lemma_cell_bound (b: nat{b < T.bands}) (i: nat{i < T.rows_per_band}) (c: nat)
  : Lemma (requires c < T.col_counts b)
          (ensures  T.offsets b + i * T.col_counts b + c < T.total_cells)
let lemma_cell_bound b i c =
  let k = T.col_counts b in
  // i * k + c < rows_per_band * k, because i <= rows_per_band - 1 and c <= k - 1
  M.lemma_mult_le_right k i (T.rows_per_band - 1);
  T.lemma_offsets_contiguous b;
  T.lemma_offsets_le (b + 1) T.bands;
  T.lemma_total ()

let point_to_cell (lat: lat_ns) (lon: lon_ns) : cell =
  let r = row_of lat in
  let b = band_of_row r in
  let k = T.col_counts b in
  let i = row_in_band r in
  let c = col_of lon k in
  lemma_cell_bound b i c;
  T.offsets b + i * k + c

(* ---------------------------------------------------------------- inverse *)

/// Largest band whose offset does not exceed the index. The table is strictly
/// increasing, so this band is unique.
let rec band_search (lo hi: nat) (index: nat)
  : Pure nat
    (requires lo <= hi /\ hi < T.bands /\
              T.offsets lo <= index /\ index < T.offsets (hi + 1))
    (ensures  fun b -> b < T.bands /\ T.offsets b <= index /\ index < T.offsets (b + 1))
    (decreases hi - lo)
  = if lo = hi then lo
    else begin
      let mid = (lo + hi + 1) / 2 in
      M.lemma_div_mod (lo + hi + 1) 2;
      M.lemma_mod_lt (lo + hi + 1) 2;
      if T.offsets mid <= index then band_search mid hi index
      else band_search lo (mid - 1) index
    end

let band_of_cell (index: cell) : (b: nat{b < T.bands /\
                                         T.offsets b <= index /\
                                         index < T.offsets (b + 1)}) =
  T.lemma_offsets_base ();
  T.lemma_total ();
  band_search 0 (T.bands - 1) index

/// Cell index decomposed back into band, row and column.
let decompose (index: cell)
  : r: nat{r < T.rows} & b: nat{b < T.bands} & c: nat{c < T.col_counts b} =
  let b = band_of_cell index in
  let k = T.col_counts b in
  T.lemma_offsets_contiguous b;
  let rem = index - T.offsets b in
  // rem < rows_per_band * k
  lemma_div_bound rem k T.rows_per_band;
  M.lemma_div_mod rem k;
  M.lemma_mod_lt rem k;
  let i = rem / k in
  let c = rem % k in
  T.lemma_rows_divide ();
  M.lemma_mult_le_right T.rows_per_band (b + 1) T.bands;
  let r = b * T.rows_per_band + i in
  (| r, b, c |)

/// Representative point of a cell: its centre, computed without division loss.
let cell_to_point (index: cell) : lat_ns & lon_ns =
  let (| r, b, c |) = decompose index in
  let k = T.col_counts b in
  M.lemma_mult_le_right lat_span (2 * r + 1) (2 * T.rows);
  M.lemma_mult_le_right lon_span (2 * c + 1) (2 * k);
  lemma_div_bound ((2 * r + 1) * lat_span) (2 * T.rows) lat_span;
  lemma_div_bound ((2 * c + 1) * lon_span) (2 * k) lon_span;
  let lat = lat_min + ((2 * r + 1) * lat_span) / (2 * T.rows) in
  let lon = lon_min + ((2 * c + 1) * lon_span) / (2 * k) in
  (lat, lon)

/// Half-open bounds of a cell: [lat_lo, lat_hi) x [lon_lo, lon_hi).
/// Inverting a floor-bucket takes a CEILING, which is what `edge` does.
let cell_bounds (index: cell) : int & int & int & int =
  let (| r, b, c |) = decompose index in
  let k = T.col_counts b in
  (edge r lat_min lat_span T.rows,
   edge (r + 1) lat_min lat_span T.rows,
   edge c lon_min lon_span k,
   edge (c + 1) lon_min lon_span k)
