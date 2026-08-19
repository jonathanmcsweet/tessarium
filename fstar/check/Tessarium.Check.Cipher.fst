module Tessarium.Check.Cipher

/// The Feistel, the codec, and the rejection path, as extracted,
/// recomputed by F*. No table involvement, so no `friend` -- everything
/// here is arithmetic the normalizer walks directly. See
/// Tessarium.Check.Round for what these modules are.

module L = FStar.List.Tot
module F = Tessarium.Feistel
module C = Tessarium.Codec
module A = Tessarium.Api
module E = Tessarium.Check.Expected

open Tessarium.Spec
open Tessarium.Check.Round

(* -------------------------------------------------------------- feistel *)

/// Each expected output is checked, and decrypt is driven back over it --
/// the proved round-trip theorem guarantees decrypt inverts encrypt, but
/// only running the EXTRACTED decrypt checks its extraction.
let rec fe_ok (ks ts xs ys: list int) : Tot bool (decreases ks) =
  match ks, ts, xs, ys with
  | [], [], [], [] -> true
  | k :: ks', t :: ts', x :: xs', y :: ys' ->
      0 <= k && 0 <= t && 0 <= x && x < addr_space
      && (let y' = F.encrypt rf k t x in
          y' = y && F.decrypt rf k t y' = x)
      && fe_ok ks' ts' xs' ys'
  | _, _, _, _ -> false

let _ = assert_norm (fe_ok E.fe_k E.fe_t E.fe_x E.fe_y)

(* ---------------------------------------------------------------- codec *)

let rec codec_ok (l: list (int & int & int & int & int)) : bool =
  match l with
  | [] -> true
  | (i, w1, w2, w3, n) :: tl ->
      0 <= i && i < addr_space
      (* Destructured, not compared as tuples: the components of an
         `address` are refined, tuple parameters are invariant, and F*
         would demand the expected ints BE word indices rather than
         merely equal them. Widening each component is free. *)
      && (let (a1, a2, a3, an) = C.to_address i in
          a1 = w1 && a2 = w2 && a3 = w3 && an = n
          && C.from_address (a1, a2, a3, an) = i)
      && codec_ok tl

let _ = assert_norm (codec_ok E.codec)

(* ------------------------------------------------------ rejection path *)

/// Addresses nobody encoded resolve to nothing. The None arm is a branch
/// extraction could lose without any other check noticing.
let rec nones_ok (l: list (int & int & int & int)) : bool =
  match l with
  | [] -> true
  | (w1, w2, w3, n) :: tl ->
      0 <= w1 && w1 < words && 0 <= w2 && w2 < words
      && 0 <= w3 && w3 < words && 0 <= n && n < num_max
      && None? (A.decode rf ck ct (w1, w2, w3, n))
      && nones_ok tl

let _ = assert_norm (nones_ok E.nones)

