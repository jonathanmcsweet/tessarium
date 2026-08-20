module Tessarium.Low.Hmac

/// SHA-256 (FIPS 180-4) and the production Feistel round function's HMAC,
/// in pure machine integers, so the REAL round function lives inside the
/// proof instead of being injected from OCaml.
///
/// What is proved here and what is pinned:
///
///   - Every word is a U64 kept below 2^32 by masking, so all overflow
///     obligations discharge by linear arithmetic (BOUNDS.md discipline);
///     rotations are div/mul by literal powers of two for the same reason.
///     FIPS defines SHA-256 over wrapping 32-bit words, so this masked
///     arithmetic IS the standard's arithmetic, not a model of it.
///   - That the constants and message layout below transcribe FIPS 180-4
///     and ocaml/lib/crypto.ml's round_fn correctly is NOT provable -- it
///     is pinned by vectors instead: NIST SHA-256 vectors drive `compress`
///     directly in the C harness, and digestif recomputes the composed
///     round function on random draws in check_vectors.h and Expected.fst.
///     A wrong FIPS constant fails the NIST pins and both digestif legs;
///     a wrong layout word fails the digestif legs alone (the C harness
///     and the evaluator) -- the falsification log demonstrates both
///     separations, and that diagnostic layering is deliberate.
///
/// The message this HMAC signs is fixed-shape (47 bytes): the production
/// key is exactly 32 bytes (PBKDF2 dklen=32) and the tweak is the constant
/// "tessarium-grid-2", so the whole HMAC is four compressions with
/// statically known padding -- which is why no buffers, loops or length
/// arithmetic appear anywhere in this file.
///
/// Deliberately NOT HACL*: its HMAC is written against LowStar's stateful
/// buffer model, and calling it would pull the whole pure Tot core into
/// the Stack effect. See the ledger entry for the tradeoff.

module U64 = FStar.UInt64
module UI = FStar.UInt

#set-options "--fuel 0 --ifuel 0 --z3rlimit 60"

/// A SHA word: a U64 provably below 2^32.
type w32 = x: U64.t{U64.v x < 0x100000000}

/// Mask to the low 32 bits. logand_mask gives the exact remainder
/// semantics, which is also the < 2^32 bound.
inline_for_extraction
let m32 (x: U64.t) : w32 =
  assert_norm (pow2 32 == 0x100000000);
  UI.logand_mask (U64.v x) 32;
  U64.logand x 0xffffffffuL

(* Bitwise helpers. Results re-masked so w32 discharges definitionally;
   the extra AND is folded by any C compiler. *)
inline_for_extraction
let xor32 (a b: U64.t) : w32 = m32 (U64.logxor a b)

inline_for_extraction
let and32 (a b: U64.t) : w32 = m32 (U64.logand a b)

inline_for_extraction
let not32 (a: U64.t) : w32 = m32 (U64.lognot a)

(* rotr n as (x >> n) + (x << (32-n)) on the low 32 bits: the two parts are
   bit-disjoint there, so the sum is the rotation. Spelled as division and
   multiplication by literals to keep every proof obligation linear; C
   compilers emit shifts for both. Pinned by the NIST vectors like
   everything else in this file. *)
inline_for_extraction
let rotr2 (x: w32) : w32 = m32 (U64.add (U64.div x 4uL) (U64.mul x 1073741824uL))
inline_for_extraction
let rotr6 (x: w32) : w32 = m32 (U64.add (U64.div x 64uL) (U64.mul x 67108864uL))
inline_for_extraction
let rotr7 (x: w32) : w32 = m32 (U64.add (U64.div x 128uL) (U64.mul x 33554432uL))
inline_for_extraction
let rotr11 (x: w32) : w32 = m32 (U64.add (U64.div x 2048uL) (U64.mul x 2097152uL))
inline_for_extraction
let rotr13 (x: w32) : w32 = m32 (U64.add (U64.div x 8192uL) (U64.mul x 524288uL))
inline_for_extraction
let rotr17 (x: w32) : w32 = m32 (U64.add (U64.div x 131072uL) (U64.mul x 32768uL))
inline_for_extraction
let rotr18 (x: w32) : w32 = m32 (U64.add (U64.div x 262144uL) (U64.mul x 16384uL))
inline_for_extraction
let rotr19 (x: w32) : w32 = m32 (U64.add (U64.div x 524288uL) (U64.mul x 8192uL))
inline_for_extraction
let rotr22 (x: w32) : w32 = m32 (U64.add (U64.div x 4194304uL) (U64.mul x 1024uL))
inline_for_extraction
let rotr25 (x: w32) : w32 = m32 (U64.add (U64.div x 33554432uL) (U64.mul x 128uL))

(* FIPS 180-4 section 4.1.2. shr 3 and shr 10 are the plain divisions. *)
inline_for_extraction
let bsig0 (x: w32) : w32 = xor32 (rotr2 x) (xor32 (rotr13 x) (rotr22 x))
inline_for_extraction
let bsig1 (x: w32) : w32 = xor32 (rotr6 x) (xor32 (rotr11 x) (rotr25 x))
inline_for_extraction
let ssig0 (x: w32) : w32 = xor32 (rotr7 x) (xor32 (rotr18 x) (U64.div x 8uL))
inline_for_extraction
let ssig1 (x: w32) : w32 = xor32 (rotr17 x) (xor32 (rotr19 x) (U64.div x 1024uL))

inline_for_extraction
let ch (e f g: w32) : w32 = xor32 (and32 e f) (and32 (not32 e) g)
inline_for_extraction
let maj (a b c: w32) : w32 = xor32 (and32 a b) (xor32 (and32 a c) (and32 b c))

/// The three per-round combinations and the schedule extension, verified
/// once each so the unrolled body below is nothing but application: every
/// obligation there is "this argument is a w32", already carried by the
/// helper types. Sums of at most five words stay below 5 * 2^32 < 2^64.
inline_for_extraction
let schedw (a b c d: w32) : w32 =
  m32 (U64.add (U64.add (ssig1 a) b) (U64.add (ssig0 c) d))

inline_for_extraction
let rt1 (h e f g kt wt: w32) : w32 =
  m32 (U64.add (U64.add (U64.add h (bsig1 e)) (U64.add (ch e f g) kt)) wt)

inline_for_extraction
let rna (t1 a b c: w32) : w32 =
  m32 (U64.add t1 (m32 (U64.add (bsig0 a) (maj a b c))))

inline_for_extraction
let rne (d t1: w32) : w32 = m32 (U64.add d t1)

inline_for_extraction
let add32 (x y: w32) : w32 = m32 (U64.add x y)

(* FIPS 180-4 section 5.3.3: H(0), frac(sqrt) of the first eight primes. *)
let iv0 : w32 = 0x6a09e667uL
let iv1 : w32 = 0xbb67ae85uL
let iv2 : w32 = 0x3c6ef372uL
let iv3 : w32 = 0xa54ff53auL
let iv4 : w32 = 0x510e527fuL
let iv5 : w32 = 0x9b05688cuL
let iv6 : w32 = 0x1f83d9abuL
let iv7 : w32 = 0x5be0cd19uL


/// Everything from the chunks up is [@@"opaque_to_smt"]: no downstream
/// proof ever needs these definitions (agreement with the OCaml round
/// function is pinned by vectors, and the Feistel theorems hold for any
/// round function), and leaving the defining equations visible lets Z3
/// unfold a four-compression chain into a term that took the VC from
/// one second to unbounded. The normalizer still reduces them, so the
/// evaluator leg can replay vectors through the proved source.

[@@"opaque_to_smt"]
let q0 (a b c d e f g h: w32) (w0 w1 w2 w3 w4 w5 w6 w7: w32)
  : (w32 & w32 & w32 & w32 & w32 & w32 & w32 & w32)
  =
  let t1_0 = rt1 h e f g 0x428a2f98uL w0 in
  let na0 = rna t1_0 a b c in
  let ne0 = rne d t1_0 in
  let t1_1 = rt1 g ne0 e f 0x71374491uL w1 in
  let na1 = rna t1_1 na0 a b in
  let ne1 = rne c t1_1 in
  let t1_2 = rt1 f ne1 ne0 e 0xb5c0fbcfuL w2 in
  let na2 = rna t1_2 na1 na0 a in
  let ne2 = rne b t1_2 in
  let t1_3 = rt1 e ne2 ne1 ne0 0xe9b5dba5uL w3 in
  let na3 = rna t1_3 na2 na1 na0 in
  let ne3 = rne a t1_3 in
  let t1_4 = rt1 ne0 ne3 ne2 ne1 0x3956c25buL w4 in
  let na4 = rna t1_4 na3 na2 na1 in
  let ne4 = rne na0 t1_4 in
  let t1_5 = rt1 ne1 ne4 ne3 ne2 0x59f111f1uL w5 in
  let na5 = rna t1_5 na4 na3 na2 in
  let ne5 = rne na1 t1_5 in
  let t1_6 = rt1 ne2 ne5 ne4 ne3 0x923f82a4uL w6 in
  let na6 = rna t1_6 na5 na4 na3 in
  let ne6 = rne na2 t1_6 in
  let t1_7 = rt1 ne3 ne6 ne5 ne4 0xab1c5ed5uL w7 in
  let na7 = rna t1_7 na6 na5 na4 in
  let ne7 = rne na3 t1_7 in
  (na7, na6, na5, na4, ne7, ne6, ne5, ne4)

[@@"opaque_to_smt"]
let q1 (a b c d e f g h: w32) (w0 w1 w2 w3 w4 w5 w6 w7: w32)
  : (w32 & w32 & w32 & w32 & w32 & w32 & w32 & w32)
  =
  let t1_0 = rt1 h e f g 0xd807aa98uL w0 in
  let na0 = rna t1_0 a b c in
  let ne0 = rne d t1_0 in
  let t1_1 = rt1 g ne0 e f 0x12835b01uL w1 in
  let na1 = rna t1_1 na0 a b in
  let ne1 = rne c t1_1 in
  let t1_2 = rt1 f ne1 ne0 e 0x243185beuL w2 in
  let na2 = rna t1_2 na1 na0 a in
  let ne2 = rne b t1_2 in
  let t1_3 = rt1 e ne2 ne1 ne0 0x550c7dc3uL w3 in
  let na3 = rna t1_3 na2 na1 na0 in
  let ne3 = rne a t1_3 in
  let t1_4 = rt1 ne0 ne3 ne2 ne1 0x72be5d74uL w4 in
  let na4 = rna t1_4 na3 na2 na1 in
  let ne4 = rne na0 t1_4 in
  let t1_5 = rt1 ne1 ne4 ne3 ne2 0x80deb1feuL w5 in
  let na5 = rna t1_5 na4 na3 na2 in
  let ne5 = rne na1 t1_5 in
  let t1_6 = rt1 ne2 ne5 ne4 ne3 0x9bdc06a7uL w6 in
  let na6 = rna t1_6 na5 na4 na3 in
  let ne6 = rne na2 t1_6 in
  let t1_7 = rt1 ne3 ne6 ne5 ne4 0xc19bf174uL w7 in
  let na7 = rna t1_7 na6 na5 na4 in
  let ne7 = rne na3 t1_7 in
  (na7, na6, na5, na4, ne7, ne6, ne5, ne4)

[@@"opaque_to_smt"]
let q2 (a b c d e f g h: w32) (w0 w1 w2 w3 w4 w5 w6 w7: w32)
  : (w32 & w32 & w32 & w32 & w32 & w32 & w32 & w32)
  =
  let t1_0 = rt1 h e f g 0xe49b69c1uL w0 in
  let na0 = rna t1_0 a b c in
  let ne0 = rne d t1_0 in
  let t1_1 = rt1 g ne0 e f 0xefbe4786uL w1 in
  let na1 = rna t1_1 na0 a b in
  let ne1 = rne c t1_1 in
  let t1_2 = rt1 f ne1 ne0 e 0x0fc19dc6uL w2 in
  let na2 = rna t1_2 na1 na0 a in
  let ne2 = rne b t1_2 in
  let t1_3 = rt1 e ne2 ne1 ne0 0x240ca1ccuL w3 in
  let na3 = rna t1_3 na2 na1 na0 in
  let ne3 = rne a t1_3 in
  let t1_4 = rt1 ne0 ne3 ne2 ne1 0x2de92c6fuL w4 in
  let na4 = rna t1_4 na3 na2 na1 in
  let ne4 = rne na0 t1_4 in
  let t1_5 = rt1 ne1 ne4 ne3 ne2 0x4a7484aauL w5 in
  let na5 = rna t1_5 na4 na3 na2 in
  let ne5 = rne na1 t1_5 in
  let t1_6 = rt1 ne2 ne5 ne4 ne3 0x5cb0a9dcuL w6 in
  let na6 = rna t1_6 na5 na4 na3 in
  let ne6 = rne na2 t1_6 in
  let t1_7 = rt1 ne3 ne6 ne5 ne4 0x76f988dauL w7 in
  let na7 = rna t1_7 na6 na5 na4 in
  let ne7 = rne na3 t1_7 in
  (na7, na6, na5, na4, ne7, ne6, ne5, ne4)

[@@"opaque_to_smt"]
let q3 (a b c d e f g h: w32) (w0 w1 w2 w3 w4 w5 w6 w7: w32)
  : (w32 & w32 & w32 & w32 & w32 & w32 & w32 & w32)
  =
  let t1_0 = rt1 h e f g 0x983e5152uL w0 in
  let na0 = rna t1_0 a b c in
  let ne0 = rne d t1_0 in
  let t1_1 = rt1 g ne0 e f 0xa831c66duL w1 in
  let na1 = rna t1_1 na0 a b in
  let ne1 = rne c t1_1 in
  let t1_2 = rt1 f ne1 ne0 e 0xb00327c8uL w2 in
  let na2 = rna t1_2 na1 na0 a in
  let ne2 = rne b t1_2 in
  let t1_3 = rt1 e ne2 ne1 ne0 0xbf597fc7uL w3 in
  let na3 = rna t1_3 na2 na1 na0 in
  let ne3 = rne a t1_3 in
  let t1_4 = rt1 ne0 ne3 ne2 ne1 0xc6e00bf3uL w4 in
  let na4 = rna t1_4 na3 na2 na1 in
  let ne4 = rne na0 t1_4 in
  let t1_5 = rt1 ne1 ne4 ne3 ne2 0xd5a79147uL w5 in
  let na5 = rna t1_5 na4 na3 na2 in
  let ne5 = rne na1 t1_5 in
  let t1_6 = rt1 ne2 ne5 ne4 ne3 0x06ca6351uL w6 in
  let na6 = rna t1_6 na5 na4 na3 in
  let ne6 = rne na2 t1_6 in
  let t1_7 = rt1 ne3 ne6 ne5 ne4 0x14292967uL w7 in
  let na7 = rna t1_7 na6 na5 na4 in
  let ne7 = rne na3 t1_7 in
  (na7, na6, na5, na4, ne7, ne6, ne5, ne4)

[@@"opaque_to_smt"]
let q4 (a b c d e f g h: w32) (w0 w1 w2 w3 w4 w5 w6 w7: w32)
  : (w32 & w32 & w32 & w32 & w32 & w32 & w32 & w32)
  =
  let t1_0 = rt1 h e f g 0x27b70a85uL w0 in
  let na0 = rna t1_0 a b c in
  let ne0 = rne d t1_0 in
  let t1_1 = rt1 g ne0 e f 0x2e1b2138uL w1 in
  let na1 = rna t1_1 na0 a b in
  let ne1 = rne c t1_1 in
  let t1_2 = rt1 f ne1 ne0 e 0x4d2c6dfcuL w2 in
  let na2 = rna t1_2 na1 na0 a in
  let ne2 = rne b t1_2 in
  let t1_3 = rt1 e ne2 ne1 ne0 0x53380d13uL w3 in
  let na3 = rna t1_3 na2 na1 na0 in
  let ne3 = rne a t1_3 in
  let t1_4 = rt1 ne0 ne3 ne2 ne1 0x650a7354uL w4 in
  let na4 = rna t1_4 na3 na2 na1 in
  let ne4 = rne na0 t1_4 in
  let t1_5 = rt1 ne1 ne4 ne3 ne2 0x766a0abbuL w5 in
  let na5 = rna t1_5 na4 na3 na2 in
  let ne5 = rne na1 t1_5 in
  let t1_6 = rt1 ne2 ne5 ne4 ne3 0x81c2c92euL w6 in
  let na6 = rna t1_6 na5 na4 na3 in
  let ne6 = rne na2 t1_6 in
  let t1_7 = rt1 ne3 ne6 ne5 ne4 0x92722c85uL w7 in
  let na7 = rna t1_7 na6 na5 na4 in
  let ne7 = rne na3 t1_7 in
  (na7, na6, na5, na4, ne7, ne6, ne5, ne4)

[@@"opaque_to_smt"]
let q5 (a b c d e f g h: w32) (w0 w1 w2 w3 w4 w5 w6 w7: w32)
  : (w32 & w32 & w32 & w32 & w32 & w32 & w32 & w32)
  =
  let t1_0 = rt1 h e f g 0xa2bfe8a1uL w0 in
  let na0 = rna t1_0 a b c in
  let ne0 = rne d t1_0 in
  let t1_1 = rt1 g ne0 e f 0xa81a664buL w1 in
  let na1 = rna t1_1 na0 a b in
  let ne1 = rne c t1_1 in
  let t1_2 = rt1 f ne1 ne0 e 0xc24b8b70uL w2 in
  let na2 = rna t1_2 na1 na0 a in
  let ne2 = rne b t1_2 in
  let t1_3 = rt1 e ne2 ne1 ne0 0xc76c51a3uL w3 in
  let na3 = rna t1_3 na2 na1 na0 in
  let ne3 = rne a t1_3 in
  let t1_4 = rt1 ne0 ne3 ne2 ne1 0xd192e819uL w4 in
  let na4 = rna t1_4 na3 na2 na1 in
  let ne4 = rne na0 t1_4 in
  let t1_5 = rt1 ne1 ne4 ne3 ne2 0xd6990624uL w5 in
  let na5 = rna t1_5 na4 na3 na2 in
  let ne5 = rne na1 t1_5 in
  let t1_6 = rt1 ne2 ne5 ne4 ne3 0xf40e3585uL w6 in
  let na6 = rna t1_6 na5 na4 na3 in
  let ne6 = rne na2 t1_6 in
  let t1_7 = rt1 ne3 ne6 ne5 ne4 0x106aa070uL w7 in
  let na7 = rna t1_7 na6 na5 na4 in
  let ne7 = rne na3 t1_7 in
  (na7, na6, na5, na4, ne7, ne6, ne5, ne4)

[@@"opaque_to_smt"]
let q6 (a b c d e f g h: w32) (w0 w1 w2 w3 w4 w5 w6 w7: w32)
  : (w32 & w32 & w32 & w32 & w32 & w32 & w32 & w32)
  =
  let t1_0 = rt1 h e f g 0x19a4c116uL w0 in
  let na0 = rna t1_0 a b c in
  let ne0 = rne d t1_0 in
  let t1_1 = rt1 g ne0 e f 0x1e376c08uL w1 in
  let na1 = rna t1_1 na0 a b in
  let ne1 = rne c t1_1 in
  let t1_2 = rt1 f ne1 ne0 e 0x2748774cuL w2 in
  let na2 = rna t1_2 na1 na0 a in
  let ne2 = rne b t1_2 in
  let t1_3 = rt1 e ne2 ne1 ne0 0x34b0bcb5uL w3 in
  let na3 = rna t1_3 na2 na1 na0 in
  let ne3 = rne a t1_3 in
  let t1_4 = rt1 ne0 ne3 ne2 ne1 0x391c0cb3uL w4 in
  let na4 = rna t1_4 na3 na2 na1 in
  let ne4 = rne na0 t1_4 in
  let t1_5 = rt1 ne1 ne4 ne3 ne2 0x4ed8aa4auL w5 in
  let na5 = rna t1_5 na4 na3 na2 in
  let ne5 = rne na1 t1_5 in
  let t1_6 = rt1 ne2 ne5 ne4 ne3 0x5b9cca4fuL w6 in
  let na6 = rna t1_6 na5 na4 na3 in
  let ne6 = rne na2 t1_6 in
  let t1_7 = rt1 ne3 ne6 ne5 ne4 0x682e6ff3uL w7 in
  let na7 = rna t1_7 na6 na5 na4 in
  let ne7 = rne na3 t1_7 in
  (na7, na6, na5, na4, ne7, ne6, ne5, ne4)

[@@"opaque_to_smt"]
let q7 (a b c d e f g h: w32) (w0 w1 w2 w3 w4 w5 w6 w7: w32)
  : (w32 & w32 & w32 & w32 & w32 & w32 & w32 & w32)
  =
  let t1_0 = rt1 h e f g 0x748f82eeuL w0 in
  let na0 = rna t1_0 a b c in
  let ne0 = rne d t1_0 in
  let t1_1 = rt1 g ne0 e f 0x78a5636fuL w1 in
  let na1 = rna t1_1 na0 a b in
  let ne1 = rne c t1_1 in
  let t1_2 = rt1 f ne1 ne0 e 0x84c87814uL w2 in
  let na2 = rna t1_2 na1 na0 a in
  let ne2 = rne b t1_2 in
  let t1_3 = rt1 e ne2 ne1 ne0 0x8cc70208uL w3 in
  let na3 = rna t1_3 na2 na1 na0 in
  let ne3 = rne a t1_3 in
  let t1_4 = rt1 ne0 ne3 ne2 ne1 0x90befffauL w4 in
  let na4 = rna t1_4 na3 na2 na1 in
  let ne4 = rne na0 t1_4 in
  let t1_5 = rt1 ne1 ne4 ne3 ne2 0xa4506cebuL w5 in
  let na5 = rna t1_5 na4 na3 na2 in
  let ne5 = rne na1 t1_5 in
  let t1_6 = rt1 ne2 ne5 ne4 ne3 0xbef9a3f7uL w6 in
  let na6 = rna t1_6 na5 na4 na3 in
  let ne6 = rne na2 t1_6 in
  let t1_7 = rt1 ne3 ne6 ne5 ne4 0xc67178f2uL w7 in
  let na7 = rna t1_7 na6 na5 na4 in
  let ne7 = rne na3 t1_7 in
  (na7, na6, na5, na4, ne7, ne6, ne5, ne4)

/// Eight schedule extensions from the previous sixteen words. The same
/// recurrence serves every chunk: only relative indices matter.
[@@"opaque_to_smt"]
let sched8 (w0 w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12 w13 w14 w15: w32)
  : (w32 & w32 & w32 & w32 & w32 & w32 & w32 & w32)
  =
  let w16 = schedw w14 w9 w1 w0 in
  let w17 = schedw w15 w10 w2 w1 in
  let w18 = schedw w16 w11 w3 w2 in
  let w19 = schedw w17 w12 w4 w3 in
  let w20 = schedw w18 w13 w5 w4 in
  let w21 = schedw w19 w14 w6 w5 in
  let w22 = schedw w20 w15 w7 w6 in
  let w23 = schedw w21 w16 w8 w7 in
  (w16, w17, w18, w19, w20, w21, w22, w23)

/// One SHA-256 compression. The 64 rounds live in eight 8-round chunks
/// (q0..q7) and the schedule in six sched8 calls, because a single flat
/// body sends the pure-WP substitution exponential: each state word feeds
/// several later rounds, and 64 rounds of that duplication was measured at
/// 8 rounds = 0.6s, 24 rounds = 5m. Function boundaries keep every value a
/// binder. Constants are FIPS 180-4 section 4.2.2, inline in the chunks;
/// flat arguments rather than a struct so the C harness can drive this
/// against the NIST vectors with no layout coupling.
#push-options "--ifuel 1"
let compress
    (a0 b0 c0 d0 e0 f0 g0 h0: w32)
    (w0 w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12 w13 w14 w15: w32)
  : (w32 & w32 & w32 & w32 & w32 & w32 & w32 & w32)
  =
  let (a1, b1, c1, d1, e1, f1, g1, h1) = q0 a0 b0 c0 d0 e0 f0 g0 h0 w0 w1 w2 w3 w4 w5 w6 w7 in
  let (a2, b2, c2, d2, e2, f2, g2, h2) = q1 a1 b1 c1 d1 e1 f1 g1 h1 w8 w9 w10 w11 w12 w13 w14 w15 in
  let (w16, w17, w18, w19, w20, w21, w22, w23) = sched8 w0 w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12 w13 w14 w15 in
  let (a3, b3, c3, d3, e3, f3, g3, h3) = q2 a2 b2 c2 d2 e2 f2 g2 h2 w16 w17 w18 w19 w20 w21 w22 w23 in
  let (w24, w25, w26, w27, w28, w29, w30, w31) = sched8 w8 w9 w10 w11 w12 w13 w14 w15 w16 w17 w18 w19 w20 w21 w22 w23 in
  let (a4, b4, c4, d4, e4, f4, g4, h4) = q3 a3 b3 c3 d3 e3 f3 g3 h3 w24 w25 w26 w27 w28 w29 w30 w31 in
  let (w32, w33, w34, w35, w36, w37, w38, w39) = sched8 w16 w17 w18 w19 w20 w21 w22 w23 w24 w25 w26 w27 w28 w29 w30 w31 in
  let (a5, b5, c5, d5, e5, f5, g5, h5) = q4 a4 b4 c4 d4 e4 f4 g4 h4 w32 w33 w34 w35 w36 w37 w38 w39 in
  let (w40, w41, w42, w43, w44, w45, w46, w47) = sched8 w24 w25 w26 w27 w28 w29 w30 w31 w32 w33 w34 w35 w36 w37 w38 w39 in
  let (a6, b6, c6, d6, e6, f6, g6, h6) = q5 a5 b5 c5 d5 e5 f5 g5 h5 w40 w41 w42 w43 w44 w45 w46 w47 in
  let (w48, w49, w50, w51, w52, w53, w54, w55) = sched8 w32 w33 w34 w35 w36 w37 w38 w39 w40 w41 w42 w43 w44 w45 w46 w47 in
  let (a7, b7, c7, d7, e7, f7, g7, h7) = q6 a6 b6 c6 d6 e6 f6 g6 h6 w48 w49 w50 w51 w52 w53 w54 w55 in
  let (w56, w57, w58, w59, w60, w61, w62, w63) = sched8 w40 w41 w42 w43 w44 w45 w46 w47 w48 w49 w50 w51 w52 w53 w54 w55 in
  let (a8, b8, c8, d8, e8, f8, g8, h8) = q7 a7 b7 c7 d7 e7 f7 g7 h7 w56 w57 w58 w59 w60 w61 w62 w63 in
  (add32 a0 a8, add32 b0 b8, add32 c0 c8, add32 d0 d8,
   add32 e0 e8, add32 f0 f8, add32 g0 g8, add32 h0 h8)
#pop-options

(* ---------------------------------------------- the fixed-shape HMAC *)

/// The production key: PBKDF2 output, exactly 32 bytes, as eight
/// big-endian words. HMAC pads it to the 64-byte block with zeros, so
/// K' = key || 0^32 and the ipad/opad blocks below are exact.
type key8 = w32 & w32 & w32 & w32 & w32 & w32 & w32 & w32

/// HMAC-SHA256 over the round-function message of ocaml/lib/crypto.ml:
///
///   "tessarium/v1/fe1" (18) || len16(tweak)=0x0012 || "tessarium-grid-2" (18)
///   || i (1 byte) || x (8 bytes BE)                              = 47 bytes
///
/// x < 2^24 makes the first five of its eight big-endian bytes zero, which
/// is why words 9-11 below take the shapes they do. Inner input is 64+47
/// bytes (bit length 888 = 0x378), outer is 64+32 (768 = 0x300); both pad
/// within two blocks, so the whole HMAC is these four compressions.
/// Returns the first four digest words -- the 128 bits crypto.ml reduces.
#push-options "--ifuel 1"
[@@"opaque_to_smt"]
let hmac47 (k: key8)
    (i: U64.t{0 < U64.v i /\ U64.v i <= 16})
    (x: U64.t{U64.v x < 0x1000000})
  : (w32 & w32 & w32 & w32)
  =
  let (k0, k1, k2, k3, k4, k5, k6, k7) = k in
  let p0 = xor32 k0 0x36363636uL in
  let p1 = xor32 k1 0x36363636uL in
  let p2 = xor32 k2 0x36363636uL in
  let p3 = xor32 k3 0x36363636uL in
  let p4 = xor32 k4 0x36363636uL in
  let p5 = xor32 k5 0x36363636uL in
  let p6 = xor32 k6 0x36363636uL in
  let p7 = xor32 k7 0x36363636uL in
  (* inner block 0: K' xor ipad *)
  let (ia, ib, ic, id, ie, if_, ig, ih) =
    compress iv0 iv1 iv2 iv3 iv4 iv5 iv6 iv7
      p0 p1 p2 p3 p4 p5 p6 p7
      0x36363636uL 0x36363636uL 0x36363636uL 0x36363636uL
      0x36363636uL 0x36363636uL 0x36363636uL 0x36363636uL in
  (* inner block 1: the 47-byte message, 0x80, zeros, bit length 888 *)
  let mw9 = m32 (U64.add 0x2D320000uL (U64.mul i 256uL)) in   (* "-2" || i || x[0]=0 *)
  let mw11 = m32 (U64.add (U64.mul x 256uL) 128uL) in         (* x[5..7] || 0x80 *)
  let (i0, i1, i2, i3, i4, i5, i6, i7) =
    compress ia ib ic id ie if_ ig ih
      0x63727970uL (* "cryp" *) 0x74657373uL (* "tess" *)
      0x6572612FuL (* "era/" *) 0x76312F66uL (* "v1/f" *)
      0x65310012uL (* "e1" || tweak length 18 *)
      0x63727970uL (* "cryp" *) 0x74657373uL (* "tess" *)
      0x6572612DuL (* "era-" *) 0x67726964uL (* "grid" *)
      mw9 0uL (* x[1..4] = 0 *) mw11
      0uL 0uL 0uL 0x378uL in
  (* outer block 0: K' xor opad *)
  let o0 = xor32 k0 0x5C5C5C5CuL in
  let o1 = xor32 k1 0x5C5C5C5CuL in
  let o2 = xor32 k2 0x5C5C5C5CuL in
  let o3 = xor32 k3 0x5C5C5C5CuL in
  let o4 = xor32 k4 0x5C5C5C5CuL in
  let o5 = xor32 k5 0x5C5C5C5CuL in
  let o6 = xor32 k6 0x5C5C5C5CuL in
  let o7 = xor32 k7 0x5C5C5C5CuL in
  let (oa, ob, oc, od, oe, of_, og, oh) =
    compress iv0 iv1 iv2 iv3 iv4 iv5 iv6 iv7
      o0 o1 o2 o3 o4 o5 o6 o7
      0x5C5C5C5CuL 0x5C5C5C5CuL 0x5C5C5C5CuL 0x5C5C5C5CuL
      0x5C5C5C5CuL 0x5C5C5C5CuL 0x5C5C5C5CuL 0x5C5C5C5CuL in
  (* outer block 1: inner digest, 0x80, zeros, bit length 768 *)
  let (r0, r1, r2, r3, r4, r5, r6, r7) =
    compress oa ob oc od oe of_ og oh
      i0 i1 i2 i3 i4 i5 i6 i7
      0x80000000uL 0uL 0uL 0uL 0uL 0uL 0uL 0x300uL in
  (r0, r1, r2, r3)
#pop-options
