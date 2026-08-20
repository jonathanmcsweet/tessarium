module Tessarium.Low.Blake2s

/// BLAKE2s (RFC 7693) and the production Feistel round function's keyed
/// MAC, in pure machine integers, so the REAL round function lives inside
/// the proof instead of being injected from OCaml. This file replaces the
/// HMAC-SHA256 of mapping v1: the project moved its security functions off
/// NIST designs onto community-vetted primitives (see the ledger), and
/// BLAKE2s keys natively, so the HMAC construction disappears -- the whole
/// MAC is TWO compressions (key block, then the fixed 47-byte message)
/// against HMAC's four.
///
/// What is proved here and what is pinned:
///
///   - Every word is a U64 kept below 2^32 by masking, so all overflow
///     obligations discharge by linear arithmetic (BOUNDS.md discipline);
///     rotations are div/mul by literal powers of two for the same reason.
///     RFC 7693 defines BLAKE2s over wrapping 32-bit words, so this masked
///     arithmetic IS the standard's arithmetic, not a model of it.
///   - That the constants below (IV, the sigma wiring baked into r0..r9,
///     the parameter-block word, the message layout) transcribe RFC 7693
///     and ocaml/lib/crypto.ml's round_fn correctly is NOT provable -- it
///     is pinned by vectors instead: the RFC's "abc" digest and the
///     official keyed KAT drive `compress` through a generic harness in
///     check_main.c, and digestif recomputes the composed round function
///     on random draws in check_vectors.h and Expected.fst. A wrong sigma
///     or rotation fails the KAT pins and both digestif legs; a wrong
///     layout word fails the digestif legs alone -- the same diagnostic
///     layering the v1 falsification log demonstrated.
///
/// The message this MAC signs is fixed-shape (47 bytes): the production
/// key is exactly 32 bytes and the tweak is the constant
/// "tessarium-grid-2", so both blocks have statically known padding --
/// which is why no buffers, loops or length arithmetic appear anywhere in
/// this file. BLAKE2s is little-endian throughout, and the v2 protocol
/// reads the first 16 digest bytes as a little-endian integer, so no word
/// ever needs a byte swap.

module U64 = FStar.UInt64
module UI = FStar.UInt

#set-options "--fuel 0 --ifuel 0 --z3rlimit 60"

/// A BLAKE2s word: a U64 provably below 2^32.
type w32 = x: U64.t{U64.v x < 0x100000000}

/// Mask to the low 32 bits. logand_mask gives the exact remainder
/// semantics, which is also the < 2^32 bound.
inline_for_extraction
let m32 (x: U64.t) : w32 =
  assert_norm (pow2 32 == 0x100000000);
  UI.logand_mask (U64.v x) 32;
  U64.logand x 0xffffffffuL

inline_for_extraction
let xor32 (a b: U64.t) : w32 = m32 (U64.logxor a b)

inline_for_extraction
let add32 (x y: w32) : w32 = m32 (U64.add x y)

(* A sum of three words stays below 3 * 2^32 < 2^64. *)
inline_for_extraction
let add3 (a b x: w32) : w32 = m32 (U64.add (U64.add a b) x)

(* rotr n as (x >> n) + (x << (32-n)) on the low 32 bits: the two parts
   are bit-disjoint there, so the sum is the rotation. Spelled as division
   and multiplication by literals to keep every proof obligation linear; C
   compilers emit shifts for both. RFC 7693's four rotation distances. *)
inline_for_extraction
let rotr16 (x: w32) : w32 = m32 (U64.add (U64.div x 65536uL) (U64.mul x 65536uL))
inline_for_extraction
let rotr12 (x: w32) : w32 = m32 (U64.add (U64.div x 4096uL) (U64.mul x 1048576uL))
inline_for_extraction
let rotr8 (x: w32) : w32 = m32 (U64.add (U64.div x 256uL) (U64.mul x 16777216uL))
inline_for_extraction
let rotr7 (x: w32) : w32 = m32 (U64.add (U64.div x 128uL) (U64.mul x 33554432uL))

/// RFC 7693 section 3.1: the quarter-round. Verified once; the unrolled
/// round bodies below are nothing but application of this and each
/// obligation there is "this argument is a w32", already carried by the
/// binder types.
inline_for_extraction
let g (a b c d x y: w32) : (w32 & w32 & w32 & w32) =
  let a = add3 a b x in
  let d = rotr16 (xor32 d a) in
  let c = add32 c d in
  let b = rotr12 (xor32 b c) in
  let a = add3 a b y in
  let d = rotr8 (xor32 d a) in
  let c = add32 c d in
  let b = rotr7 (xor32 b c) in
  (a, b, c, d)

type st8 = w32 & w32 & w32 & w32 & w32 & w32 & w32 & w32

(* RFC 7693 section 2.6: the IV -- frac(sqrt) of the first eight primes,
   the same words as SHA-256's H(0). *)
let iv0 : w32 = 0x6a09e667uL
let iv1 : w32 = 0xbb67ae85uL
let iv2 : w32 = 0x3c6ef372uL
let iv3 : w32 = 0xa54ff53auL
let iv4 : w32 = 0x510e527fuL
let iv5 : w32 = 0x9b05688cuL
let iv6 : w32 = 0x1f83d9abuL
let iv7 : w32 = 0x5be0cd19uL

/// One round each, sigma wiring baked in as literal argument order
/// (RFC 7693 section 2.7's SIGMA table -- pinned by the KATs like every
/// other constant here). Ten top-level functions rather than one flat
/// body: the v1 SHA-256 port measured a flat unrolling sending the pure
/// WP substitution exponential, and function boundaries keep every value
/// a binder. F* tuples stop at arity 14, so state travels as two st8s.
///
/// Everything from these rounds up is [@@"opaque_to_smt"]: no downstream
/// proof ever needs the defining equations (agreement with the OCaml
/// round function is pinned by vectors, and the Feistel theorems hold for
/// any round function), and leaving them visible lets Z3 unfold a chain
/// of compressions into an unbounded term. The normalizer still reduces
/// them, so the evaluator leg can replay vectors through the proved
/// source.
#push-options "--ifuel 1"
[@@"opaque_to_smt"]
let r0 (v0 v1 v2 v3 v4 v5 v6 v7 v8 v9 v10 v11 v12 v13 v14 v15: w32)
    (m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15: w32)
  : (st8 & st8)
  =
  let (v0, v4, v8, v12) = g v0 v4 v8 v12 m0 m1 in
  let (v1, v5, v9, v13) = g v1 v5 v9 v13 m2 m3 in
  let (v2, v6, v10, v14) = g v2 v6 v10 v14 m4 m5 in
  let (v3, v7, v11, v15) = g v3 v7 v11 v15 m6 m7 in
  let (v0, v5, v10, v15) = g v0 v5 v10 v15 m8 m9 in
  let (v1, v6, v11, v12) = g v1 v6 v11 v12 m10 m11 in
  let (v2, v7, v8, v13) = g v2 v7 v8 v13 m12 m13 in
  let (v3, v4, v9, v14) = g v3 v4 v9 v14 m14 m15 in
  ((v0, v1, v2, v3, v4, v5, v6, v7),
   (v8, v9, v10, v11, v12, v13, v14, v15))
#pop-options

#push-options "--ifuel 1"
[@@"opaque_to_smt"]
let r1 (v0 v1 v2 v3 v4 v5 v6 v7 v8 v9 v10 v11 v12 v13 v14 v15: w32)
    (m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15: w32)
  : (st8 & st8)
  =
  let (v0, v4, v8, v12) = g v0 v4 v8 v12 m14 m10 in
  let (v1, v5, v9, v13) = g v1 v5 v9 v13 m4 m8 in
  let (v2, v6, v10, v14) = g v2 v6 v10 v14 m9 m15 in
  let (v3, v7, v11, v15) = g v3 v7 v11 v15 m13 m6 in
  let (v0, v5, v10, v15) = g v0 v5 v10 v15 m1 m12 in
  let (v1, v6, v11, v12) = g v1 v6 v11 v12 m0 m2 in
  let (v2, v7, v8, v13) = g v2 v7 v8 v13 m11 m7 in
  let (v3, v4, v9, v14) = g v3 v4 v9 v14 m5 m3 in
  ((v0, v1, v2, v3, v4, v5, v6, v7),
   (v8, v9, v10, v11, v12, v13, v14, v15))
#pop-options

#push-options "--ifuel 1"
[@@"opaque_to_smt"]
let r2 (v0 v1 v2 v3 v4 v5 v6 v7 v8 v9 v10 v11 v12 v13 v14 v15: w32)
    (m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15: w32)
  : (st8 & st8)
  =
  let (v0, v4, v8, v12) = g v0 v4 v8 v12 m11 m8 in
  let (v1, v5, v9, v13) = g v1 v5 v9 v13 m12 m0 in
  let (v2, v6, v10, v14) = g v2 v6 v10 v14 m5 m2 in
  let (v3, v7, v11, v15) = g v3 v7 v11 v15 m15 m13 in
  let (v0, v5, v10, v15) = g v0 v5 v10 v15 m10 m14 in
  let (v1, v6, v11, v12) = g v1 v6 v11 v12 m3 m6 in
  let (v2, v7, v8, v13) = g v2 v7 v8 v13 m7 m1 in
  let (v3, v4, v9, v14) = g v3 v4 v9 v14 m9 m4 in
  ((v0, v1, v2, v3, v4, v5, v6, v7),
   (v8, v9, v10, v11, v12, v13, v14, v15))
#pop-options

#push-options "--ifuel 1"
[@@"opaque_to_smt"]
let r3 (v0 v1 v2 v3 v4 v5 v6 v7 v8 v9 v10 v11 v12 v13 v14 v15: w32)
    (m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15: w32)
  : (st8 & st8)
  =
  let (v0, v4, v8, v12) = g v0 v4 v8 v12 m7 m9 in
  let (v1, v5, v9, v13) = g v1 v5 v9 v13 m3 m1 in
  let (v2, v6, v10, v14) = g v2 v6 v10 v14 m13 m12 in
  let (v3, v7, v11, v15) = g v3 v7 v11 v15 m11 m14 in
  let (v0, v5, v10, v15) = g v0 v5 v10 v15 m2 m6 in
  let (v1, v6, v11, v12) = g v1 v6 v11 v12 m5 m10 in
  let (v2, v7, v8, v13) = g v2 v7 v8 v13 m4 m0 in
  let (v3, v4, v9, v14) = g v3 v4 v9 v14 m15 m8 in
  ((v0, v1, v2, v3, v4, v5, v6, v7),
   (v8, v9, v10, v11, v12, v13, v14, v15))
#pop-options

#push-options "--ifuel 1"
[@@"opaque_to_smt"]
let r4 (v0 v1 v2 v3 v4 v5 v6 v7 v8 v9 v10 v11 v12 v13 v14 v15: w32)
    (m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15: w32)
  : (st8 & st8)
  =
  let (v0, v4, v8, v12) = g v0 v4 v8 v12 m9 m0 in
  let (v1, v5, v9, v13) = g v1 v5 v9 v13 m5 m7 in
  let (v2, v6, v10, v14) = g v2 v6 v10 v14 m2 m4 in
  let (v3, v7, v11, v15) = g v3 v7 v11 v15 m10 m15 in
  let (v0, v5, v10, v15) = g v0 v5 v10 v15 m14 m1 in
  let (v1, v6, v11, v12) = g v1 v6 v11 v12 m11 m12 in
  let (v2, v7, v8, v13) = g v2 v7 v8 v13 m6 m8 in
  let (v3, v4, v9, v14) = g v3 v4 v9 v14 m3 m13 in
  ((v0, v1, v2, v3, v4, v5, v6, v7),
   (v8, v9, v10, v11, v12, v13, v14, v15))
#pop-options

#push-options "--ifuel 1"
[@@"opaque_to_smt"]
let r5 (v0 v1 v2 v3 v4 v5 v6 v7 v8 v9 v10 v11 v12 v13 v14 v15: w32)
    (m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15: w32)
  : (st8 & st8)
  =
  let (v0, v4, v8, v12) = g v0 v4 v8 v12 m2 m12 in
  let (v1, v5, v9, v13) = g v1 v5 v9 v13 m6 m10 in
  let (v2, v6, v10, v14) = g v2 v6 v10 v14 m0 m11 in
  let (v3, v7, v11, v15) = g v3 v7 v11 v15 m8 m3 in
  let (v0, v5, v10, v15) = g v0 v5 v10 v15 m4 m13 in
  let (v1, v6, v11, v12) = g v1 v6 v11 v12 m7 m5 in
  let (v2, v7, v8, v13) = g v2 v7 v8 v13 m15 m14 in
  let (v3, v4, v9, v14) = g v3 v4 v9 v14 m1 m9 in
  ((v0, v1, v2, v3, v4, v5, v6, v7),
   (v8, v9, v10, v11, v12, v13, v14, v15))
#pop-options

#push-options "--ifuel 1"
[@@"opaque_to_smt"]
let r6 (v0 v1 v2 v3 v4 v5 v6 v7 v8 v9 v10 v11 v12 v13 v14 v15: w32)
    (m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15: w32)
  : (st8 & st8)
  =
  let (v0, v4, v8, v12) = g v0 v4 v8 v12 m12 m5 in
  let (v1, v5, v9, v13) = g v1 v5 v9 v13 m1 m15 in
  let (v2, v6, v10, v14) = g v2 v6 v10 v14 m14 m13 in
  let (v3, v7, v11, v15) = g v3 v7 v11 v15 m4 m10 in
  let (v0, v5, v10, v15) = g v0 v5 v10 v15 m0 m7 in
  let (v1, v6, v11, v12) = g v1 v6 v11 v12 m6 m3 in
  let (v2, v7, v8, v13) = g v2 v7 v8 v13 m9 m2 in
  let (v3, v4, v9, v14) = g v3 v4 v9 v14 m8 m11 in
  ((v0, v1, v2, v3, v4, v5, v6, v7),
   (v8, v9, v10, v11, v12, v13, v14, v15))
#pop-options

#push-options "--ifuel 1"
[@@"opaque_to_smt"]
let r7 (v0 v1 v2 v3 v4 v5 v6 v7 v8 v9 v10 v11 v12 v13 v14 v15: w32)
    (m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15: w32)
  : (st8 & st8)
  =
  let (v0, v4, v8, v12) = g v0 v4 v8 v12 m13 m11 in
  let (v1, v5, v9, v13) = g v1 v5 v9 v13 m7 m14 in
  let (v2, v6, v10, v14) = g v2 v6 v10 v14 m12 m1 in
  let (v3, v7, v11, v15) = g v3 v7 v11 v15 m3 m9 in
  let (v0, v5, v10, v15) = g v0 v5 v10 v15 m5 m0 in
  let (v1, v6, v11, v12) = g v1 v6 v11 v12 m15 m4 in
  let (v2, v7, v8, v13) = g v2 v7 v8 v13 m8 m6 in
  let (v3, v4, v9, v14) = g v3 v4 v9 v14 m2 m10 in
  ((v0, v1, v2, v3, v4, v5, v6, v7),
   (v8, v9, v10, v11, v12, v13, v14, v15))
#pop-options

#push-options "--ifuel 1"
[@@"opaque_to_smt"]
let r8 (v0 v1 v2 v3 v4 v5 v6 v7 v8 v9 v10 v11 v12 v13 v14 v15: w32)
    (m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15: w32)
  : (st8 & st8)
  =
  let (v0, v4, v8, v12) = g v0 v4 v8 v12 m6 m15 in
  let (v1, v5, v9, v13) = g v1 v5 v9 v13 m14 m9 in
  let (v2, v6, v10, v14) = g v2 v6 v10 v14 m11 m3 in
  let (v3, v7, v11, v15) = g v3 v7 v11 v15 m0 m8 in
  let (v0, v5, v10, v15) = g v0 v5 v10 v15 m12 m2 in
  let (v1, v6, v11, v12) = g v1 v6 v11 v12 m13 m7 in
  let (v2, v7, v8, v13) = g v2 v7 v8 v13 m1 m4 in
  let (v3, v4, v9, v14) = g v3 v4 v9 v14 m10 m5 in
  ((v0, v1, v2, v3, v4, v5, v6, v7),
   (v8, v9, v10, v11, v12, v13, v14, v15))
#pop-options

#push-options "--ifuel 1"
[@@"opaque_to_smt"]
let r9 (v0 v1 v2 v3 v4 v5 v6 v7 v8 v9 v10 v11 v12 v13 v14 v15: w32)
    (m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15: w32)
  : (st8 & st8)
  =
  let (v0, v4, v8, v12) = g v0 v4 v8 v12 m10 m2 in
  let (v1, v5, v9, v13) = g v1 v5 v9 v13 m8 m4 in
  let (v2, v6, v10, v14) = g v2 v6 v10 v14 m7 m6 in
  let (v3, v7, v11, v15) = g v3 v7 v11 v15 m1 m5 in
  let (v0, v5, v10, v15) = g v0 v5 v10 v15 m15 m11 in
  let (v1, v6, v11, v12) = g v1 v6 v11 v12 m9 m14 in
  let (v2, v7, v8, v13) = g v2 v7 v8 v13 m3 m12 in
  let (v3, v4, v9, v14) = g v3 v4 v9 v14 m13 m0 in
  ((v0, v1, v2, v3, v4, v5, v6, v7),
   (v8, v9, v10, v11, v12, v13, v14, v15))
#pop-options

/// One BLAKE2s compression (RFC 7693 section 3.2). `t` is the low word
/// of the byte counter -- the high word is zero for every message this
/// project can ever see -- and `f` is the finalization word (0 or
/// 0xffffffff). Flat arguments rather than a struct so the C harness can
/// drive this against the RFC and KAT vectors with no layout coupling.
#push-options "--ifuel 1"
let compress (h0 h1 h2 h3 h4 h5 h6 h7: w32)
    (m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15: w32)
    (t f: w32)
  : st8
  =
  let v12 = xor32 iv4 t in
  let v14 = xor32 iv6 f in
  let ((a1, b1, c1, d1, e1, f1, g1, i1),
       (j1, k1, l1, n1, o1, p1, q1, s1)) =
    r0 h0 h1 h2 h3 h4 h5 h6 h7 iv0 iv1 iv2 iv3 v12 iv5 v14 iv7 m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15 in
  let ((a2, b2, c2, d2, e2, f2, g2, i2),
       (j2, k2, l2, n2, o2, p2, q2, s2)) =
    r1 a1 b1 c1 d1 e1 f1 g1 i1 j1 k1 l1 n1 o1 p1 q1 s1 m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15 in
  let ((a3, b3, c3, d3, e3, f3, g3, i3),
       (j3, k3, l3, n3, o3, p3, q3, s3)) =
    r2 a2 b2 c2 d2 e2 f2 g2 i2 j2 k2 l2 n2 o2 p2 q2 s2 m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15 in
  let ((a4, b4, c4, d4, e4, f4, g4, i4),
       (j4, k4, l4, n4, o4, p4, q4, s4)) =
    r3 a3 b3 c3 d3 e3 f3 g3 i3 j3 k3 l3 n3 o3 p3 q3 s3 m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15 in
  let ((a5, b5, c5, d5, e5, f5, g5, i5),
       (j5, k5, l5, n5, o5, p5, q5, s5)) =
    r4 a4 b4 c4 d4 e4 f4 g4 i4 j4 k4 l4 n4 o4 p4 q4 s4 m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15 in
  let ((a6, b6, c6, d6, e6, f6, g6, i6),
       (j6, k6, l6, n6, o6, p6, q6, s6)) =
    r5 a5 b5 c5 d5 e5 f5 g5 i5 j5 k5 l5 n5 o5 p5 q5 s5 m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15 in
  let ((a7, b7, c7, d7, e7, f7, g7, i7),
       (j7, k7, l7, n7, o7, p7, q7, s7)) =
    r6 a6 b6 c6 d6 e6 f6 g6 i6 j6 k6 l6 n6 o6 p6 q6 s6 m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15 in
  let ((a8, b8, c8, d8, e8, f8, g8, i8),
       (j8, k8, l8, n8, o8, p8, q8, s8)) =
    r7 a7 b7 c7 d7 e7 f7 g7 i7 j7 k7 l7 n7 o7 p7 q7 s7 m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15 in
  let ((a9, b9, c9, d9, e9, f9, g9, i9),
       (j9, k9, l9, n9, o9, p9, q9, s9)) =
    r8 a8 b8 c8 d8 e8 f8 g8 i8 j8 k8 l8 n8 o8 p8 q8 s8 m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15 in
  let ((a10, b10, c10, d10, e10, f10, g10, i10),
       (j10, k10, l10, n10, o10, p10, q10, s10)) =
    r9 a9 b9 c9 d9 e9 f9 g9 i9 j9 k9 l9 n9 o9 p9 q9 s9 m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15 in
  (xor32 h0 (xor32 a10 j10), xor32 h1 (xor32 b10 k10),
   xor32 h2 (xor32 c10 l10), xor32 h3 (xor32 d10 n10),
   xor32 h4 (xor32 e10 o10), xor32 h5 (xor32 f10 p10),
   xor32 h6 (xor32 g10 q10), xor32 h7 (xor32 i10 s10))
#pop-options

(* ------------------------------------------- the fixed-shape keyed MAC *)

/// The production key: the KDF's 32-byte output as eight LITTLE-endian
/// words -- BLAKE2s's own byte order, unlike v1's big-endian SHA words.
/// Keyed BLAKE2s processes K || 0^32 as the first block, so the key words
/// are message words m0..m7 of that block and the block needs no other
/// data.
type key8 = st8

/// Keyed BLAKE2s-256 over the round-function message of
/// ocaml/lib/crypto.ml:
///
///   "tessarium/v2/fe1" (18) || len16(tweak)=0x0012 || "tessarium-grid-2" (18)
///   || i (1 byte) || x (8 bytes BE)                              = 47 bytes
///
/// x < 2^24 makes the first five of its eight big-endian bytes zero,
/// which is why little-endian words 9-11 below take the shapes they do.
/// Parameter block: digest length 32, key length 32, fanout=depth=1, so
/// h0 = IV0 xor 0x01012020. Key block: t=64, not final. Message block:
/// t=64+47=111, final. Returns the first four digest words -- the 128
/// bits crypto.ml reduces, little-endian.
#push-options "--ifuel 1"
[@@"opaque_to_smt"]
let blake2s47 (k: key8)
    (i: U64.t{0 < U64.v i /\ U64.v i <= 16})
    (x: U64.t{U64.v x < 0x1000000})
  : (w32 & w32 & w32 & w32)
  =
  let (k0, k1, k2, k3, k4, k5, k6, k7) = k in
  (* key block: K || 0^32, t = 64 *)
  let (a0, a1, a2, a3, a4, a5, a6, a7) =
    compress 0x6B08C647uL iv1 iv2 iv3 iv4 iv5 iv6 iv7
      k0 k1 k2 k3 k4 k5 k6 k7
      0uL 0uL 0uL 0uL 0uL 0uL 0uL 0uL
      64uL 0uL in
  (* final block: the 47 message bytes, zero-padded; t = 111 *)
  let mw9 = m32 (U64.add 0x322DuL (U64.mul i 65536uL)) in   (* "-2" || i || x[0]=0 *)
  (* x's low three big-endian bytes land in one little-endian word:
     byte 44 is x[5] = x / 2^16, byte 45 is x[6], byte 46 is x[7] = x mod
     256, byte 47 is padding zero. *)
  let mw11 =
    m32 (U64.add (U64.div x 65536uL)
           (U64.add (U64.mul (U64.rem (U64.div x 256uL) 256uL) 256uL)
              (U64.mul (U64.rem x 256uL) 65536uL))) in
  let (b0, b1, b2, b3, _, _, _, _) =
    compress a0 a1 a2 a3 a4 a5 a6 a7
      0x70797263uL (* "cryp" *) 0x73736574uL (* "tess" *)
      0x2F617265uL (* "era/" *) 0x662F3276uL (* "v2/f" *)
      0x12003165uL (* "e1" || tweak length 18 *)
      0x70797263uL (* "cryp" *) 0x73736574uL (* "tess" *)
      0x2D617265uL (* "era-" *) 0x64697267uL (* "grid" *)
      mw9 0uL (* x[1..4] = 0 *) mw11
      0uL 0uL 0uL 0uL
      111uL 0xffffffffuL in
  (b0, b1, b2, b3)
#pop-options
