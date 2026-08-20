module Tessarium.Low.Core

/// The PRODUCTION core: the machine-integer cipher and grid instantiated
/// with the real round function -- HMAC-SHA256 from Tessarium.Low.Hmac,
/// 128 bits reduced mod m, exactly ocaml/lib/crypto.ml's round_fn. This is
/// the module the OCaml server calls over the FFI and the browser runs as
/// WebAssembly; Tessarium.Low.Check remains the harness instantiation.
///
/// What is proved: the machine reduction below computes the same number as
/// the ghost spec `rf_real` (the Horner lemma), and therefore every
/// theorem of Low.Feistel/Low.Api -- round trip, injectivity, agreement
/// with Tessarium.Api -- holds with THIS round function plugged in; the
/// theorems at the bottom restate that. What is pinned instead of proved:
/// that rf_real transcribes crypto.ml's message layout, which digestif
/// recomputes on random draws in the harness (see Low.Hmac's header).

module S = Tessarium.Spec
module F = Tessarium.Feistel
module T = Tessarium.Table
module A = Tessarium.Api
module L = Tessarium.Low.Feistel
module LG = Tessarium.Low.Grid
module LA = Tessarium.Low.Api
module H = Tessarium.Low.Hmac
module M = FStar.Math.Lemmas
module G = FStar.Ghost
module U64 = FStar.UInt64

#set-options "--fuel 0 --ifuel 0 --z3rlimit 60"

(* ------------------------------------------------ the spec round function *)

/// The real round function at the spec level: total over the spec's nat
/// domain (inputs clamped into machine range -- the clamps are identities
/// everywhere the Feistel calls it, which the agreement proof below uses),
/// yielding HMAC's first 128 bits mod m.
#push-options "--ifuel 1"
noextract
let rf_real : F.round_fn H.key8 unit =
  fun k _ i x m ->
    let im = U64.uint_to_t (if i = 0 then 1 else i) in
    let xm = U64.uint_to_t (x % 0x1000000) in
    let (h0, h1, h2, h3) = H.hmac47 k im xm in
    (U64.v h0 * 0x1000000000000000000000000 +
     U64.v h1 * 0x10000000000000000 +
     U64.v h2 * 0x100000000 +
     U64.v h3) % m
#pop-options

let rf_real_ghost : G.erased (F.round_fn H.key8 unit) = G.hide rf_real

(* --------------------------------------------------- the machine reduction *)

/// One Horner step: reducing the running prefix mod m before the next
/// shift-and-add does not change the result mod m.
val horner_step (p r h: nat) (m: pos)
  : Lemma (requires r == p % m)
          (ensures  (r * 0x100000000 + h) % m == (p * 0x100000000 + h) % m)
let horner_step p r h m =
  M.lemma_mod_mul_distr_l p 0x100000000 m;
  M.lemma_mod_add_distr h ((p % m) * 0x100000000) m;
  M.lemma_mod_add_distr h (p * 0x100000000) m

/// The machine round function. 128 bits never exist as one integer: the
/// four digest words fold mod m left to right, and each intermediate stays
/// below m * 2^32 < 2^56 (m <= fe_b < 2^24), so the arithmetic is exact.
#push-options "--ifuel 1"
let rf_real_low (k: H.key8) (t: unit)
    (i: U64.t{0 < U64.v i /\ U64.v i <= F.rounds})
    (x: U64.t{U64.v x < S.fe_b})
    (m: U64.t{L.v64 m == F.modulus (U64.v i)})
  : (r: U64.t{L.v64 r == G.reveal rf_real_ghost k t (U64.v i) (U64.v x) (U64.v m)})
  =
  assert_norm (S.fe_a == 6553600);
  assert_norm (S.fe_b == 13107200);
  (* the spec's clamps are identities on this call domain *)
  M.small_mod (U64.v x) 0x1000000;
  U64.uv_inv i;
  U64.uv_inv x;
  let (h0, h1, h2, h3) = H.hmac47 k i x in
  let r0 = U64.rem h0 m in
  let r1 = U64.rem (U64.add (U64.mul r0 0x100000000uL) h1) m in
  let r2 = U64.rem (U64.add (U64.mul r1 0x100000000uL) h2) m in
  let r3 = U64.rem (U64.add (U64.mul r2 0x100000000uL) h3) m in
  horner_step (U64.v h0) (U64.v r0) (U64.v h1) (U64.v m);
  horner_step (U64.v h0 * 0x100000000 + U64.v h1) (U64.v r1) (U64.v h2) (U64.v m);
  horner_step ((U64.v h0 * 0x100000000 + U64.v h1) * 0x100000000 + U64.v h2)
    (U64.v r2) (U64.v h3) (U64.v m);
  r3
#pop-options

(* ------------------------------------------------------- extraction roots *)

/// Key arrives as eight flat words (the 32-byte PBKDF2 output, big-endian)
/// so the C ABI carries no struct layout.

let core_encrypt (k0 k1 k2 k3 k4 k5 k6 k7: H.w32)
    (x: U64.t{U64.v x < S.addr_space})
  : (y: U64.t{U64.v y < S.addr_space})
  = L.encrypt_low #H.key8 #unit #rf_real_ghost rf_real_low
      (k0, k1, k2, k3, k4, k5, k6, k7) () x

let core_decrypt (k0 k1 k2 k3 k4 k5 k6 k7: H.w32)
    (y: U64.t{U64.v y < S.addr_space})
  : (x: U64.t{U64.v x < S.addr_space})
  = L.decrypt_low #H.key8 #unit #rf_real_ghost rf_real_low
      (k0, k1, k2, k3, k4, k5, k6, k7) () y

let core_encode (cum: LG.cum_low) (k0 k1 k2 k3 k4 k5 k6 k7: H.w32)
    (dlat: U64.t{U64.v dlat <= S.lat_span})
    (dlon: U64.t{U64.v dlon <= S.lon_span})
  : U64.t & U64.t & U64.t & U64.t
  = LA.encode_low #H.key8 #unit #rf_real_ghost cum rf_real_low
      (k0, k1, k2, k3, k4, k5, k6, k7) () dlat dlon

let core_decode (cum: LG.cum_low) (k0 k1 k2 k3 k4 k5 k6 k7: H.w32)
    (w1: U64.t{U64.v w1 < S.words}) (w2: U64.t{U64.v w2 < S.words})
    (w3: U64.t{U64.v w3 < S.words}) (n: U64.t{U64.v n < S.num_max})
  : U64.t & U64.t & U64.t
  = LA.decode_low #H.key8 #unit #rf_real_ghost cum rf_real_low
      (k0, k1, k2, k3, k4, k5, k6, k7) () w1 w2 w3 n

let core_bounds (cum: LG.cum_low)
    (dlat: U64.t{U64.v dlat <= S.lat_span})
    (dlon: U64.t{U64.v dlon <= S.lon_span})
  : U64.t & U64.t & U64.t & U64.t
  = LA.bounds_of_point_low cum dlat dlon

(* --------------------------------------------------------------- theorems *)

/// The production C's encode IS Tessarium.Api.encode with the real round
/// function -- the composition the OCaml server computes today, word for
/// word. No agreement lemma is needed: the ghost index of the Feistel here
/// IS rf_real, so encode_low's ensures already says exactly this.
val theorem_core_encode (cum: LG.cum_low) (k0 k1 k2 k3 k4 k5 k6 k7: H.w32)
    (dlat: U64.t{U64.v dlat <= S.lat_span})
    (dlon: U64.t{U64.v dlon <= S.lon_span})
  : Lemma (let (w1, w2, w3, n) = core_encode cum k0 k1 k2 k3 k4 k5 k6 k7 dlat dlon in
           (let (s1, s2, s3, sn) =
              A.encode rf_real (k0, k1, k2, k3, k4, k5, k6, k7) ()
                (S.lat_min + U64.v dlat) (S.lon_min + U64.v dlon) in
            L.v64 w1 == s1 /\ L.v64 w2 == s2 /\
            L.v64 w3 == s3 /\ L.v64 n == sn))
let theorem_core_encode cum k0 k1 k2 k3 k4 k5 k6 k7 dlat dlon =
  T.lemma_fits ()

val theorem_core_decode (cum: LG.cum_low) (k0 k1 k2 k3 k4 k5 k6 k7: H.w32)
    (w1: U64.t{U64.v w1 < S.words}) (w2: U64.t{U64.v w2 < S.words})
    (w3: U64.t{U64.v w3 < S.words}) (n: U64.t{U64.v n < S.num_max})
  : Lemma (let (flag, dlat, dlon) = core_decode cum k0 k1 k2 k3 k4 k5 k6 k7 w1 w2 w3 n in
           (match A.decode rf_real (k0, k1, k2, k3, k4, k5, k6, k7) ()
                    (U64.v w1, U64.v w2, U64.v w3, U64.v n) with
            | None -> L.v64 flag == 0 /\ L.v64 dlat == 0 /\ L.v64 dlon == 0
            | Some (slat, slon) ->
                L.v64 flag == 1 /\
                L.v64 dlat == slat - S.lat_min /\
                L.v64 dlon == slon - S.lon_min))
let theorem_core_decode cum k0 k1 k2 k3 k4 k5 k6 k7 w1 w2 w3 n =
  T.lemma_fits ()

/// Round trip with the REAL round function: any in-range point, encoded
/// and decoded under the same key, lands back in the same cell. This is
/// the user-facing guarantee, now stated about the shipping arithmetic.
val theorem_core_roundtrip (k0 k1 k2 k3 k4 k5 k6 k7: H.w32)
    (x: U64.t{U64.v x < S.addr_space})
  : Lemma (core_decrypt k0 k1 k2 k3 k4 k5 k6 k7
             (core_encrypt k0 k1 k2 k3 k4 k5 k6 k7 x) == x)
let theorem_core_roundtrip k0 k1 k2 k3 k4 k5 k6 k7 x =
  L.theorem_roundtrip_low #H.key8 #unit #rf_real_ghost rf_real_low
    (k0, k1, k2, k3, k4, k5, k6, k7) () x
