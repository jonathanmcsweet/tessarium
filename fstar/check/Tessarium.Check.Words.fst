module Tessarium.Check.Words

/// The word lookup, as extracted, recomputed by F*. See
/// Tessarium.Check.Round for what these modules are and why they exist.
///
/// This closes the gap the roadmap called the widest in the tree: the two
/// theorems in Tessarium.Words are about ALL typed spellings against ALL
/// lists, and until this module the extracted code was exercised on three.
/// Expected carries the extracted binary's answer for every spelling in a
/// corpus against a sixteen-word fixture; each one is recomputed here from
/// the proved source by F*'s own evaluator.
///
/// Nothing is spelled twice. The fixture, the corpus and the answers all
/// come from Expected, so there is no second copy of the data that could
/// drift and no way for the two sides to be comparing different questions.
/// What differs between them is the implementation of the language, which is
/// the only thing this leg is about.
///
/// Scope, stated plainly: this checks EXTRACTION, not the shipped wordlist.
/// The corpus runs against sixteen words because the code path does not
/// depend on how many there are and F*'s normalizer would otherwise walk
/// 2048 byte lists per spelling. The shipped 2048 are covered exhaustively
/// on the other side, in ocaml/test/test_words.ml, which runs the same
/// function over every word and every partial spelling of every word.

module W = Tessarium.Words
module E = Tessarium.Check.Expected

/// Expected carries plain `list int` -- that is what the generator can emit
/// without carrying a refinement across. Tessarium.Words works on bytes, so
/// this is the widening.
///
/// Total, and deliberately all-or-nothing: a literal outside 0..255 fails the
/// whole conversion rather than being clamped into range, so a corrupt entry
/// cannot quietly become a valid byte and compare equal to something.
let rec as_word (xs: list int) : Tot (option W.word) (decreases xs) =
  match xs with
  | [] -> Some []
  | x :: rest ->
      if 0 <= x && x < 256 then
        (match as_word rest with
          | Some w -> Some ((x <: W.byte) :: w)
          | None -> None)
      else None

let rec as_words (xss: list (list int))
  : Tot (option (list W.word)) (decreases xss) =
  match xss with
  | [] -> Some []
  | xs :: rest -> (
      match as_word xs, as_words rest with
      | Some w, Some ws -> Some (w :: ws)
      | _, _ -> None)

/// -1 is None, matching the generator's spelling of a miss. -2 is not
/// producible by the lookup and marks an entry that failed to convert, so a
/// bad literal fails the comparison instead of reading as a miss -- which
/// matters here, because most of the corpus IS a miss.
let answer_for (typed: list int) (words: list (list int)) : Tot int =
  match as_word typed, as_words words with
  | Some t, Some ws -> (
      match W.resolve t ws with
      | None -> -1
      | Some i -> i)
  | _, _ -> -2

/// Pointwise, and length-sensitive: a corpus and an answer list of different
/// lengths is a failure, not a shorter comparison.
let rec answers_ok (typed: list (list int)) (expected: list int)
                   (words: list (list int))
  : Tot bool (decreases typed) =
  match typed, expected with
  | [], [] -> true
  | t :: ts, e :: es -> answer_for t words = e && answers_ok ts es words
  | _, _ -> false

let _ = assert_norm (answers_ok E.words_typed E.words_answer E.words_fixture)
