module Tessarium.Feistel

/// FE1 generalized Feistel over Z_a x Z_b (Black & Rogaway, CT-RSA 2002).
/// NOT YET VERIFIED.
///
/// The domain size is exactly addr_space, so this is a bijection with no
/// cycle-walking and therefore no probabilistic termination argument.

open FStar.Mul
open Tessarium.Spec

let rounds : pos = 10        // must be even: halves swap domains each round

type index = x:nat{x < addr_space}
type key   = FStar.Seq.lseq FStar.UInt8.t 32
type tweak = s:FStar.Seq.seq FStar.UInt8.t{FStar.Seq.length s < 65536}

/// The round function is a parameter. Bijectivity does not depend on it
/// being cryptographic — that assumption is needed only for
/// unpredictability, which no proof assistant will discharge.
type round_fn = key -> tweak -> i:nat{i <= rounds} -> nat -> m:pos -> r:nat{r < m}

val encrypt : round_fn -> key -> tweak -> index -> index
val decrypt : round_fn -> key -> tweak -> index -> index

/// THEOREM. Round-trip, for ANY round function. Follows structurally from
/// Feistel invertibility.
val theorem_roundtrip (f: round_fn) (k: key) (t: tweak) (x: index)
  : Lemma (decrypt f k t (encrypt f k t x) == x)

val theorem_roundtrip_rev (f: round_fn) (k: key) (t: tweak) (y: index)
  : Lemma (encrypt f k t (decrypt f k t y) == y)

/// THEOREM. Therefore a permutation: injective and surjective on [0, addr_space).
val theorem_injective (f: round_fn) (k: key) (t: tweak) (x1 x2: index)
  : Lemma (requires encrypt f k t x1 == encrypt f k t x2) (ensures x1 == x2)

val theorem_surjective (f: round_fn) (k: key) (t: tweak) (y: index)
  : Lemma (exists (x: index). encrypt f k t x == y)
