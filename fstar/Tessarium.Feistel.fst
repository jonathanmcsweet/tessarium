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

(* ================================================================ theorems *)

/// Adding the round output then subtracting it returns the original value.
/// Both sides stay under one modulus, so the sum crosses at most one multiple
/// of m and the correction is a single m either way.
val lemma_mod_undo (l fr: nat) (m: pos)
  : Lemma (requires l < m /\ fr < m)
          (ensures  ((l + fr) % m - fr + m) % m == l)
let lemma_mod_undo l fr m =
  let q = (l + fr) / m in
  M.euclidean_division_definition (l + fr) m;
  assert ((l + fr) % m - fr + m == l + (1 - q) * m);
  M.lemma_mod_plus l (1 - q) m;
  M.small_mod l m

/// The mirror image, for the other direction.
val lemma_mod_redo (r fr: nat) (m: pos)
  : Lemma (requires r < m /\ fr < m)
          (ensures  ((r - fr + m) % m + fr) % m == r)
let lemma_mod_redo r fr m =
  let q = (r - fr + m) / m in
  M.euclidean_division_definition (r - fr + m) m;
  assert ((r - fr + m) % m + fr == r + (1 - q) * m);
  M.lemma_mod_plus r (1 - q) m;
  M.small_mod r m

/// The left half is always below the next round's modulus, which is what lets
/// a round be undone. The halves swap domains each round, so this is a fact
/// about parity rather than about the values.
val lemma_left_below_modulus (i: nat{i < rounds}) (l r: nat)
  : Lemma (requires inv i l r) (ensures l < modulus (i + 1))
let lemma_left_below_modulus i l r = ()

/// Decryption from the last round collapses onto decryption from round i, once
/// the intervening rounds have been applied by encryption.
///
/// Stated this way on purpose: it needs no second decryption loop with an
/// adjustable endpoint, and at i = 0 it is exactly the round trip, since
/// `dec_loop` at 0 is the identity.
val lemma_dec_undoes_enc
      (#key #tweak: Type) (f: round_fn key tweak) (k: key) (t: tweak)
      (i: nat{i <= rounds}) (l r: nat)
  : Lemma (requires inv i l r)
          (ensures  (let (l', r') = enc_loop f k t i l r in
                     dec_loop f k t rounds l' r' == dec_loop f k t i l r))
          (decreases rounds - i)
let rec lemma_dec_undoes_enc f k t i l r =
  if i = rounds then ()
  else begin
    let j = i + 1 in
    let m = modulus j in
    let fr = f k t j r m in
    M.lemma_mod_lt (l + fr) m;
    lemma_dec_undoes_enc f k t j r ((l + fr) % m);
    lemma_left_below_modulus i l r;
    lemma_mod_undo l fr m
  end

/// And the other way round, which is what makes the permutation onto.
val lemma_enc_undoes_dec
      (#key #tweak: Type) (f: round_fn key tweak) (k: key) (t: tweak)
      (i: nat{i <= rounds}) (l r: nat)
  : Lemma (requires inv i l r)
          (ensures  (let (l', r') = dec_loop f k t i l r in
                     enc_loop f k t 0 l' r' == enc_loop f k t i l r))
          (decreases i)
let rec lemma_enc_undoes_dec f k t i l r =
  if i = 0 then ()
  else begin
    let m = modulus i in
    let fr = f k t i l m in
    M.lemma_mod_lt (r - fr + m) m;
    lemma_enc_undoes_dec f k t (i - 1) ((r - fr + m) % m) l;
    lemma_mod_redo r fr m
  end

/// Splitting and rejoining are mutually inverse. `fe_a * fe_b = addr_space`
/// exactly, so neither direction can fall out of range.
val lemma_split_join (l: nat{l < fe_a}) (r: nat{r < fe_b})
  : Lemma (split (join l r) == (l, r))
let lemma_split_join l r =
  lemma_factors ();
  M.lemma_div_plus r l fe_b;
  M.small_div r fe_b;
  M.lemma_mod_plus r l fe_b;
  M.small_mod r fe_b

val lemma_join_split (x: index)
  : Lemma (let (l, r) = split x in join l r == x)
let lemma_join_split x =
  lemma_factors ();
  M.euclidean_division_definition x fe_b

/// The round trip. Note what it does NOT assume: nothing about `f` beyond its
/// type. Bijectivity is structural, and holds for any round function at all.
/// That `f` is cryptographic is what makes the mapping unpredictable, which is
/// a separate claim and not one a proof assistant will discharge.
val theorem_roundtrip
      (#key #tweak: Type) (f: round_fn key tweak) (k: key) (t: tweak) (x: index)
  : Lemma (decrypt f k t (encrypt f k t x) == x)
let theorem_roundtrip f k t x =
  let (l, r) = split x in
  let (l', r') = enc_loop f k t 0 l r in
  lemma_split_join l' r';
  lemma_dec_undoes_enc f k t 0 l r;
  lemma_join_split x

/// Encryption is one-to-one, so no two cells can share an address.
val theorem_injective
      (#key #tweak: Type) (f: round_fn key tweak) (k: key) (t: tweak) (x1 x2: index)
  : Lemma (requires encrypt f k t x1 == encrypt f k t x2) (ensures x1 == x2)
let theorem_injective f k t x1 x2 =
  theorem_roundtrip f k t x1;
  theorem_roundtrip f k t x2

/// And onto: every address in the space is some cell's. Witnessed by
/// decryption rather than asserted, so this is constructive.
val theorem_surjective
      (#key #tweak: Type) (f: round_fn key tweak) (k: key) (t: tweak) (y: index)
  : Lemma (encrypt f k t (decrypt f k t y) == y)
let theorem_surjective f k t y =
  let (l, r) = split y in
  let (l', r') = dec_loop f k t rounds l r in
  lemma_split_join l' r';
  lemma_enc_undoes_dec f k t rounds l r;
  lemma_join_split y
