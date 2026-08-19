module Tessarium.Low.Grid

/// The proved grid restated over 64-bit machine integers, for KaRaMeL.
///
/// Same discipline as Tessarium.Low.Feistel: nothing is re-proved, every
/// function's ensures equates its machine answer with Tessarium.Grid's on
/// the same inputs, and the spec theorems (containment, injectivity, round
/// trip) transfer by rewriting.
///
/// Two representation choices, both to keep the C boundary honest:
///
/// Coordinates travel as UNSIGNED OFFSETS from the domain corner --
/// dlat = lat - lat_min in [0, lat_span], dlon likewise -- because the
/// spec's arithmetic subtracts the corner first anyway, and F*'s signed
/// machine integers drag in library internals our zero-admit flag rejects.
/// The OCaml FFI shim does the one add/subtract at the boundary.
///
/// The band table travels as a FUNCTION PARAMETER (`cum_low`), the same
/// pattern as the Feistel's round function: the refinement on its result
/// -- "returns exactly T.cum b" -- makes every theorem here conditional on
/// a conforming lookup, and the C side's generated const array is checked
/// against that same table by the vectors (and the table itself against
/// the proved source by check/Tessarium.Check.Table). A proved in-memory
/// table (LowStar buffer) is the recorded upgrade path.

module S  = Tessarium.Spec
module T  = Tessarium.Table
module GR = Tessarium.Grid
module M  = FStar.Math.Lemmas
module U64 = FStar.UInt64

unfold noextract
let v64 (x: U64.t) : int = U64.v x

(* ---------------------------------------------------- machine constants *)

let lat_span64 : (c: U64.t{v64 c == S.lat_span}) = 180000000000uL
let lon_span64 : (c: U64.t{v64 c == S.lon_span}) = 360000000000uL

let rows64 : (c: U64.t{v64 c == T.rows}) =
  assert_norm (T.rows == 6553600); 6553600uL

let rows_per_band64 : (c: U64.t{v64 c == T.rows_per_band}) =
  assert_norm (T.rows_per_band == 1600); 1600uL

let bands64 : (c: U64.t{v64 c == T.bands}) =
  assert_norm (T.bands == 4096); 4096uL

(* -------------------------------------------------------------- the table *)

/// A machine lookup that answers exactly as the proved cumulative table.
/// Everything below is correct FOR ANY inhabitant; the C caller supplies a
/// const-array lookup whose contents the vectors and the evaluator leg pin.
type cum_low = b: U64.t{U64.v b <= T.bands} -> (r: U64.t{v64 r == T.cum (U64.v b)})

let col_counts_low (cum: cum_low) (b: U64.t{U64.v b < T.bands})
  : (k: U64.t{v64 k == T.col_counts (U64.v b)})
  = T.lemma_cum_mono (U64.v b);
    U64.sub (cum (U64.add b 1uL)) (cum b)

let offsets_low (cum: cum_low) (b: U64.t{U64.v b <= T.bands})
  : (o: U64.t{v64 o == T.offsets (U64.v b)})
  = T.lemma_offsets_le (U64.v b) T.bands;
    T.lemma_total ();
    U64.mul (cum b) rows_per_band64

(* ------------------------------------------------------------ decomposition *)

let row_of_low (dlat: U64.t{U64.v dlat <= S.lat_span})
  : (r: U64.t{v64 r == GR.row_of (S.lat_min + U64.v dlat) /\ U64.v r < T.rows})
  = if dlat = lat_span64 then U64.sub rows64 1uL
    else begin
      T.theorem_no_overflow 0;
      M.lemma_mult_le_right T.rows (U64.v dlat) S.lat_span;
      S.lemma_bucket_range (S.lat_min + U64.v dlat) S.lat_min S.lat_span T.rows;
      U64.div (U64.mul dlat rows64) lat_span64
    end

let lon_fold_low (dlon: U64.t{U64.v dlon <= S.lon_span})
  : (f: U64.t{v64 f == GR.lon_fold (S.lon_min + U64.v dlon) - S.lon_min /\
              U64.v f < S.lon_span})
  = if dlon = lon_span64 then 0uL else dlon

let col_of_low (dlon: U64.t{U64.v dlon <= S.lon_span})
    (k: U64.t{0 < U64.v k /\ U64.v k <= T.max_col_count})
  : (c: U64.t{v64 c == GR.col_of (S.lon_min + U64.v dlon) (U64.v k) /\
              U64.v c < U64.v k})
  = let f = lon_fold_low dlon in
    assert_norm (S.lon_span * 13343409 < pow2 63);
    assert_norm (T.max_col_count == 13343409);
    M.lemma_mult_le_right (U64.v k) (U64.v f) S.lon_span;
    M.lemma_mult_le_left S.lon_span (U64.v k) T.max_col_count;
    S.lemma_bucket_range (GR.lon_fold (S.lon_min + U64.v dlon))
      S.lon_min S.lon_span (U64.v k);
    U64.div (U64.mul f k) lon_span64

let band_of_row_low (r: U64.t{U64.v r < T.rows})
  : (b: U64.t{v64 b == GR.band_of_row (U64.v r) /\ U64.v b < T.bands})
  = T.lemma_rows_divide ();
    S.lemma_div_bound (U64.v r) T.rows_per_band T.bands;
    U64.div r rows_per_band64

let row_in_band_low (r: U64.t{U64.v r < T.rows})
  : (i: U64.t{v64 i == GR.row_in_band (U64.v r) /\ U64.v i < T.rows_per_band})
  = M.lemma_div_mod (U64.v r) T.rows_per_band;
    M.lemma_mod_lt (U64.v r) T.rows_per_band;
    U64.rem r rows_per_band64

(* ---------------------------------------------------------------- forward *)

let point_to_cell_low (cum: cum_low)
    (dlat: U64.t{U64.v dlat <= S.lat_span})
    (dlon: U64.t{U64.v dlon <= S.lon_span})
  : (cell: U64.t{v64 cell == GR.point_to_cell (S.lat_min + U64.v dlat)
                                              (S.lon_min + U64.v dlon) /\
                 U64.v cell < T.total_cells})
  = let r = row_of_low dlat in
    let b = band_of_row_low r in
    let k = col_counts_low cum b in
    let i = row_in_band_low r in
    let c = col_of_low dlon k in
    GR.lemma_cell_bound (U64.v b) (U64.v i) (U64.v c);
    M.lemma_mult_le_right (U64.v k) (U64.v i) (T.rows_per_band - 1);
    U64.add (U64.add (offsets_low cum b) (U64.mul i k)) c

(* ---------------------------------------------------------------- inverse *)

let rec band_search_low (cum: cum_low) (lo hi index: U64.t)
  : Pure U64.t
      (requires U64.v lo <= U64.v hi /\ U64.v hi < T.bands /\
                T.offsets (U64.v lo) <= U64.v index /\
                U64.v index < T.offsets (U64.v hi + 1))
      (ensures  fun b ->
        v64 b == GR.band_search (U64.v lo) (U64.v hi) (U64.v index))
      (decreases U64.v hi - U64.v lo)
  = if lo = hi then lo
    else begin
      let mid = U64.div (U64.add (U64.add lo hi) 1uL) 2uL in
      M.lemma_div_mod (U64.v lo + U64.v hi + 1) 2;
      M.lemma_mod_lt (U64.v lo + U64.v hi + 1) 2;
      if U64.lte (offsets_low cum mid) index
      then band_search_low cum mid hi index
      else band_search_low cum lo (U64.sub mid 1uL) index
    end

let band_of_cell_low (cum: cum_low) (index: U64.t{U64.v index < T.total_cells})
  : (b: U64.t{v64 b == GR.band_of_cell (U64.v index) /\ U64.v b < T.bands})
  = T.lemma_offsets_base ();
    T.lemma_total ();
    band_search_low cum 0uL (U64.sub bands64 1uL) index

/// The machine mirror of GR.decompose, componentwise.
let decompose_low (cum: cum_low) (index: U64.t{U64.v index < T.total_cells})
  : Pure (U64.t & U64.t & U64.t)
      (requires True)
      (ensures  fun (r, b, c) ->
        (let (| sr, sb, sc |) = GR.decompose (U64.v index) in
         v64 r == sr /\ v64 b == sb /\ v64 c == sc))
  = let b = band_of_cell_low cum index in
    let k = col_counts_low cum b in
    T.lemma_offsets_contiguous (U64.v b);
    let rem = U64.sub index (offsets_low cum b) in
    S.lemma_div_bound (U64.v rem) (U64.v k) T.rows_per_band;
    M.lemma_div_mod (U64.v rem) (U64.v k);
    M.lemma_mod_lt (U64.v rem) (U64.v k);
    let i = U64.div rem k in
    let c = U64.rem rem k in
    T.lemma_rows_divide ();
    M.lemma_mult_le_right T.rows_per_band (U64.v b + 1) T.bands;
    let r = U64.add (U64.mul b rows_per_band64) i in
    (r, b, c)

/// Cell centre, as offsets from the domain corner. The longitude product
/// (2c+1) * lon_span is the tightest number in the whole core: it peaks at
/// 9.61e18, above signed range, under unsigned by 1.92x -- which is why
/// these functions are unsigned everywhere (BOUNDS.md).
let cell_to_point_low (cum: cum_low) (index: U64.t{U64.v index < T.total_cells})
  : Pure (U64.t & U64.t)
      (requires True)
      (ensures  fun (dlat, dlon) ->
        (let (slat, slon) = GR.cell_to_point (U64.v index) in
         v64 dlat == slat - S.lat_min /\ v64 dlon == slon - S.lon_min))
  = let (r, b, c) = decompose_low cum index in
    let k = col_counts_low cum b in
    assert_norm ((2 * 6553600 - 1) * 180000000000 < pow2 63);
    assert_norm ((2 * 13343409 - 1) * 360000000000 < pow2 64);
    assert_norm (T.rows == 6553600);
    assert_norm (T.max_col_count == 13343409);
    M.lemma_mult_le_right S.lat_span (2 * U64.v r + 1) (2 * T.rows - 1);
    M.lemma_mult_le_right S.lon_span (2 * U64.v c + 1) (2 * T.max_col_count - 1);
    M.lemma_mult_le_right S.lat_span (2 * U64.v r + 1) (2 * T.rows);
    M.lemma_mult_le_right S.lon_span (2 * U64.v c + 1) (2 * U64.v k);
    S.lemma_div_bound ((2 * U64.v r + 1) * S.lat_span) (2 * T.rows) S.lat_span;
    S.lemma_div_bound ((2 * U64.v c + 1) * S.lon_span) (2 * U64.v k) S.lon_span;
    let dlat =
      U64.div (U64.mul (U64.add (U64.mul 2uL r) 1uL) lat_span64)
              (U64.mul 2uL rows64) in
    let dlon =
      U64.div (U64.mul (U64.add (U64.mul 2uL c) 1uL) lon_span64)
              (U64.mul 2uL k) in
    (dlat, dlon)

/// Half-open cell bounds, as offsets. `edge` is called with i up to AND
/// INCLUDING k (BOUNDS.md records the survey correction).
let edge_low (i span k: U64.t)
  : Pure U64.t
      (requires 0 < U64.v span /\ 0 < U64.v k /\ U64.v i <= U64.v k /\
                U64.v k * U64.v span < pow2 63)
      (ensures  fun e -> v64 e == S.edge (U64.v i) 0 (U64.v span) (U64.v k))
  = M.lemma_mult_le_right (U64.v span) (U64.v i) (U64.v k);
    U64.div (U64.sub (U64.add (U64.mul i span) k) 1uL) k

let cell_bounds_low (cum: cum_low) (index: U64.t{U64.v index < T.total_cells})
  : Pure (U64.t & U64.t & U64.t & U64.t)
      (requires True)
      (ensures  fun (lat_lo, lat_hi, lon_lo, lon_hi) ->
        (let (slat_lo, slat_hi, slon_lo, slon_hi) =
           GR.cell_bounds (U64.v index) in
         v64 lat_lo == slat_lo - S.lat_min /\ v64 lat_hi == slat_hi - S.lat_min /\
         v64 lon_lo == slon_lo - S.lon_min /\ v64 lon_hi == slon_hi - S.lon_min))
  = let (r, b, c) = decompose_low cum index in
    let k = col_counts_low cum b in
    assert_norm (T.rows * S.lat_span < pow2 63);
    assert_norm (13343409 * S.lon_span < pow2 63);
    assert_norm (T.max_col_count == 13343409);
    M.lemma_mult_le_left S.lon_span (U64.v k) T.max_col_count;
    (edge_low r lat_span64 rows64,
     edge_low (U64.add r 1uL) lat_span64 rows64,
     edge_low c lon_span64 k,
     edge_low (U64.add c 1uL) lon_span64 k)

(* -------------------------------------------------- theorems, transferred *)

/// The spec round trip, restated on the machine functions: a cell's centre
/// maps back to that cell, for any conforming table lookup.
val theorem_roundtrip_low (cum: cum_low) (index: U64.t{U64.v index < T.total_cells})
  : Lemma (let (dlat, dlon) = cell_to_point_low cum index in
           U64.v dlat <= S.lat_span /\ U64.v dlon <= S.lon_span /\
           point_to_cell_low cum dlat dlon == index)
let theorem_roundtrip_low cum index =
  GR.theorem_roundtrip (U64.v index);
  let (dlat, dlon) = cell_to_point_low cum index in
  U64.v_inj (point_to_cell_low cum dlat dlon) index
