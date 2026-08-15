module Tessarium.Spec

/// Shared constants and the bucketing lemmas that everything else rests on.
///
/// NOT YET VERIFIED. Written against the validated reference implementation;
/// run `fstar.exe --record_hints Tessarium.Spec.fst` to discharge.

open FStar.Mul

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

let lat_min  : int = -90_000_000_000
let lat_span : pos = 180_000_000_000
let lon_min  : int = -180_000_000_000
let lon_span : pos = 360_000_000_000

type lat_ns = v:int{lat_min <= v /\ v <= lat_min + lat_span}
type lon_ns = v:int{lon_min <= v /\ v <= lon_min + lon_span}

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

val lemma_bucket_monotone
  (v1 v2 v_min: int) (span k: pos)
  : Lemma (requires v1 <= v2)
          (ensures  bucket v1 v_min span k <= bucket v2 v_min span k)

/// The inverse property. This is the one the reference implementation got
/// wrong on first attempt.
val lemma_edge_inverse
  (v v_min: int) (span k: pos) (i: nat)
  : Lemma (requires i < k /\ v_min <= v /\ v < v_min + span)
          (ensures  (bucket v v_min span k == i)
                    <==> (edge i v_min span k <= v /\ v < edge (i + 1) v_min span k))

/// A cell's midpoint lands strictly inside that cell, provided the cell is at
/// least two units wide. Every cell in the shipped table is thousands of
/// nanodegrees across, so the precondition is discharged by the band table
/// rather than assumed.
val lemma_midpoint_interior
  (v_min: int) (span k: pos) (i: nat)
  : Lemma (requires i < k /\ span >= 2 * k)
          (ensures  bucket (v_min + ((2 * i + 1) * span) / (2 * k)) v_min span k == i)
