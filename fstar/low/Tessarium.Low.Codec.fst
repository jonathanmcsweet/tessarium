module Tessarium.Low.Codec

/// The mixed-radix codec over 64-bit machine integers, for KaRaMeL.
/// Same discipline as the Feistel and grid ports: every ensures equates
/// the machine answer with Tessarium.Codec's, componentwise, and the
/// bijection theorems transfer by one appeal each.

module S = Tessarium.Spec
module C = Tessarium.Codec
module M = FStar.Math.Lemmas
module U64 = FStar.UInt64

unfold noextract
let v64 (x: U64.t) : int = U64.v x

let words64 : (c: U64.t{v64 c == S.words}) = 2048uL
let num_max64 : (c: U64.t{v64 c == S.num_max}) = 10000uL

let to_address_low (i: U64.t{U64.v i < S.addr_space})
  : Pure (U64.t & U64.t & U64.t & U64.t)
      (requires True)
      (ensures  fun (w1, w2, w3, n) ->
        (let (sw1, sw2, sw3, sn) = C.to_address (U64.v i) in
         v64 w1 == sw1 /\ v64 w2 == sw2 /\ v64 w3 == sw3 /\ v64 n == sn))
  = let q1 = U64.div i num_max64 in
    let q2 = U64.div q1 words64 in
    (U64.div q2 words64, U64.rem q2 words64,
     U64.rem q1 words64, U64.rem i num_max64)

let from_address_low
    (w1: U64.t{U64.v w1 < S.words}) (w2: U64.t{U64.v w2 < S.words})
    (w3: U64.t{U64.v w3 < S.words}) (n: U64.t{U64.v n < S.num_max})
  : Pure U64.t
      (requires True)
      (ensures  fun i ->
        v64 i == C.from_address (U64.v w1, U64.v w2, U64.v w3, U64.v n) /\
        U64.v i < S.addr_space)
  = M.lemma_mult_le_right S.words (U64.v w1) (S.words - 1);
    M.lemma_mult_le_right S.words (U64.v w1 * S.words + U64.v w2)
                                  (S.words * S.words - 1);
    M.lemma_mult_le_right S.num_max
      ((U64.v w1 * S.words + U64.v w2) * S.words + U64.v w3)
      (S.words * S.words * S.words - 1);
    U64.add
      (U64.mul (U64.add (U64.mul (U64.add (U64.mul w1 words64) w2) words64) w3)
               num_max64)
      n

val theorem_roundtrip_low (i: U64.t{U64.v i < S.addr_space})
  : Lemma (let (w1, w2, w3, n) = to_address_low i in
           U64.v w1 < S.words /\ U64.v w2 < S.words /\
           U64.v w3 < S.words /\ U64.v n < S.num_max /\
           from_address_low w1 w2 w3 n == i)
let theorem_roundtrip_low i =
  C.theorem_roundtrip (U64.v i);
  let (w1, w2, w3, n) = to_address_low i in
  U64.v_inj (from_address_low w1 w2 w3 n) i
