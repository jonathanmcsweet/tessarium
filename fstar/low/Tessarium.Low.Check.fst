module Tessarium.Low.Check

/// KaRaMeL's extraction root: the machine-integer Feistel instantiated with
/// the cross-examination round function from `check/`.
///
/// The chain this closes: gen_check.ml runs the EXTRACTED OCaml core and
/// writes the answers down (Expected.fst and check_vectors.h);
/// check-extraction makes F*'s evaluator recompute them from the proved
/// source; and the C emitted from this module must reproduce them again --
/// three implementations, one set of numbers. The theorems at the bottom
/// state the C side's half of that triangle inside F*: what the machine
/// functions compute IS F.encrypt/F.decrypt with the harness round function.
///
/// Only `rf_low`, `check_encrypt` and `check_decrypt` survive extraction;
/// everything else is spec (Prims arithmetic, marked noextract or erased).

module S = Tessarium.Spec
module F = Tessarium.Feistel
module R = Tessarium.Check.Round
module L = Tessarium.Low.Feistel
module M = FStar.Math.Lemmas
module G = FStar.Ghost
module U64 = FStar.UInt64

/// Keys and tweaks for the check, bounded so the round sums stay far from
/// 2^64. gen_check's vectors use k <= 195 and t <= 77.
type key64 = k: U64.t{U64.v k < 4294967296}

/// The test round function over machine-typed keys, at the SPEC level.
/// Same formula as Tessarium.Check.Round.rf and ocaml/tools/gen_check.ml.
noextract
let rf_spec : F.round_fn key64 key64 =
  fun k t i x m -> (x * 31 + i * 1000003 + (U64.v k + U64.v t)) % m

let rf_ghost : G.erased (F.round_fn key64 key64) = G.hide rf_spec

/// The same formula over machine integers. The result refinement -- "equal
/// to what rf_spec returns" -- is the per-call agreement proof; the loop
/// specs in Tessarium.Low.Feistel lift it to the whole permutation.
/// Spelled with explicit binders rather than as `L.round_low rf_ghost`:
/// the type is the same, but KaRaMeL cannot express a value-dependent
/// abbreviation as a declared type and silently drops the definition.
let rf_low (k t: key64)
    (i: U64.t{0 < U64.v i /\ U64.v i <= F.rounds})
    (x: U64.t{U64.v x < S.fe_b})
    (m: U64.t{L.v64 m == F.modulus (U64.v i)})
  : (r: U64.t{L.v64 r == G.reveal rf_ghost k t (U64.v i) (U64.v x) (U64.v m)})
  = U64.rem (U64.add (U64.add (U64.mul x 31uL) (U64.mul i 1000003uL))
                     (U64.add k t))
            m

(* ------------------------------------------------------ extraction roots *)

let check_encrypt (k t: key64) (x: U64.t{U64.v x < S.addr_space})
  : (y: U64.t{U64.v y < S.addr_space})
  = L.encrypt_low #key64 #key64 #rf_ghost rf_low k t x

let check_decrypt (k t: key64) (y: U64.t{U64.v y < S.addr_space})
  : (x: U64.t{U64.v x < S.addr_space})
  = L.decrypt_low #key64 #key64 #rf_ghost rf_low k t y

(* ------------------------------------------- agreement with the harness *)

/// One formula, two spellings: on the same numbers, the machine-key spec
/// round function IS the harness round function from check/.
val lemma_rf_agrees (k t: key64) (i: nat{i <= F.rounds}) (x: nat) (m: pos)
  : Lemma (rf_spec k t i x m == R.rf (U64.v k) (U64.v t) i x m)
let lemma_rf_agrees k t i x m = ()

/// The Feistel only ever hands the round function its arguments, so
/// pointwise-equal round functions run the loops to the same place. Proved
/// by walking the rounds, since round functions are parameters rather than
/// definitions the SMT could unfold.
val lemma_enc_loop_agrees (k t: key64) (i: nat{i <= F.rounds}) (l r: nat)
  : Lemma (requires F.inv i l r)
          (ensures  F.enc_loop rf_spec k t i l r
                 == F.enc_loop R.rf (U64.v k) (U64.v t) i l r)
          (decreases F.rounds - i)
let rec lemma_enc_loop_agrees k t i l r =
  if i = F.rounds then ()
  else begin
    let j = i + 1 in
    let m = F.modulus j in
    let fr = rf_spec k t j r m in
    lemma_rf_agrees k t j r m;
    M.lemma_mod_lt (l + fr) m;
    lemma_enc_loop_agrees k t j r ((l + fr) % m)
  end

val lemma_dec_loop_agrees (k t: key64) (i: nat{i <= F.rounds}) (l r: nat)
  : Lemma (requires F.inv i l r)
          (ensures  F.dec_loop rf_spec k t i l r
                 == F.dec_loop R.rf (U64.v k) (U64.v t) i l r)
          (decreases i)
let rec lemma_dec_loop_agrees k t i l r =
  if i = 0 then ()
  else begin
    let m = F.modulus i in
    let fr = rf_spec k t i l m in
    lemma_rf_agrees k t i l m;
    M.lemma_mod_lt (r - fr + m) m;
    lemma_dec_loop_agrees k t (i - 1) ((r - fr + m) % m) l
  end

/// End to end: the number the extracted C computes is the number the
/// evaluator leg re-derives from the proved source. Both directions.
val theorem_check_encrypt (k t: key64) (x: U64.t{U64.v x < S.addr_space})
  : Lemma (L.v64 (check_encrypt k t x)
           == F.encrypt R.rf (U64.v k) (U64.v t) (U64.v x))
let theorem_check_encrypt k t x =
  let (l, r) = F.split (U64.v x) in
  lemma_enc_loop_agrees k t 0 l r

val theorem_check_decrypt (k t: key64) (y: U64.t{U64.v y < S.addr_space})
  : Lemma (L.v64 (check_decrypt k t y)
           == F.decrypt R.rf (U64.v k) (U64.v t) (U64.v y))
let theorem_check_decrypt k t y =
  let (l, r) = F.split (U64.v y) in
  lemma_dec_loop_agrees k t F.rounds l r
