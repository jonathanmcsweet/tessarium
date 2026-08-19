module Tessarium.Check.Round

/// The extracted OCaml, cross-examined by F* itself: shared pieces.
///
/// `Tessarium.Check.Expected` holds answers computed by the EXTRACTED
/// core -- the OCaml that `make extract` produced and `ocamlopt`
/// compiled. The Check.* modules beside this one make F*'s normalizer
/// recompute those answers from the PROVED source and refuse the module
/// if any differ: one computation is the F* evaluator walking the
/// elaborated terms directly, the other is the extraction pipeline's
/// output running as native code. A divergence on
/// any checked value -- one band-table entry, one Feistel output, one
/// grid cell -- is a type error there, and `make check-extraction`
/// fails.
///
/// What this is NOT: a proof of the extraction pipeline. It is
/// differential testing with F* as the oracle, on these points and this
/// data. Precisely what the two computations share and do not: both go
/// through F*'s front end (parsing, elaboration), and both do their
/// arithmetic through zarith -- the normalizer's integers and the
/// extracted binary's are the same library. They diverge at the
/// extraction backend, which is the step under watch. The js/ oracle is
/// the leg that escapes the shared substrate. The honest statement after
/// this passes: the extracted core agrees with the proved source on all
/// 4097 table entries, the module constants, and every checked point of
/// the Feistel, the codec, the grid and the end-to-end composition.
///
/// One module per leg, one process per module, by measurement rather
/// than taste: the normalizer retains what it has evaluated for the
/// lifetime of a module's check, and the legs together exceed memory
/// that each is nowhere near alone.
///
/// The round function is concrete and deliberately trivial -- the
/// theorems hold for ANY inhabitant of the type, so checking with a
/// simple one is checking the proved code. It is spelled once here and
/// once in ocaml/tools/gen_check.ml over Prims' own operators; if the
/// two spellings drift apart, every Check module FAILS, which is the
/// right direction. HMAC is absent on purpose: it was never inside the
/// proof, and it is vector-tested where it lives (ocaml/lib/crypto.ml).

module F = Tessarium.Feistel
open Tessarium.Spec

(* The other spelling lives in ocaml/tools/gen_check.ml.

   No lemma call in the body, deliberately: the refinement discharges by
   SMT alone, and a `Lemma` invoked here would be EXECUTED by the
   normalizer -- ulib's arithmetic proofs recurse on the magnitude of
   their arguments, which at this domain's size is an out-of-memory, not
   a proof. *)
let rf : F.round_fn nat nat =
  fun k t i x m -> (x * 31 + i * 1000003 + (k + t)) % m

(* Key and tweak for the end-to-end points; gen_check.ml hardcodes the
   same two numerals. *)
let ck : nat = 7
let ct : nat = 9
