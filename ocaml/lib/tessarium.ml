(* Public API: seed phrase in, addresses out.

   Everything numeric below crosses into the F*-extracted core, which works in
   Zarith integers. OCaml's native int is 63-bit and would hold every value
   here, but the conversion is kept explicit at the boundary rather than
   assumed. *)

module Api = Tessarium_Api
module Table = Tessarium_Table

(* A refusal the user can act on, carrying a stable code beside its English
   sentence.

   The sentence is unchanged and stays authoritative: it is what the HTTP API
   puts on the wire and what the tests read. The code exists for the browser,
   which ships in six locales and cannot translate a sentence it did not
   choose -- it maps the code to a catalogue entry and substitutes [arg] for
   the one value that varies. See ui/src/core/refusal.ts.

   [arg] is a string even where it holds a count, because it crosses into
   JavaScript through js_of_ocaml and there is exactly one of it per refusal.
   A refusal that ever needs two values is the point at which this should
   become a proper variant rather than growing an [arg2]. *)
type refusal = { code : string; arg : string; message : string }

exception Invalid_address of refusal
exception Bad_mnemonic of refusal
exception Bad_passphrase of refusal

let grid_version = Table.grid_version
(* Left as Zarith. Both exceed 2^31, and this module is also compiled to
   JavaScript, where Z.to_int targets a 32-bit int and raises Z.Overflow at
   load time. *)
let total_cells = Table.total_cells
let address_space = Tessarium_Spec.addr_space

(* Bound the mapping to a specific grid. Regenerating the band table changes
   every address rather than silently reinterpreting old ones. *)
let tweak = grid_version

(* Its LENGTH is transcribed into fstar/low/Tessarium.Low.Blake2s.fst as
   literal words and a byte counter, so a tweak of any other length parts the
   OCaml and JS legs from the proved core, the vendored C and the wasm --
   quietly, since both halves still build and still verify. The prefix half
   of the same invariant is checked in ocaml/lib/crypto.ml. *)
let () =
  if String.length tweak <> 16 then
    failwith
      "tessarium: the grid tweak must be 16 bytes -- redo the transcription \
       in fstar/low/Tessarium.Low.Blake2s.fst first"

(* The injected round function, exposed so tests can drive the core directly. *)
let round_fn = Crypto.round_fn

(* Zarith, not int literals. This module is also compiled to JavaScript, where
   OCaml's native int is 32 bits: written as literals these four constants are
   silently truncated, and js_of_ocaml says so. *)
let lat_min = Z.of_string "-90000000000"
let lat_max = Z.of_string "90000000000"
let lon_min = Z.of_string "-180000000000"
let lon_max = Z.of_string "180000000000"

(* ------------------------------------------------------- key derivation *)

let required_words = 24

(* One derivation stage, memory-hard, and the reason it is Argon2id.

   Until kdf-3 this was two PBKDF2-HMAC-SHA512 stages (BIP-39's fixed 2048,
   then a hardened 200,000 -- the measurements are in the ledger). Argon2id
   was the recorded better answer, rejected only because pure-OCaml Argon2id
   at 64 MiB cost 21 s in a browser and a wasm build would have meant a
   second implementation of the primitive. The C-core pipeline dissolved
   that objection: ONE vendored reference implementation (ocaml/argon2) now
   compiles both natively for this function and to WebAssembly for the
   browser, byte-identical -- measured 108 ms native, 149 ms as wasm.

   The parameters (t=3, m=64 MiB, p=1 -- RFC 9106's second recommended
   option) are baked in the stubs and the wasm glue, not passed here: a
   memory-hard function prices out the perfectly-parallel GPU attacker the
   iteration count only taxed linearly.

   What this deliberately gives up: the intermediate value is no longer the
   standard BIP-39 seed (that chain was PBKDF2-HMAC-SHA512, a NIST-designed
   path -- the move off those primitives is ledgered). The PHRASE is
   unchanged -- same wordlist, same checksum, same typing ergonomics, which
   is the whole reason that format was chosen -- and nothing external ever
   consumed the seed, since the Feistel key was always derived from it by a
   custom stage. *)
(* Re-exported so tests can exercise it directly. The library's own module
   shares its name, so sibling modules are otherwise unreachable from outside. *)
let nfkd = Normalize.nfkd

(* The Argon2id salt, so it decides every key and therefore every address.
   Bumped to -4 with the 2026-08-23 rename rather than reusing -3, so an
   address issued under the old derivation can never be silently reread as
   a new one. *)
let derivation_version = "tessarium-kdf-4"

(* For the mnemonic only. BIP-39's English words are lowercase, so folding case
   and trimming here is safe and forgiving of how a phrase was pasted.

   It must NOT be applied to the passphrase. BIP-39 uses the passphrase
   verbatim: it is case-sensitive, and whitespace in it is significant. Folding
   it would make "MySecret" and "mysecret" the same map and silently throw away
   one bit per letter. *)
let normalize_mnemonic s = String.trim (String.lowercase_ascii s)

let split_words s =
  String.split_on_char ' ' (String.map (function '\t' | '\n' | '\r' -> ' ' | c -> c) s)
  |> List.filter (fun w -> w <> "")

(* 24 words only. A 12-word phrase carries 128 bits of entropy, which Grover
   reduces to an effective 64. 24 words leaves 128 standing. *)
let validate_mnemonic m =
  let words = split_words (normalize_mnemonic m) in
  let n = List.length words in
  if n <> required_words then
    Error
      {
        code = "mnemonic_word_count";
        arg = string_of_int n;
        message =
          Printf.sprintf
            "expected %d words, got %d. 12-word phrases are not accepted: 128 \
             bits of entropy is only 64 against a quantum adversary."
            required_words n;
      }
  else
    match List.find_opt (fun w -> not (Hashtbl.mem Wordlist.index w)) words with
    | Some bad ->
        Error
          {
            code = "mnemonic_not_a_word";
            arg = bad;
            message = Printf.sprintf "'%s' is not a BIP-39 word" bad;
          }
    | None ->
        (* 24 words = 264 bits = 256 entropy + 8 checksum *)
        let bits =
          List.fold_left
            (fun acc w -> Z.add (Z.shift_left acc 11) (Z.of_int (Hashtbl.find Wordlist.index w)))
            Z.zero words
        in
        let checksum = Z.to_int (Z.logand bits (Z.of_int 0xff)) in
        let entropy = Crypto.be_bytes_of_z (Z.shift_right bits 8) 32 in
        if Char.code (Crypto.sha256 entropy).[0] <> checksum then
          Error
            {
              code = "mnemonic_checksum";
              arg = "";
              message = "checksum failed -- likely a typo in one word";
            }
        else Ok ()

(* Entropy in, words out -- the inverse of [validate_mnemonic].

   Pure on purpose. Where the bytes came from is the single decision that
   decides whether a phrase is worth 2^256 guesses or 2^40, and it is the one
   thing that cannot be checked by looking at the output: a phrase built from
   a counter and one built from a hardware RNG are indistinguishable. So the
   randomness stays with the caller, at the edge, where it is visible -- and
   this half stays a function that can be tested against BIP-39's published
   vectors.

   32 bytes, because this application accepts 24-word phrases only. *)
let entropy_bytes = 32

let mnemonic_of_entropy entropy =
  if String.length entropy <> entropy_bytes then
    invalid_arg
      (Printf.sprintf "expected %d bytes of entropy, got %d" entropy_bytes
         (String.length entropy));
  (* 256 bits of entropy plus an 8-bit checksum is 264, which is exactly 24
     words of 11 bits each. *)
  let bits =
    Z.add
      (Z.shift_left (Crypto.z_of_be_bytes entropy) 8)
      (Z.of_int (Char.code (Crypto.sha256 entropy).[0]))
  in
  String.concat " "
    (List.init required_words (fun i ->
         let shift = (required_words - 1 - i) * 11 in
         Wordlist.words.(Z.to_int (Z.logand (Z.shift_right bits shift) (Z.of_int 0x7ff)))))

(* The KDF's two inputs, built HERE and only here: native callers and the
   browser worker (through the js_of_ocaml export) both take them from this
   code, so the NFKD and joining rules cannot drift between targets. The
   salt carries the version, so a future parameter change cannot silently
   collide with keys derived today; the passphrase rides in the salt with
   case and whitespace verbatim, per the BIP-39 convention this follows --
   but NFKD-normalised, which is a different thing (see normalize_mnemonic
   for why the mnemonic alone is case-folded). The 17-byte version prefix
   keeps the salt above Argon2's 8-byte floor for any passphrase. *)
let kdf_password ~mnemonic =
  Normalize.nfkd (String.concat " " (split_words (normalize_mnemonic mnemonic)))

(* The KDF's input buffers are sized for phrases and passphrases, not for
   pasted documents: the wasm glue carries 1024-byte buffers, and the limit
   is enforced HERE -- before any host-specific code -- so the server and
   the browser refuse the same inputs with the same words. 1000 bytes of
   NFKD passphrase plus the 17-byte version prefix stays inside the wasm
   buffer with margin.

   The password needs no such check: [derive_key] and [kdfInputs] both
   validate first, and 24 BIP-39 words cannot exceed 215 bytes (the longest
   word is eight letters). The worker re-checks both lengths anyway, since
   an unchecked write into wasm memory is worse than a redundant compare. *)
let max_passphrase_bytes = 1000

let kdf_salt ~passphrase =
  let p = Normalize.nfkd passphrase in
  if String.length p > max_passphrase_bytes then
    raise
      (Bad_passphrase
         {
           code = "passphrase_too_long";
           arg = string_of_int (String.length p);
           message =
             Printf.sprintf
               "passphrase too long: %d bytes NFKD-normalised, the limit is %d"
               (String.length p) max_passphrase_bytes;
         });
  derivation_version ^ p

(* Key derivation is deliberately expensive. Derive once per session and
   cache the result; it must never sit in the per-request path.

   [kdf] is injected (Tessarium_argon2.kdf natively; the browser derives
   with the same C as wasm and never calls this function): this library
   also compiles under js_of_ocaml, where C stubs cannot follow. *)
let derive_key ~kdf ~mnemonic ~passphrase =
  match validate_mnemonic mnemonic with
  | Error e -> raise (Bad_mnemonic e)
  | Ok () ->
      kdf ~password:(kdf_password ~mnemonic) ~salt:(kdf_salt ~passphrase)

(* ------------------------------------------------------------- addresses *)

let address_to_string (w1, w2, w3, n) =
  Printf.sprintf "%s.%s.%s.%04d" Wordlist.words.(Z.to_int w1)
    Wordlist.words.(Z.to_int w2) Wordlist.words.(Z.to_int w3) (Z.to_int n)

(* The abbreviation rule is PROVED, in fstar/Tessarium.Words.fst: nothing
   resolves to a word the typing does not spell the beginning of. That is
   there because the rule shipped wrong -- it compared the first four letters
   of the INPUT, which makes "cannot" an abbreviation of "cannon", so a word
   the user never typed decoded to a square they never meant and nothing said
   so. A test now covers three spellings of that; the theorem covers every
   input against every list.

   Bytes, because the proved module works on bytes -- see its header for why
   F* strings could not carry the claim. *)
(* The list, reachable from outside. Everything else here takes an index or a
   spelling, and that is the right shape for callers -- but a test that holds
   the fast path below to the proved lookup has to walk every word, and it
   cannot reach `Wordlist` through this module's namespace. Read-only by
   construction: an accessor and a count, not the array. *)
let word_count = Array.length Wordlist.words
let word_at i = Wordlist.words.(i)

let bytes_of_word w =
  List.init (String.length w) (fun i -> Z.of_int (Char.code w.[i]))

(* Built once. [address_of_string] resolves three words per address, and
   rebuilding 2048 byte lists per call would be most of a decode. *)
let word_bytes =
  lazy (Array.to_list Wordlist.words |> List.map bytes_of_word)

(* No two words are the same word.

   The proved lookup answers with the FIRST index whose word matches; the
   hashtable below answers with whichever the table kept. On a list with a
   duplicate those are two different answers to one question, and which one a
   user got would depend on a fast path. BIP-39 has no duplicate, and this is
   the line that means the code does not merely assume so. Checked once, at
   load, because the list is generated and a regeneration is exactly when it
   could stop being true. *)
let () =
  if Hashtbl.length Wordlist.index <> Array.length Wordlist.words then
    failwith "tessarium: the wordlist holds a duplicate word"

(* A word spelled in full is the common case -- a pasted address -- and
   walking 2048 byte lists for it costs 25x what a hashtable does, measured
   in the browser. So the table stays, as a fast path, and carries the
   theorem's property as a runtime check instead of a proof: [i] is only
   accepted when the list really does hold [w] there. One string comparison.
   With the duplicate check above, the two paths cannot give different
   answers, and if the guard ever failed the fall-through is the proved
   lookup, which is right either way. *)
let resolve_word w =
  match Hashtbl.find_opt Wordlist.index w with
  | Some i
    when i < Array.length Wordlist.words && String.equal Wordlist.words.(i) w ->
      Some i
  | _ -> (
      match Tessarium_Words.resolve (bytes_of_word w) (Lazy.force word_bytes) with
      | Some i -> Some (Z.to_int i)
      | None -> None)

let split_address s =
  let norm =
    String.map (function ',' | '/' | ' ' | '-' | '_' -> '.' | c -> c)
      (String.trim (String.lowercase_ascii s))
  in
  String.split_on_char '.' norm |> List.filter (fun p -> p <> "")

(* Does this text name an address -- and if not, might it be about to?

   One input now serves both place names and addresses, and the two must not
   be confused in either direction. An address is a secret: sending one to the
   place index would put it in a request, in a log, and (in a hosted
   deployment) on a network. Answering "paper.later.curve.0851" with a village
   in France called Papere is the same bug seen from the other side.

   The decision lives here, beside the format it is about, rather than as a
   second parser in TypeScript that would drift from this one the first time
   the format moved. It has to cover EVERY spelling [split_address] accepts --
   `,` `/` space `-` `_` `.` -- and an earlier version covered only the dot,
   which left "vacuum-penalty-health-347" (three words and three of four
   digits) going to the place index on its way to being typed.

   [Complete] is the shape [address_of_string] accepts. The WORDS are not
   checked: a mistyped word is still an address attempt, and the honest answer
   to it is "that is not a BIP-39 word", not a place three hundred miles away.

   [Partial] is text on its way to becoming an address, and it exists only so
   that nothing is sent while a user is still typing one. Two tests, because
   the separators fall into two groups:

   - PUNCTUATION a place name does not use that way: a dot, comma, slash or
     underscore with nothing after it, or a non-space after it. "st. louis"
     and "Fixtureville, ZZ" put a space after theirs; "dream." and
     "dream,tourist" do not. This catches a mistyped address too, since it
     looks at the punctuation rather than at the words.
   - THE WORDLIST, for space and dash, which places genuinely use: "new york
     city" and "Stratford-upon-Avon" are places. Two or more BIP-39 words is
     what separates them -- each of those has exactly one ("city", "upon"),
     while two thirds of an address has two. Digits do not count towards it,
     or "highway 4 exit 12" would be withheld, and the match is exact rather
     than by four-letter prefix, or "orange county" would be.

   The bias runs one way on purpose. "route 66 exit 1234" is read as an
   address and answered with "'route' is not a BIP-39 word" rather than
   searched, and a place that happens to be two BIP-39 words ("Canyon River")
   is withheld. Failing towards silence costs a search; failing the other way
   spends a secret, and only one of those can be taken back. *)
type address_shape = Complete | Partial | Not_address

let address_shape s =
  let digits t = t <> "" && String.for_all (fun c -> c >= '0' && c <= '9') t in
  let t = String.trim s in
  let n = String.length t in
  let tight = ref false in
  String.iteri
    (fun i c ->
      if
        (c = '.' || c = ',' || c = '/' || c = '_')
        && (i = n - 1 || t.[i + 1] <> ' ')
      then tight := true)
    t;
  let parts = split_address s in
  (* Exact membership, NOT resolve_word: the four-letter prefix rule resolves
     "county" to "country" and "penalty" to itself alike, and counting those
     withheld "orange county" from the place index. The cost is that the
     abbreviated spelling is only recognised once it is complete -- "drea tour
     cree" reads as a place name until its number arrives. *)
  let is_word p = (not (digits p)) && Hashtbl.mem Wordlist.index p in
  (* The LAST part is the one being typed, so it counts when it can still only
     become one word: "vacuum pena" is an address, because nothing but
     "penalty" starts that way. Uniqueness is what keeps it safe -- "orange
     county" does not count, because no BIP-39 word starts with "county", and
     "north can" does not, because seven do. *)
  let becoming_word p =
    p <> "" && (not (digits p))
    && (not (Hashtbl.mem Wordlist.index p))
    (* The same proved predicate the resolver uses, rather than a second
       hand-written prefix comparison beside it -- which is what the two were
       before, and only one of them was right. [p] is not a word here, so
       "spells the beginning of" and "is a strict abbreviation of" name the
       same set. *)
    && (match
          Tessarium_Words.matching (bytes_of_word p) (Lazy.force word_bytes)
            Z.zero
        with
       | [ _ ] -> true
       | _ -> false)
  in
  let rec count = function
    | [] -> 0
    | [ last ] -> if is_word last || becoming_word last then 1 else 0
    | p :: rest -> (if is_word p then 1 else 0) + count rest
  in
  let words = count parts in
  (* The UNTRIMMED string: "dream " is a word and a keystroke, and trimming it
     first would make it indistinguishable from "dream" alone -- which is a
     place name someone might mean. *)
  let ends_with_sep =
    String.length s > 0
    &&
    match s.[String.length s - 1] with
    | '.' | ',' | '/' | '_' | '-' | ' ' -> true
    | _ -> false
  in
  match parts with
  | [ _; _; _; num ] when digits num && String.length num = 4 -> Complete
  | _ when !tight -> Partial
  | _ when words >= 2 -> Partial
  (* One word and a separator after it: the second word is being typed. A
     lone "orange" with nothing after it stays a place. *)
  | [ _ ] when words = 1 && ends_with_sep -> Partial
  | _ -> Not_address

let address_shape_string s =
  match address_shape s with
  | Complete -> "complete"
  | Partial -> "partial"
  | Not_address -> "no"

let address_of_string s =
  match split_address s with
  | [ a; b; c; num ] ->
      let is_digits t =
        String.length t = 4 && String.for_all (fun ch -> ch >= '0' && ch <= '9') t
      in
      if not (is_digits num) then
        raise
          (Invalid_address
             {
               code = "address_not_four_digits";
               arg = num;
               message = Printf.sprintf "'%s' is not a four-digit number" num;
             });
      let idx w =
        match resolve_word w with
        | Some i -> Z.of_int i
        | None ->
            raise
              (Invalid_address
                 {
                   code = "address_not_a_word";
                   arg = w;
                   message = Printf.sprintf "'%s' is not a BIP-39 word" w;
                 })
      in
      (idx a, idx b, idx c, Z.of_int (int_of_string num))
  | parts ->
      raise
        (Invalid_address
           {
             code = "address_part_count";
             arg = string_of_int (List.length parts);
             message =
               Printf.sprintf "expected 3 words and a number, got %d parts"
                 (List.length parts);
           })

(* ------------------------------------------------------------ public API *)

let check_range lat lon =
  if Z.lt lat lat_min || Z.gt lat lat_max then
    invalid_arg (Printf.sprintf "latitude %s out of range" (Z.to_string lat));
  if Z.lt lon lon_min || Z.gt lon lon_max then
    invalid_arg (Printf.sprintf "longitude %s out of range" (Z.to_string lon))

(* The arithmetic core, injected -- the same shape as [derive_key ~kdf].

   Two implementations answer this signature: [extracted_core] below (the
   F*-extracted OCaml with digestif's round function) and
   Tessarium_c_core (the same F*, extracted to C by KaRaMeL and linked
   over the FFI). Injecting rather than choosing here is what lets the
   server run one while the tests drive both against each other, and what
   makes the switch a one-value change at a call site instead of an edit
   inside this module.

   They agree on every input the functions BELOW can hand them, which is
   the domain that matters and the one the side-by-side wall sweeps. They
   do not agree on the whole domain this signature admits: the C core
   refuses a key that is not 32 bytes and a word index at or above 2048,
   where the extracted core computes over unbounded nats. Callers reach
   these functions through the wordlist codec and [check_range], which
   cannot produce either.

   Only the arithmetic crosses this boundary. The wordlist codec, the
   range checks on the way in, and the user-facing messages stay here, so
   whichever core is injected produces the same words and the same errors. *)
type core = {
  encode : key:string -> lat:Z.t -> lon:Z.t -> Z.t * Z.t * Z.t * Z.t;
  decode : key:string -> Z.t * Z.t * Z.t * Z.t -> (Z.t * Z.t) option;
  bounds_of_point : lat:Z.t -> lon:Z.t -> Z.t * Z.t * Z.t * Z.t;
}

let extracted_core =
  {
    encode = (fun ~key ~lat ~lon -> Api.encode Crypto.round_fn key tweak lat lon);
    decode = (fun ~key address -> Api.decode Crypto.round_fn key tweak address);
    bounds_of_point = (fun ~lat ~lon -> Api.bounds_of_point lat lon);
  }

let encode_z ~core ~key ~lat ~lon =
  check_range lat lon;
  address_to_string (core.encode ~key ~lat ~lon)

let encode ~core ~key ~lat_ns ~lon_ns =
  encode_z ~core ~key ~lat:(Z.of_int lat_ns) ~lon:(Z.of_int lon_ns)

let decode ~core ~key addr =
  match core.decode ~key (address_of_string addr) with
  | None ->
      Error
        "address does not correspond to any location (about 35% of word \
         combinations do not; check for a typo)"
  | Some (lat, lon) -> Ok (Z.to_int lat, Z.to_int lon)

(* Cell corners for the grid overlay: (lat_lo, lat_hi, lon_lo, lon_hi),
   half-open at the high edge. *)
let cell_bounds_z ~core ~lat ~lon =
  check_range lat lon;
  core.bounds_of_point ~lat ~lon

let cell_bounds ~core ~lat_ns ~lon_ns =
  let a, b, c, d =
    cell_bounds_z ~core ~lat:(Z.of_int lat_ns) ~lon:(Z.of_int lon_ns)
  in
  (Z.to_int a, Z.to_int b, Z.to_int c, Z.to_int d)

(* Every cell overlapping a bounding box, for the map's grid overlay.

   This is a driver over `bounds_of_point`, not a second implementation of the
   grid: it walks by taking each cell's upper edge as the next cell's lower
   edge, which is exact because `cell_bounds` is half-open at the high edge.

   The server drives this. The browser runs a BigInt transcription of it in
   ui/public/core.worker.js, over the same proved `bounds` compiled to wasm --
   two drivers, one proved function. That duplication is deliberate but it is
   not free, so `js/worker-differential.mjs` drives the real worker and this
   walk in one process and requires them to agree cell for cell, on every
   `make test`; a change here that is not made there rings.
   What must NOT happen either side is stepping across cell boundaries in
   floats, which is why both walk in integer nanodegrees.

   [limit] bounds the work: the caller asks for a viewport, and a viewport
   zoomed out far enough covers more cells than any renderer wants. Truncation
   is reported rather than silent, and it means exactly one thing: at least one
   cell overlapping the box was not returned. An earlier version reported
   [false] when the limit ran out inside the LAST row -- cells genuinely
   dropped, caller told the grid was complete -- because it only tested for a
   remaining ROW.

   The zero-width guard ends the ROW, not the walk, and reports no truncation.
   That distinction is load-bearing: the guard fires for real at [lon_max],
   where the last cell in a row is clamped to zero width, so a viewport
   touching the antimeridian would otherwise draw one row and stop. Nothing is
   owed there -- there is no cell beyond the clamp. A row whose upper edge does
   not advance is different: it cannot happen, and if it did the walk would be
   giving up, so that one does report truncation. *)
let cells_in_bounds ~core ~lat_lo ~lon_lo ~lat_hi ~lon_hi ~limit =
  let clamp lo hi v = if Z.lt v lo then lo else if Z.gt v hi then hi else v in
  let lat_lo = clamp lat_min lat_max lat_lo
  and lat_hi = clamp lat_min lat_max lat_hi
  and lon_lo = clamp lon_min lon_max lon_lo
  and lon_hi = clamp lon_min lon_max lon_hi in
  if Z.gt lat_lo lat_hi || Z.gt lon_lo lon_hi then ([], false)
  else
    let rec rows lat acc count =
      if Z.gt lat lat_hi then (acc, false)
      else if count >= limit then (acc, true)
      else
        (* Within one row every cell shares the row's latitude bounds, so the
           row's upper edge comes out of the first cell in it. [cut] is what
           the row reports back: it stopped with cells still owed. *)
        let rec cols lon acc count row_top =
          if Z.gt lon lon_hi then (acc, count, row_top, false)
          else if count >= limit then (acc, count, row_top, true)
          else
            let a, b, c, d = cell_bounds_z ~core ~lat ~lon in
            (* A cell whose upper edge does not advance would loop forever.
               It cannot happen -- widths are positive -- but the guard costs
               nothing and a hung tab costs a lot. *)
            if Z.leq d lon then (acc, count, b, false)
            else cols d ((a, b, c, d) :: acc) (count + 1) b
        in
        let acc, count, row_top, cut =
          cols lon_lo acc count (Z.add lat Z.one)
        in
        if cut || Z.leq row_top lat then (acc, true)
        else rows row_top acc count
    in
    let cells, truncated = rows lat_lo [] 0 in
    (List.rev cells, truncated)
