open Prims
let rounds : Prims.pos= Prims.of_int 10
type index = Prims.nat
type ('key, 'tweak) round_fn =
  'key -> 'tweak -> Prims.nat -> Prims.nat -> Prims.pos -> Prims.nat
let modulus (i : Prims.nat) : Prims.pos=
  if ((mod) i (Prims.of_int 2)) = Prims.int_one
  then Tessarium_Spec.fe_a
  else Tessarium_Spec.fe_b
let rec enc_loop :
  'key 'tweak .
    ('key, 'tweak) round_fn ->
      'key ->
        'tweak ->
          Prims.nat -> Prims.nat -> Prims.nat -> (Prims.nat * Prims.nat)
  =
  fun f k t i l r ->
    if i = rounds
    then (l, r)
    else
      (let j = i + Prims.int_one in
       let m = modulus j in
       let fr = f k t j r m in enc_loop f k t j r ((mod) (l + fr) m))
let rec dec_loop :
  'key 'tweak .
    ('key, 'tweak) round_fn ->
      'key ->
        'tweak ->
          Prims.nat -> Prims.nat -> Prims.nat -> (Prims.nat * Prims.nat)
  =
  fun f k t i l r ->
    if i = Prims.int_zero
    then (l, r)
    else
      (let m = modulus i in
       let fr = f k t i l m in
       dec_loop f k t (i - Prims.int_one) ((mod) ((r - fr) + m) m) l)
let split (x : index) : (Prims.nat * Prims.nat)=
  ((x / Tessarium_Spec.fe_b), ((mod) x Tessarium_Spec.fe_b))
let join (l : Prims.nat) (r : Prims.nat) : index=
  (l * Tessarium_Spec.fe_b) + r
let encrypt (f : ('key, 'tweak) round_fn) (k : 'key) (t : 'tweak) (x : index)
  : index=
  let uu___ = split x in
  match uu___ with
  | (l, r) ->
      let uu___1 = enc_loop f k t Prims.int_zero l r in
      (match uu___1 with | (l', r') -> join l' r')
let decrypt (f : ('key, 'tweak) round_fn) (k : 'key) (t : 'tweak) (y : index)
  : index=
  let uu___ = split y in
  match uu___ with
  | (l, r) ->
      let uu___1 = dec_loop f k t rounds l r in
      (match uu___1 with | (l', r') -> join l' r')
