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

(* ================================================================ theorems *)

/// A cell index determines its band. This is where band seams are settled: two
/// adjacent bands cannot both claim an index, because offsets is strictly
/// increasing, so the half-open interval each band owns is disjoint from every
/// other's. Seams are the failure the design worried about, and this is the
/// whole of the argument.
val lemma_band_unique (b1 b2: nat) (index: nat)
  : Lemma (requires b1 < T.bands /\ b2 < T.bands /\
                    T.offsets b1 <= index /\ index < T.offsets (b1 + 1) /\
                    T.offsets b2 <= index /\ index < T.offsets (b2 + 1))
          (ensures  b1 == b2)
let lemma_band_unique b1 b2 index =
  if b1 < b2 then T.lemma_offsets_le (b1 + 1) b2
  else if b2 < b1 then T.lemma_offsets_le (b2 + 1) b1

/// The forward layout is recoverable: from `offsets b + i * k + c` alone, each
/// of b, i and c comes back. Every theorem below is a corollary.
val lemma_layout_injective (b: nat{b < T.bands}) (i: nat{i < T.rows_per_band}) (c: nat)
  : Lemma (requires c < T.col_counts b)
          (ensures (let k = T.col_counts b in
                    let index = T.offsets b + i * k + c in
                    index < T.total_cells /\
                    band_of_cell index == b /\
                    (index - T.offsets b) / k == i /\
                    (index - T.offsets b) % k == c))
let lemma_layout_injective b i c =
  let k = T.col_counts b in
  let index = T.offsets b + i * k + c in
  lemma_cell_bound b i c;
  // index sits inside band b's half-open interval, so the search finds b
  M.lemma_mult_le_right k 0 i;
  M.lemma_mult_le_right k i (T.rows_per_band - 1);
  T.lemma_offsets_contiguous b;
  lemma_band_unique (band_of_cell index) b index;
  // and i, c are the quotient and remainder, because c < k
  assert (index - T.offsets b == c + i * k);
  M.lemma_div_plus c i k;
  M.small_div c k;
  M.lemma_mod_plus c i k;
  M.small_mod c k

/// `decompose` inverts the layout exactly.
val lemma_decompose_layout (b: nat{b < T.bands}) (i: nat{i < T.rows_per_band}) (c: nat)
  : Lemma (requires c < T.col_counts b)
          (ensures (let index = T.offsets b + i * T.col_counts b + c in
                    lemma_cell_bound b i c;
                    let (| r', b', c' |) = decompose index in
                    b' == b /\ c' == c /\ r' == b * T.rows_per_band + i))
let lemma_decompose_layout b i c =
  lemma_cell_bound b i c;
  lemma_layout_injective b i c

(* ------------------------------------------------------------ containment *)

/// Exactly +90 is the one latitude bucketing puts out of range; it is clamped
/// into the final row rather than becoming row `rows`. Stated separately so
/// the containment theorem below can be strict everywhere else.
val lemma_pole_clamp : unit -> Lemma (row_of (lat_min + lat_span) == T.rows - 1)
let lemma_pole_clamp () = ()

/// Every point lies inside the cell it maps to.
///
/// This is the floor/ceiling bug the reference implementation shipped, stated
/// as a theorem. Inverting a floor-bucket with a floor puts each cell's upper
/// edge one nanodegree short, so points in that sliver test as outside their
/// own cell — no crash, no error, just a wrong answer at boundaries.
///
/// Half-open at the high edge, and longitude is compared after folding, since
/// +180 and -180 are the same meridian.
val theorem_containment (lat: lat_ns) (lon: lon_ns)
  : Lemma (requires lat < lat_min + lat_span)
          (ensures (let lat_lo, lat_hi, lon_lo, lon_hi =
                      cell_bounds (point_to_cell lat lon) in
                    lat_lo <= lat /\ lat < lat_hi /\
                    lon_lo <= lon_fold lon /\ lon_fold lon < lon_hi))
let theorem_containment lat lon =
  let r = row_of lat in
  let b = band_of_row r in
  let k = T.col_counts b in
  let i = row_in_band r in
  let c = col_of lon k in
  lemma_decompose_layout b i c;
  T.lemma_rows_divide ();
  M.lemma_div_mod r T.rows_per_band;
  lemma_edge_inverse lat lat_min lat_span T.rows r;
  lemma_edge_inverse (lon_fold lon) lon_min lon_span k c

(* ------------------------------------------------------------- injectivity *)

/// Distinct cells get distinct indices — including across band seams, which is
/// the case tests miss because the failure set is measure-zero.
///
/// Stated as: if two points share an index then they share a row and a column.
/// Note the columns are compared under the same band's count, which is exactly
/// what makes this a statement about seams rather than about one band.
val theorem_injective (lat1: lat_ns) (lon1: lon_ns) (lat2: lat_ns) (lon2: lon_ns)
  : Lemma (requires point_to_cell lat1 lon1 == point_to_cell lat2 lon2)
          (ensures  (let r1 = row_of lat1 in
                     let r2 = row_of lat2 in
                     r1 == r2 /\
                     col_of lon1 (T.col_counts (band_of_row r1))
                     == col_of lon2 (T.col_counts (band_of_row r2))))
let theorem_injective lat1 lon1 lat2 lon2 =
  let r1 = row_of lat1 in
  let b1 = band_of_row r1 in
  let i1 = row_in_band r1 in
  let c1 = col_of lon1 (T.col_counts b1) in
  let r2 = row_of lat2 in
  let b2 = band_of_row r2 in
  let i2 = row_in_band r2 in
  let c2 = col_of lon2 (T.col_counts b2) in
  lemma_layout_injective b1 i1 c1;
  lemma_layout_injective b2 i2 c2;
  // same index => same band, then same quotient and remainder within it
  T.lemma_rows_divide ();
  M.lemma_div_mod r1 T.rows_per_band;
  M.lemma_div_mod r2 T.rows_per_band

(* -------------------------------------------------------------- round trip *)

/// A cell's representative point maps back to that cell.
///
/// Rests on the midpoint landing strictly inside its own bucket, which needs
/// the cell to be at least two units wide. Every cell in the shipped table is
/// thousands of nanodegrees across, and `lemma_cells_wide` discharges that from
/// the band table rather than assuming it.
val theorem_roundtrip (index: cell)
  : Lemma (let lat, lon = cell_to_point index in point_to_cell lat lon == index)
let theorem_roundtrip index =
  let (| r, b, c |) = decompose index in
  let k = T.col_counts b in
  let i = r - b * T.rows_per_band in
  T.lemma_rows_divide ();
  T.lemma_offsets_contiguous b;
  T.lemma_cells_wide b;
  // the midpoint of row r buckets back to r, and likewise for column c
  lemma_midpoint_interior lat_min lat_span T.rows r;
  lemma_midpoint_interior lon_min lon_span k c;
  // and the midpoint is strictly below the top edge, so no clamping applies
  M.lemma_mult_le_right lat_span (2 * r + 1) (2 * T.rows);
  M.lemma_mult_le_right lon_span (2 * c + 1) (2 * k);
  lemma_div_bound ((2 * r + 1) * lat_span) (2 * T.rows) lat_span;
  lemma_div_bound ((2 * c + 1) * lon_span) (2 * k) lon_span;
  lemma_layout_injective b i c;
  M.lemma_div_mod (index - T.offsets b) k
