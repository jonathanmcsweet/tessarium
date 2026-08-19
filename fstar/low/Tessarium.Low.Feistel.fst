module Tessarium.Low.Feistel

/// The proved Feistel restated over 64-bit machine integers, for KaRaMeL.
///
/// Nothing here is re-proved from scratch. Tessarium.Feistel remains the
/// specification; every function below carries an `ensures` equating its
/// machine-integer result with the spec's answer on the same inputs, so the
/// bijection theorems transfer by rewriting rather than by a second proof.
/// That equation is also the compatibility guarantee: a port that changed
/// any user's addresses would fail to verify, not fail in the field.
///
/// Bounds discipline (see BOUNDS.md): every intermediate is proved under
/// 2^48 here -- the halves live below fe_b < 2^24, sums below 2^25, and the
/// joined index below addr_space < 2^47 -- so each U64 operation's
/// no-overflow refinement discharges by linear arithmetic alone.
///
/// The spec-level round function travels as a GHOST index (`G.erased`): it
/// is Prims arithmetic and must never reach the extracted C. The machine
/// round function `round_low rf` carries its agreement with `rf` in the
/// refinement of its result type, one call at a time; the loop specs lift
/// that to the whole permutation.

module S = Tessarium.Spec
module F = Tessarium.Feistel
module M = FStar.Math.Lemmas
module G = FStar.Ghost
module U64 = FStar.UInt64

/// U64.v returns a refined int; the spec computes in nat. Equalities are
/// stated in plain int so the two sides meet without pair-type friction --
/// the same element-widening discipline as the check/ harness.
unfold noextract
let v64 (x: U64.t) : int = U64.v x

(* ---------------------------------------------------- machine constants *)

let fe_a64 : (c: U64.t{v64 c == S.fe_a}) =
  assert_norm (S.fe_a == 6553600); 6553600uL

let fe_b64 : (c: U64.t{v64 c == S.fe_b}) =
  assert_norm (S.fe_b == 13107200); 13107200uL

let addr_space64 : (c: U64.t{v64 c == S.addr_space}) =
  assert_norm (S.addr_space == 85899345920000); 85899345920000uL

let rounds64 : (c: U64.t{U64.v c == F.rounds}) = 16uL

(* --------------------------------------------------------- round function *)

/// Machine modulus for round i, pinned to the spec's.
let modulus64 (i: U64.t{U64.v i <= F.rounds})
  : (m: U64.t{v64 m == F.modulus (U64.v i)})
  = if U64.rem i 2uL = 1uL then fe_a64 else fe_b64

/// A machine round function that computes exactly what the (ghost) spec
/// round function computes, wherever the Feistel calls it. The bound on x
/// is what the loops guarantee at every call site: both halves stay below
/// max(fe_a, fe_b) = fe_b.
type round_low (#key #tweak: Type) (rf: G.erased (F.round_fn key tweak)) =
    k: key -> t: tweak
  -> i: U64.t{0 < U64.v i /\ U64.v i <= F.rounds}
  -> x: U64.t{U64.v x < S.fe_b}
  -> m: U64.t{v64 m == F.modulus (U64.v i)}
  -> r: U64.t{v64 r == G.reveal rf k t (U64.v i) (U64.v x) (U64.v m)}

(* ------------------------------------------------------------- the cipher *)

let rec enc_loop_low
    (#key #tweak: Type) (#rf: G.erased (F.round_fn key tweak))
    (f: round_low rf) (k: key) (t: tweak)
    (i: U64.t{U64.v i <= F.rounds}) (l r: U64.t)
  : Pure (U64.t & U64.t)
      (requires F.inv (U64.v i) (U64.v l) (U64.v r))
      (ensures  fun (l', r') ->
        (let (sl, sr) = F.enc_loop (G.reveal rf) k t (U64.v i) (U64.v l) (U64.v r) in
         v64 l' == sl /\ v64 r' == sr))
      (decreases F.rounds - U64.v i)
  = if i = rounds64 then (l, r)
    else begin
      let j = U64.add i 1uL in
      let m = modulus64 j in
      let fr = f k t j r m in
      M.lemma_mod_lt (U64.v l + U64.v fr) (U64.v m);
      enc_loop_low f k t j r (U64.rem (U64.add l fr) m)
    end

let rec dec_loop_low
    (#key #tweak: Type) (#rf: G.erased (F.round_fn key tweak))
    (f: round_low rf) (k: key) (t: tweak)
    (i: U64.t{U64.v i <= F.rounds}) (l r: U64.t)
  : Pure (U64.t & U64.t)
      (requires F.inv (U64.v i) (U64.v l) (U64.v r))
      (ensures  fun (l', r') ->
        (let (sl, sr) = F.dec_loop (G.reveal rf) k t (U64.v i) (U64.v l) (U64.v r) in
         v64 l' == sl /\ v64 r' == sr))
      (decreases U64.v i)
  = if i = 0uL then (l, r)
    else begin
      let m = modulus64 i in
      let fr = f k t i l m in
      M.lemma_mod_lt (U64.v r - U64.v fr + U64.v m) (U64.v m);
      (* Spec subtracts then re-adds m to keep the numerator non-negative;
         machine order adds m FIRST so the subtraction cannot underflow.
         Same integer: (r - fr + m) = (r + m) - fr. *)
      dec_loop_low f k t (U64.sub i 1uL)
        (U64.rem (U64.sub (U64.add r m) fr) m) l
    end

let split_low (x: U64.t{U64.v x < S.addr_space})
  : Pure (U64.t & U64.t)
      (requires True)
      (ensures  fun (l, r) ->
        (let (sl, sr) = F.split (U64.v x) in v64 l == sl /\ v64 r == sr))
  = (U64.div x fe_b64, U64.rem x fe_b64)

let join_low (l: U64.t{U64.v l < S.fe_a}) (r: U64.t{U64.v r < S.fe_b})
  : Pure U64.t
      (requires True)
      (ensures  fun y -> v64 y == F.join (U64.v l) (U64.v r))
  = S.lemma_factors ();
    M.lemma_mult_le_right S.fe_b (U64.v l) (S.fe_a - 1);
    U64.add (U64.mul l fe_b64) r

let encrypt_low
    (#key #tweak: Type) (#rf: G.erased (F.round_fn key tweak))
    (f: round_low rf) (k: key) (t: tweak) (x: U64.t{U64.v x < S.addr_space})
  : Pure U64.t
      (requires True)
      (ensures  fun y ->
        v64 y == F.encrypt (G.reveal rf) k t (U64.v x) /\
        U64.v y < S.addr_space)
  = let (l, r) = split_low x in
    let (l', r') = enc_loop_low f k t 0uL l r in
    join_low l' r'

let decrypt_low
    (#key #tweak: Type) (#rf: G.erased (F.round_fn key tweak))
    (f: round_low rf) (k: key) (t: tweak) (y: U64.t{U64.v y < S.addr_space})
  : Pure U64.t
      (requires True)
      (ensures  fun x ->
        v64 x == F.decrypt (G.reveal rf) k t (U64.v y) /\
        U64.v x < S.addr_space)
  = let (l, r) = split_low y in
    let (l', r') = dec_loop_low f k t rounds64 l r in
    join_low l' r'

(* -------------------------------------------------- theorems, transferred *)

/// The spec's bijection theorems restated on the machine functions. Each is
/// one appeal to the spec theorem plus injectivity of U64.v -- there is no
/// second Feistel proof to maintain.

val theorem_roundtrip_low
    (#key #tweak: Type) (#rf: G.erased (F.round_fn key tweak))
    (f: round_low rf) (k: key) (t: tweak) (x: U64.t{U64.v x < S.addr_space})
  : Lemma (decrypt_low f k t (encrypt_low f k t x) == x)
let theorem_roundtrip_low #key #tweak #rf f k t x =
  F.theorem_roundtrip (G.reveal rf) k t (U64.v x);
  U64.v_inj (decrypt_low f k t (encrypt_low f k t x)) x

val theorem_surjective_low
    (#key #tweak: Type) (#rf: G.erased (F.round_fn key tweak))
    (f: round_low rf) (k: key) (t: tweak) (y: U64.t{U64.v y < S.addr_space})
  : Lemma (encrypt_low f k t (decrypt_low f k t y) == y)
let theorem_surjective_low #key #tweak #rf f k t y =
  F.theorem_surjective (G.reveal rf) k t (U64.v y);
  U64.v_inj (encrypt_low f k t (decrypt_low f k t y)) y
