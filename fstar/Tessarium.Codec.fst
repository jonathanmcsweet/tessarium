module Tessarium.Codec

/// Mixed radix (2048, 2048, 2048, 10000) over the permuted index.
///
/// Three BIP-39 word indices and a four-digit number. The trailing number is
/// what makes a 2048-word list sufficient; without it the list would need to be
/// around 40,000 words.

module M = FStar.Math.Lemmas

open Tessarium.Spec

type word_idx = w: nat{w < words}
type num_idx  = n: nat{n < num_max}
type address  = word_idx & word_idx & word_idx & num_idx

let to_address (i: nat{i < addr_space}) : address =
  lemma_div_bound i num_max (words * words * words);
  let q1 = i / num_max in
  lemma_div_bound q1 words (words * words);
  let q2 = q1 / words in
  lemma_div_bound q2 words words;
  M.lemma_mod_lt i num_max;
  M.lemma_mod_lt q1 words;
  M.lemma_mod_lt q2 words;
  (q2 / words, q2 % words, q1 % words, i % num_max)

let from_address (a: address) : (n: nat{n < addr_space}) =
  let (w1, w2, w3, n) = a in
  M.lemma_mult_le_right words w1 (words - 1);
  M.lemma_mult_le_right words (w1 * words + w2) (words * words - 1);
  M.lemma_mult_le_right num_max ((w1 * words + w2) * words + w3)
                                (words * words * words - 1);
  ((w1 * words + w2) * words + w3) * num_max + n

(* ================================================================ theorems *)

/// Mixed-radix decomposition is a bijection onto the address space.
///
/// Each digit is a quotient-remainder pair against its own radix, so this is
/// four applications of euclidean division and nothing more. It matters because
/// it is what makes "about 35% of addresses decode to nothing" a statement
/// about the grid not filling the space, rather than about the codec losing
/// information.
val theorem_roundtrip (i: nat{i < addr_space})
  : Lemma (from_address (to_address i) == i)
let theorem_roundtrip i =
  let q1 = i / num_max in
  let q2 = q1 / words in
  M.euclidean_division_definition i num_max;
  M.euclidean_division_definition q1 words;
  M.euclidean_division_definition q2 words

val theorem_roundtrip_address (a: address)
  : Lemma (to_address (from_address a) == a)
let theorem_roundtrip_address a =
  let (w1, w2, w3, n) = a in
  let i = from_address a in
  let q1 = (w1 * words + w2) * words + w3 in
  let q2 = w1 * words + w2 in
  // i = q1 * num_max + n with n < num_max, and so on down the radices
  M.lemma_div_plus n q1 num_max;
  M.small_div n num_max;
  M.lemma_mod_plus n q1 num_max;
  M.small_mod n num_max;
  M.lemma_div_plus w3 q2 words;
  M.small_div w3 words;
  M.lemma_mod_plus w3 q2 words;
  M.small_mod w3 words;
  M.lemma_div_plus w2 w1 words;
  M.small_div w2 words;
  M.lemma_mod_plus w2 w1 words;
  M.small_mod w2 words

/// The codec is injective, so two different indices never spell the same
/// address.
val theorem_injective (i1 i2: nat{i1 < addr_space /\ i2 < addr_space})
  : Lemma (requires to_address i1 == to_address i2) (ensures i1 == i2)
let theorem_injective i1 i2 = theorem_roundtrip i1; theorem_roundtrip i2
