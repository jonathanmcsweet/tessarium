module Tessarium.Scan

/// Generic scaffolding for establishing a pointwise property of a long table
/// from cheap per-chunk facts.
///
/// Nothing here mentions the band table, so every proof below is small and
/// fast. That separation is not stylistic: a module that defines 4096 literals
/// drags them into every SMT query it contains, and even a trivial index bound
/// then becomes intractable. Data-free lemmas prove once, here; the concrete
/// table instantiates them.

module L = FStar.List.Tot

(* ----------------------------------------------------- adjacent differences *)

/// Every adjacent difference lies in (0, max].
///
/// The band table is stored as *cumulative* column counts, which is what makes
/// this one predicate sufficient: strict increase gives every column count a
/// positive width, and the bounded difference gives the per-band maximum. Both
/// of the facts the grid needs about the table fall out of it, and contiguity
/// of the band offsets becomes true by definition rather than by proof.
let rec diffs_ok (l: list nat) (max: pos) : bool =
  match l with
  | []  -> true
  | [_] -> true
  | a :: b :: tl -> a < b && b - a <= max && diffs_ok (b :: tl) max

/// Pointwise consequence: what the grid actually consumes.
val lemma_diffs_index (l: list nat) (max: pos) (i: nat)
  : Lemma (requires diffs_ok l max /\ i + 1 < L.length l)
          (ensures  (let a = L.index l i in
                     let b = L.index l (i + 1) in
                     a < b /\ b - a <= max))
          (decreases i)
let rec lemma_diffs_index l max i =
  match l with
  | a :: b :: tl -> if i = 0 then () else lemma_diffs_index (b :: tl) max (i - 1)

/// The head of an append is the head of its left operand. Needed because the
/// chunks are folded right-associated: each step compares the last element of
/// one chunk against the head of everything after it, and that head has to be
/// reduced back to a concrete chunk's head for the normaliser to evaluate it.
val lemma_hd_append (l1 l2: list nat)
  : Lemma (requires Cons? l1)
          (ensures  Cons? (l1 `L.append` l2) /\
                    L.hd (l1 `L.append` l2) == L.hd l1)
let lemma_hd_append l1 l2 = match l1 with | _ :: _ -> ()

/// Chunk combination. Each chunk is checked on its own by the normaliser, so
/// no obligation ever spans the whole table; the only extra thing to discharge
/// is that the seam between two adjacent chunks is itself sound.
val lemma_diffs_append (l1 l2: list nat) (max: pos)
  : Lemma (requires diffs_ok l1 max /\ diffs_ok l2 max /\ Cons? l1 /\ Cons? l2 /\
                    (let a = L.last l1 in
                     let b = L.hd l2 in
                     a < b /\ b - a <= max))
          (ensures  diffs_ok (l1 `L.append` l2) max)
          (decreases l1)
let rec lemma_diffs_append l1 l2 max =
  match l1 with
  | [_] -> ()
  | _ :: c :: rest -> lemma_diffs_append (c :: rest) l2 max
