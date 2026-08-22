module Tessarium.UrlPath

/// Turning a request target into a list of path segments we are willing to
/// open, and proving that none of them can leave the directory they are
/// opened under.
///
/// This is the module that stops `GET /../../etc/passwd`. It is the first
/// proof here of a *server* decision rather than a piece of the grid, and it
/// is provable for the same reason the grid is: the safety argument is
/// "these segments contain no traversal", which is a statement about a list
/// and needs no filesystem to check.
///
/// Bytes, not characters. A request target is octets until something decodes
/// it, percent-decoding produces octets, and the three bytes that matter here
/// -- `/`, `.` and NUL -- are single octets in UTF-8 and cannot occur inside
/// a multi-byte sequence. Working at the byte level therefore loses nothing
/// and avoids a decoder in the one place where a decoder's mistakes are
/// exploitable.

module L = FStar.List.Tot

type byte = b: nat{b < 256}

let nul       : byte = 0
let hash      : byte = 35
let pct       : byte = 37
let dot       : byte = 46
let slash     : byte = 47
let question  : byte = 63
let backslash : byte = 92

(* ------------------------------------------------------------ the pieces *)

/// A target's path ends at the first `?` or `#`; what follows is the query
/// and the fragment, and neither names a file.
let rec query_stripped (p: list byte) : list byte =
  match p with
  | [] -> []
  | b :: tl -> if b = question || b = hash then [] else b :: query_stripped tl

let hex_val (b: byte) : option (n: nat{n < 16}) =
  if b >= 48 && b <= 57 then Some (b - 48)        (* 0-9 *)
  else if b >= 97 && b <= 102 then Some (b - 87)  (* a-f *)
  else if b >= 65 && b <= 70 then Some (b - 55)   (* A-F *)
  else None

/// Percent-decoding. A `%` not followed by two hex digits is rejected rather
/// than passed through, so an accepted target has one reading and not two --
/// which is a design choice, not something proved below.
let rec percent_decode (p: list byte) : Tot (option (list byte)) (decreases L.length p) =
  match p with
  | [] -> Some []
  | b :: tl ->
      if b <> pct then
        match percent_decode tl with
        | None -> None
        | Some r -> Some (b :: r)
      else (
        match tl with
        | hi :: lo :: rest -> (
            match hex_val hi, hex_val lo with
            | Some h, Some l -> (
                match percent_decode rest with
                | None -> None
                | Some r -> Some (((h * 16) + l) :: r))
            | _ -> None)
        | _ -> None)

/// Split on `/`, keeping empty pieces. Always at least one piece, which is
/// what lets the recursive case reach into the head without a partial `hd`.
let rec split_slash (p: list byte) : Tot (r: list (list byte){Cons? r}) =
  match p with
  | [] -> [ [] ]
  | b :: tl ->
      let r = split_slash tl in
      if b = slash then [] :: r else (b :: L.hd r) :: L.tl r

/// The pieces that name something. `//` and a trailing `/` produce empty
/// pieces, which are dropped rather than refused: they are how a browser
/// spells the same path, not an attack.
let segments (p: list byte) : list (list byte) =
  L.filter (fun s -> Cons? s) (split_slash p)

/// A segment we are willing to open. This is the runtime test.
///
/// The leading-dot rule does two jobs. Refusing `.` and `..` is containment,
/// and [theorem_no_escape] holds it. Refusing `.git` and `.env` is not --
/// a dotfile sits squarely under the root -- so it gets its own claim,
/// [theorem_no_dotfile], rather than riding along on the first one.
///
/// There is deliberately no test for `/` here. A segment comes out of a split
/// on `/` and cannot contain one; a runtime check for it would be a branch
/// that never fires, which reads as coverage without being any. That it holds
/// is proved of the split instead -- [lemma_split_no_slash].
let safe (s: list byte) : bool =
  match s with
  | [] -> false
  | d :: _ -> d <> dot && not (L.mem nul s) && not (L.mem backslash s)

/// What a segment has to be for joining it to a root to stay under that root.
/// This is the CLAIM, and it is deliberately not written in terms of [safe]:
/// every hazard is named, so weakening the runtime test above cannot weaken
/// the theorem to match. Delete the leading-dot rule from [safe] and
/// [theorem_no_escape] stops verifying rather than proving something smaller.
let opens_under_root (s: list byte) : bool =
  Cons? s
  && not (L.mem slash s)
  && not (L.mem backslash s)
  && not (L.mem nul s)
  && s <> [ dot ]
  && s <> [ dot; dot ]

/// Names nothing hidden. Separate from [opens_under_root] because it is a
/// different claim: a dotfile is reachable, it is just not ours to serve.
let names_no_dotfile (s: list byte) : bool =
  match s with
  | [] -> false
  | d :: _ -> d <> dot

/// `index.html`, the segment a directory target resolves to, so the app is
/// reachable at `/`.
let index_html : list byte = [ 105; 110; 100; 101; 120; 46; 104; 116; 109; 108 ]

let resolve (target: list byte) : option (list (list byte)) =
  match percent_decode (query_stripped target) with
  | None -> None
  | Some path ->
      let segs = segments path in
      if L.for_all safe segs then
        match segs with [] -> Some [ index_html ] | _ -> Some segs
      else None

(* ================================================================ theorems *)

val lemma_for_all_mem (f: list byte -> bool) (x: list byte) (l: list (list byte))
  : Lemma (requires L.mem x l /\ not (f x)) (ensures not (L.for_all f l))
let rec lemma_for_all_mem f x l =
  match l with
  | [] -> ()
  | h :: tl -> if h = x then () else lemma_for_all_mem f x tl

/// Splitting on `/` cannot leave a `/` inside a piece.
///
/// This is what makes the absent runtime check in [safe] sound, and it is the
/// half of the claim a check could not establish anyway: a check tells you
/// this call was fine, a proof tells you every call is.
val lemma_split_no_slash (p: list byte)
  : Lemma (L.for_all (fun s -> not (L.mem slash s)) (split_slash p))
let rec lemma_split_no_slash p =
  match p with
  | [] -> ()
  | b :: tl -> lemma_split_no_slash tl

val lemma_filter_for_all (f g: list byte -> bool) (l: list (list byte))
  : Lemma (requires L.for_all g l) (ensures L.for_all g (L.filter f l))
let rec lemma_filter_for_all f g l =
  match l with
  | [] -> ()
  | h :: tl -> lemma_filter_for_all f g tl

/// The runtime test plus the fact about the split give the claim, pointwise.
val lemma_safe_opens (l: list (list byte))
  : Lemma (requires L.for_all safe l /\
                    L.for_all (fun s -> not (L.mem slash s)) l)
          (ensures  L.for_all opens_under_root l)
let rec lemma_safe_opens l =
  match l with
  | [] -> ()
  | h :: tl -> lemma_safe_opens tl

(* ---------------------------------------------------------------- theorem *)

/// Nothing accepted can leave the root.
///
/// Every segment [resolve] hands back is non-empty, is neither `.` nor `..`,
/// and holds no `/`, `\` or NUL. Joined to a root directory in order, segments
/// with those properties address something strictly beneath it: `..` cannot
/// appear, an empty segment cannot restart the path, and neither separator can
/// smuggle one in.
///
/// What is NOT proved: that the caller joins them that way, and that the
/// directory underneath holds no symlink pointing out of itself. Both are
/// outside F*'s sight, and the second is a property of the filesystem rather
/// than of this code.
val theorem_no_escape (target: list byte)
  : Lemma (match resolve target with
           | None -> True
           | Some segs -> L.for_all opens_under_root segs)
let theorem_no_escape target =
  assert_norm (opens_under_root index_html);
  match percent_decode (query_stripped target) with
  | None -> ()
  | Some path ->
      let segs = segments path in
      (* Mirrors [resolve]'s own branch: [lemma_safe_opens] wants the runtime
         test to have passed, and that is only known on this side of it. *)
      if L.for_all safe segs then (
        lemma_split_no_slash path;
        lemma_filter_for_all (fun s -> Cons? s)
          (fun s -> not (L.mem slash s)) (split_slash path);
        lemma_safe_opens segs)

/// A target that decodes to a traversal is refused.
///
/// Not an independent guarantee: given [opens_under_root] as written, this
/// follows from [theorem_no_escape], and it is [theorem_no_escape] that
/// rejects a module reordered to validate before decoding -- deleting this
/// theorem does not let that reordering through.
///
/// It earns its place by naming `..` directly instead of routing through
/// [opens_under_root]: drop the `s <> [ dot; dot ]` clause from that
/// predicate and [theorem_no_escape] goes on verifying while quietly saying
/// less, where this one is untouched and still refuses the traversal. One
/// statement of that case that does not depend on a hand-written predicate
/// being complete.
///
/// One round of decoding, not a fixpoint. `%252e%252e` decodes to the literal
/// `%2e%2e` and is accepted as an ordinary name, which is correct -- nothing
/// downstream decodes a second time -- but it is why the claim is "decodes"
/// and not "however it was spelled".
val theorem_traversal_refused (target: list byte) (path: list byte)
  : Lemma (requires percent_decode (query_stripped target) == Some path /\
                    L.mem [ dot; dot ] (segments path))
          (ensures  resolve target == None)
let theorem_traversal_refused target path =
  lemma_for_all_mem safe [ dot; dot ] (segments path)

val lemma_safe_no_dotfile (l: list (list byte))
  : Lemma (requires L.for_all safe l) (ensures L.for_all names_no_dotfile l)
let rec lemma_safe_no_dotfile l =
  match l with
  | [] -> ()
  | h :: tl -> lemma_safe_no_dotfile tl

/// Nothing accepted begins with a dot.
///
/// The other half of [safe]'s one rule, and not a containment claim: `.env`
/// is under the root, it is simply not something this server has any business
/// handing out. Stated separately so that half is held by a proof rather than
/// by the two unit tests that used to be all of it.
val theorem_no_dotfile (target: list byte)
  : Lemma (match resolve target with
           | None -> True
           | Some segs -> L.for_all names_no_dotfile segs)
let theorem_no_dotfile target =
  assert_norm (names_no_dotfile index_html);
  match percent_decode (query_stripped target) with
  | None -> ()
  | Some path ->
      let segs = segments path in
      if L.for_all safe segs then lemma_safe_no_dotfile segs

(* ------------------------------------------------------------- liveness *)

/// Every theorem above says "if it accepts, then ...", and a resolver that
/// refused everything would satisfy all of them. These three say it does not,
/// and they are here because that is exactly the shape of vacuity the rest of
/// the module cannot see: `resolve = fun _ -> None` verifies against
/// everything above and serves no file at all.
val theorem_root_is_index (_: unit)
  : Lemma (resolve [] == Some [ index_html ])
let theorem_root_is_index () =
  assert_norm (resolve [] == Some [ index_html ])

/// `/a.js` -- an ordinary name, with a dot that is not in front.
val theorem_name_survives (_: unit)
  : Lemma (resolve [ slash; 97; 46; 106; 115 ] == Some [ [ 97; 46; 106; 115 ] ])
let theorem_name_survives () =
  assert_norm (resolve [ slash; 97; 46; 106; 115 ] == Some [ [ 97; 46; 106; 115 ] ])

/// `/a%20b` -- decoding has to do something, not merely refuse.
val theorem_decoding_happens (_: unit)
  : Lemma (resolve [ slash; 97; 37; 50; 48; 98 ] == Some [ [ 97; 32; 98 ] ])
let theorem_decoding_happens () =
  assert_norm (resolve [ slash; 97; 37; 50; 48; 98 ] == Some [ [ 97; 32; 98 ] ])
