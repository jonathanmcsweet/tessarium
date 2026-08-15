module Tessarium.Spec

/// Shared constants and the bucketing lemmas that everything else rests on.

module M = FStar.Math.Lemmas

(* ------------------------------------------------------------------ sizes *)

let words   : pos = 2048
let num_max : pos = 10000

/// Address space. Factors as 2^37 * 625, which is what lets the Feistel
/// domain match it exactly with no cycle-walking.
let addr_space : pos = words * words * words * num_max   // 85_899_345_920_000

/// Near-balanced factor pair: a * b = addr_space, ratio 2:1.
let fe_a : pos = 262144 * 25     //  6_553_600  = 2^18 * 25
let fe_b : pos = 524288 * 25     // 13_107_200  = 2^19 * 25

val lemma_factors : unit -> Lemma (fe_a * fe_b == addr_space)
let lemma_factors () = assert_norm (fe_a * fe_b == addr_space)

(* ------------------------------------------------------------- geodetic *)

let lat_min  : int = -90000000000
let lat_span : pos = 180000000000
let lon_min  : int = -180000000000
let lon_span : pos = 360000000000

type lat_ns = v:int{lat_min <= v /\ v <= lat_min + lat_span}
type lon_ns = v:int{lon_min <= v /\ v <= lon_min + lon_span}

(* --------------------------------------------------- division groundwork *)

/// Everything below reduces to these three. F* division on a non-negative
/// numerator is floor division, and all four uses here keep the numerator
/// non-negative, which is why the bucketing arithmetic is exact.

/// The defining characterisation of a floor quotient.
val lemma_div_char (a: int) (b: pos) (q: int)
  : Lemma (a / b == q <==> (q * b <= a /\ a < (q + 1) * b))
let lemma_div_char a b q =
  M.division_propriety a b;
  assert ((q + 1) * b == q * b + b);
  if q * b <= a && a < (q + 1) * b then M.division_definition a b q

/// The same fact in inequality form, which is what the ceiling needs.
val lemma_div_le_iff (a: int) (b: pos) (d: int)
  : Lemma (a / b <= d <==> a < (d + 1) * b)
let lemma_div_le_iff a b d =
  M.division_propriety a b;
  M.multiplication_order_lemma d (a / b) b;
  M.multiplication_order_lemma (a / b) (d + 1) b;
  assert ((d + 1) * b == d * b + b)

/// `(p + k - 1) / k` is ceil(p / k), and a ceiling sits below an integer
/// exactly when the un-rounded fraction does. This is the arithmetic heart of
/// `lemma_edge_inverse`.
val lemma_ceil_le (p: nat) (k: pos) (d: int)
  : Lemma (((p + k - 1) / k <= d) <==> (p <= d * k))
let lemma_ceil_le p k d =
  lemma_div_le_iff (p + k - 1) k d;
  assert ((d + 1) * k == d * k + k)

(* ------------------------------------------------------- bucketing core *)

/// Uniform bucketing of [v_min, v_min + span) onto [0, k).
///
/// This single function underlies both the latitude and longitude
/// decomposition. Everything about grid injectivity reduces to its
/// properties.
let bucket (v v_min: int) (span k: pos) : int =
  ((v - v_min) * k) / span

/// Lowest v mapping into bucket i. Inverting a floor takes a CEILING.
/// Getting this wrong (using floor on both sides) produces an off-by-one
/// nanodegree at every cell's upper edge — invisible in ordinary testing,
/// caught only at cell boundaries.
let edge (i: nat) (v_min: int) (span k: pos) : int =
  v_min + (i * span + k - 1) / k

val lemma_bucket_range
  (v v_min: int) (span k: pos)
  : Lemma (requires v_min <= v /\ v < v_min + span)
          (ensures  0 <= bucket v v_min span k /\ bucket v v_min span k < k)
let lemma_bucket_range v v_min span k =
  let d = v - v_min in
  M.lemma_mult_le_right k 0 d;                            // 0 <= d * k
  M.small_div 0 span;
  M.lemma_div_le 0 (d * k) span;                          // 0 <= (d * k) / span
  M.lemma_mult_lt_right k d span;                         // d * k < span * k
  M.division_propriety (d * k) span;
  M.multiplication_order_lemma ((d * k) / span) k span

val lemma_bucket_monotone
  (v1 v2 v_min: int) (span k: pos)
  : Lemma (requires v1 <= v2)
          (ensures  bucket v1 v_min span k <= bucket v2 v_min span k)
let lemma_bucket_monotone v1 v2 v_min span k =
  M.lemma_mult_le_right k (v1 - v_min) (v2 - v_min);
  M.lemma_div_le ((v1 - v_min) * k) ((v2 - v_min) * k) span

/// The inverse property. This is the one the reference implementation got
/// wrong on first attempt.
val lemma_edge_inverse
  (v v_min: int) (span k: pos) (i: nat)
  : Lemma (requires i < k /\ v_min <= v /\ v < v_min + span)
          (ensures  (bucket v v_min span k == i)
                    <==> (edge i v_min span k <= v /\ v < edge (i + 1) v_min span k))
let lemma_edge_inverse v v_min span k i =
  let d = v - v_min in
  M.lemma_mult_le_right span 0 i;                         // 0 <= i * span
  M.lemma_mult_le_right span 0 (i + 1);                   // 0 <= (i + 1) * span
  lemma_div_char (d * k) span i;
  lemma_ceil_le (i * span) k d;
  lemma_ceil_le ((i + 1) * span) k d

/// A cell's midpoint lands strictly inside that cell, provided the cell is at
/// least two units wide. Every cell in the shipped table is thousands of
/// nanodegrees across, so the precondition is discharged by the band table
/// rather than assumed.
val lemma_midpoint_interior
  (v_min: int) (span k: pos) (i: nat)
  : Lemma (requires i < k /\ span >= 2 * k)
          (ensures  bucket (v_min + ((2 * i + 1) * span) / (2 * k)) v_min span k == i)
let lemma_midpoint_interior v_min span k i =
  let m = ((2 * i + 1) * span) / (2 * k) in
  M.division_propriety ((2 * i + 1) * span) (2 * k);
  assert ((2 * i + 1) * span == 2 * (i * span) + span);
  assert (m * (2 * k) == 2 * (m * k));
  assert ((i + 1) * span == i * span + span);
  lemma_div_char (m * k) span i
