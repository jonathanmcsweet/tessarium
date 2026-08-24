module Tessarium.Words

/// Resolving a typed word to its place in the BIP-39 list, and proving that
/// what comes back is a word the typing actually spells the start of.
///
/// This is the module that stops "cannot" answering with cannon's square.
///
/// The rule is an ABBREVIATION rule: BIP-39's first four letters identify a
/// word, so "slic" may stand for "slice". Comparing only the first four
/// letters of the INPUT implements something else -- it makes "cannot" an
/// abbreviation of "cannon", and "artistic" one of "artist" -- and the
/// difference is a valid-looking address for a square nobody asked about,
/// handed back with no error at all. That shipped, and no test caught it
/// because the oracle written to disagree with this code had copied the
/// same mistake.
///
/// Bytes, not characters, for the reason Tessarium.UrlPath gives and one
/// more: F*'s string operations are specified only by the LENGTH of what
/// they return, so nothing relates the contents of a slice to the string it
/// came from. That fact could be assumed -- and this project forbids
/// assuming, which is `--report_assumes error` in fstar/Makefile. Over lists
/// the predicate is an ordinary definition and needs no assumption.
///
/// The word list crosses as a PARAMETER, the way the band table does.
/// Nothing here depends on which words are in it, or on their being
/// distinct, or on four letters really identifying one: the guarantee comes
/// from counting the matches, not from any property of the list. That is
/// what keeps the proof cheap -- the expensive statement (no two of 2048
/// words share four letters) is four million comparisons and is not needed.

module L = FStar.List.Tot

type byte = b: nat{b < 256}

/// A word, and what was typed, are both just bytes.
type word = list byte

(* ------------------------------------------------------------ the rule *)

/// [typed] spells the beginning of [w].
let rec is_prefix (typed w: word) : Tot bool (decreases typed) =
  match typed, w with
  | [], _ -> true
  | _ :: _, [] -> false
  | a :: typed', b :: w' -> a = b && is_prefix typed' w'

/// Where the list holds this word exactly. [base] is the index of the head,
/// so the walk carries no accumulator to reason about separately.
let rec exact (typed: word) (words: list word) (base: nat)
  : Tot (option nat) (decreases words) =
  match words with
  | [] -> None
  | w :: rest -> if w = typed then Some base else exact typed rest (base + 1)

/// Every index whose word [typed] spells the beginning of.
let rec matching (typed: word) (words: list word) (base: nat)
  : Tot (list nat) (decreases words) =
  match words with
  | [] -> []
  | w :: rest ->
      if is_prefix typed w then base :: matching typed rest (base + 1)
      else matching typed rest (base + 1)

/// The shortest abbreviation the rule will accept. Below four letters the
/// answer would be a guess, and a guess here is a wrong location.
///
/// An exact word is not an abbreviation and is not held to this: "act" is a
/// BIP-39 word and also the start of "action", "actor", "actress" and
/// "actual", so the abbreviation rule alone would refuse it. Exact first is
/// what makes those five reachable.
let min_abbrev : nat = 4

let resolve (typed: word) (words: list word) : Tot (option nat) =
  match exact typed words 0 with
  | Some i -> Some i
  | None ->
      if L.length typed < min_abbrev then None
      else (match matching typed words 0 with [ i ] -> Some i | _ -> None)

(* -------------------------------------------------------------- lemmas *)

/// A word spells its own beginning. What makes the exact branch a special
/// case of the claim rather than an exception to it.
val lemma_prefix_refl (w: word)
  : Lemma (ensures is_prefix w w) (decreases w)
let rec lemma_prefix_refl w =
  match w with [] -> () | _ :: tl -> lemma_prefix_refl tl

/// What [exact] found, it found in the list.
val lemma_exact (typed: word) (words: list word) (base: nat)
  : Lemma
      (ensures
        (match exact typed words base with
         | None -> True
         | Some i ->
             i >= base /\ i - base < L.length words
             /\ L.index words (i - base) == typed))
      (decreases words)
let rec lemma_exact typed words base =
  match words with
  | [] -> ()
  | _ :: rest -> lemma_exact typed rest (base + 1)

/// [matching] lists exactly the indices whose word [typed] begins -- both
/// directions, which is what makes a singleton mean "no other word could
/// have been meant" rather than merely "here is one".
val lemma_matching (typed: word) (words: list word) (base: nat) (i: nat)
  : Lemma
      (ensures
        L.mem i (matching typed words base)
        <==> (i >= base /\ i - base < L.length words
              /\ is_prefix typed (L.index words (i - base))))
      (decreases words)
let rec lemma_matching typed words base i =
  match words with
  | [] -> ()
  | _ :: rest -> lemma_matching typed rest (base + 1) i

(* ------------------------------------------------------------ theorems *)

/// Nothing resolves to a word the typing does not spell the beginning of.
///
/// This is the theorem. Written against [is_prefix] and not against the
/// four-letter rule on purpose: the bug WAS the four-letter rule, so a claim
/// phrased in its terms would have verified against the broken code.
val theorem_spelled (typed: word) (words: list word)
  : Lemma
      (match resolve typed words with
       | None -> True
       | Some i -> i < L.length words /\ is_prefix typed (L.index words i))
let theorem_spelled typed words =
  lemma_prefix_refl typed;
  lemma_exact typed words 0;
  match exact typed words 0 with
  | Some _ -> ()
  | None ->
      (match matching typed words 0 with
       | [ i ] -> lemma_matching typed words 0 i
       | _ -> ())

/// And an abbreviation resolves only when one word could have been meant.
///
/// Not implied by the theorem above: that one says the answer fits, this one
/// says nothing else does. Only about the abbreviation branch -- an exact
/// word is answered exactly even when it also begins longer words, which is
/// the whole reason "act" resolves.
val theorem_unambiguous (typed: word) (words: list word)
  : Lemma
      (requires exact typed words 0 == None)
      (ensures
        (match resolve typed words with
         | None -> True
         | Some i ->
             forall (j: nat).
               j < L.length words /\ is_prefix typed (L.index words j) ==> j == i))
let theorem_unambiguous typed words =
  match matching typed words 0 with
  | [ i ] ->
      FStar.Classical.forall_intro
        (Classical.move_requires (lemma_matching typed words 0))
  | _ -> ()
