open Prims
type word_idx = Prims.nat
type num_idx = Prims.nat
type address = (word_idx * word_idx * word_idx * num_idx)
let to_address (i : Prims.nat) : address=
  let q1 = i / Tessarium_Spec.num_max in
  let q2 = q1 / Tessarium_Spec.words in
  ((q2 / Tessarium_Spec.words), ((mod) q2 Tessarium_Spec.words),
    ((mod) q1 Tessarium_Spec.words), ((mod) i Tessarium_Spec.num_max))
let from_address (a : address) : Prims.nat=
  let uu___ = a in
  match uu___ with
  | (w1, w2, w3, n) ->
      (((((w1 * Tessarium_Spec.words) + w2) * Tessarium_Spec.words) + w3)
         * Tessarium_Spec.num_max)
        + n
