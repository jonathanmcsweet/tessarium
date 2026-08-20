module Tessarium.Check.RealRound

/// The evaluator leg for the REAL round function. Every other check module
/// drives the harness round function; this one makes F*'s normalizer
/// recompute digestif's HMAC-SHA256 answers from the proved machine source
/// (Tessarium.Low.Hmac through Tessarium.Low.Core.rf_real) -- closing
/// the gap the roadmap recorded: a miswired production round function
/// would slip past every harness-round-function leg.
///
/// rf_real is the ghost SPEC that rf_real_low is proved equal to, so
/// pinning it to digestif here pins both sides of that proof; the C
/// harness replays the same draws through the machine side.

module L = FStar.List.Tot
module E = Tessarium.Check.Expected
module C = Tessarium.Low.Core
module U64 = FStar.UInt64

let w32ok (k: int) : bool = 0 <= k && k < 0x100000000

let rec rf_ok (keys: list (int & int & int & int & int & int & int & int))
    (vecs: list (int & int & int & int))
  : Tot bool (decreases keys) =
  match keys, vecs with
  | [], [] -> true
  | (k0, k1, k2, k3, k4, k5, k6, k7) :: ks, (i, x, m, r) :: vs ->
      w32ok k0 && w32ok k1 && w32ok k2 && w32ok k3
      && w32ok k4 && w32ok k5 && w32ok k6 && w32ok k7
      (* m pinned to F.modulus's parity convention, not just positivity:
         gen_check duplicates that convention, and an unwatched drift
         would quietly move the draws off the domain the Feistel uses. *)
      && 0 < i && i <= 16 && 0 <= x
      && m = (if i % 2 = 1 then 6553600 else 13107200)
      && C.rf_real
           (U64.uint_to_t k0, U64.uint_to_t k1, U64.uint_to_t k2,
            U64.uint_to_t k3, U64.uint_to_t k4, U64.uint_to_t k5,
            U64.uint_to_t k6, U64.uint_to_t k7) () i x m = r
      && rf_ok ks vs
  | _, _ -> false

(* Counts pinned here for the same reason as everywhere else: a walker is
   vacuously true on empty lists. gen_check emits 16 draws over 4 keys. *)
let _ = assert_norm (L.length E.real_rf_keys = 16 && L.length E.real_rf = 16)
let _ = assert_norm (rf_ok E.real_rf_keys E.real_rf)
