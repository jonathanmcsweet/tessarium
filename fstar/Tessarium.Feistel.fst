module Tessarium.Feistel

/// FE1 generalized Feistel over Z_a x Z_b (Black & Rogaway, CT-RSA 2002).
///
/// The domain size is exactly addr_space, so this is a bijection with no
/// cycle-walking and therefore no probabilistic termination argument.
///
/// The halves swap domains every round, so the loop invariant alternates with
/// the round parity and an even round count returns them to their start ranges.

module M = FStar.Math.Lemmas

open Tessarium.Spec

let rounds : pos = 10        // must be even: halves swap domains each round

type index = x: nat{x < addr_space}

/// The round function is a parameter, and so are the key and tweak types: this
/// module never inspects either, it only hands them back to `f`. Leaving them
/// abstract states the theorem for any key representation and keeps
/// FStar.Seq out of the extracted surface, so the OCaml side can pass plain
/// strings.
///
/// Bijectivity does not depend on the round function being cryptographic —
/// that assumption is needed only for unpredictability, which no proof
/// assistant will discharge.
type round_fn (key tweak: Type) =
  key -> tweak -> i: nat{i <= rounds} -> nat -> m: pos -> r: nat{r < m}

/// Modulus for round i. Odd rounds reduce into Z_a, even rounds into Z_b.
let modulus (i: nat) : pos = if i % 2 = 1 then fe_a else fe_b

/// After i rounds the halves sit in these ranges. Even i restores the start.
let inv (i: nat) (l r: nat) : prop =
  if i % 2 = 0 then l < fe_a /\ r < fe_b else l < fe_b /\ r < fe_a

let rec enc_loop (#key #tweak: Type) (f: round_fn key tweak) (k: key) (t: tweak) (i: nat{i <= rounds}) (l r: nat)
  : Pure (nat & nat)
      (requires inv i l r)
      (ensures  fun (l', r') -> l' < fe_a /\ r' < fe_b)
      (decreases rounds - i)
  = if i = rounds then (l, r)
    else begin
      let j = i + 1 in
      let m = modulus j in
      let fr = f k t j r m in
      M.lemma_mod_lt (l + fr) m;
      enc_loop f k t j r ((l + fr) % m)
    end

/// Undo the rounds in reverse. The reference does this with Python's modulo,
/// which is always non-negative; F* division truncates toward zero, so the
/// subtraction is biased by one modulus first to keep the numerator positive.
let rec dec_loop (#key #tweak: Type) (f: round_fn key tweak) (k: key) (t: tweak) (i: nat{i <= rounds}) (l r: nat)
  : Pure (nat & nat)
      (requires inv i l r)
      (ensures  fun (l', r') -> l' < fe_a /\ r' < fe_b)
      (decreases i)
  = if i = 0 then (l, r)
    else begin
      let m = modulus i in
      let fr = f k t i l m in
      M.lemma_mod_lt (r - fr + m) m;
      dec_loop f k t (i - 1) ((r - fr + m) % m) l
    end

/// Split an index into halves, and rejoin. `fe_a * fe_b = addr_space` exactly,
/// which is what makes both directions total.
let split (x: index) : (p: (nat & nat){fst p < fe_a /\ snd p < fe_b}) =
  lemma_factors ();
  lemma_div_bound x fe_b fe_a;
  M.lemma_mod_lt x fe_b;
  (x / fe_b, x % fe_b)

let join (l: nat{l < fe_a}) (r: nat{r < fe_b}) : index =
  lemma_factors ();
  M.lemma_mult_le_right fe_b l (fe_a - 1);
  l * fe_b + r

let encrypt (#key #tweak: Type) (f: round_fn key tweak) (k: key) (t: tweak) (x: index) : index =
  let (l, r) = split x in
  let (l', r') = enc_loop f k t 0 l r in
  join l' r'

let decrypt (#key #tweak: Type) (f: round_fn key tweak) (k: key) (t: tweak) (y: index) : index =
  let (l, r) = split y in
  let (l', r') = dec_loop f k t rounds l r in
  join l' r'
