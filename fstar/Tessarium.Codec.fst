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
