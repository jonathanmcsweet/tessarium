(* Public API: seed phrase in, addresses out.

   Everything numeric below crosses into the F*-extracted core, which works in
   Zarith integers. OCaml's native int is 63-bit and would hold every value
   here, but the conversion is kept explicit at the boundary rather than
   assumed. *)

module Api = Tessarium_Api
module Table = Tessarium_Table

exception Invalid_address of string
exception Bad_mnemonic of string

let grid_version = Table.grid_version
(* Left as Zarith. Both exceed 2^31, and this module is also compiled to
   JavaScript, where Z.to_int targets a 32-bit int and raises Z.Overflow at
   load time. *)
let total_cells = Table.total_cells
let address_space = Tessarium_Spec.addr_space

(* Bound the mapping to a specific grid. Regenerating the band table changes
   every address rather than silently reinterpreting old ones. *)
let tweak = grid_version

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
let hkdf_salt = "tessarium/v1/salt"
let hkdf_info = "tessarium/v1/feistel-key"

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
      (Printf.sprintf
         "expected %d words, got %d. 12-word phrases are not accepted: 128 bits \
          of entropy is only 64 against a quantum adversary."
         required_words n)
  else
    match List.find_opt (fun w -> not (Hashtbl.mem Wordlist.index w)) words with
    | Some bad -> Error (Printf.sprintf "'%s' is not a BIP-39 word" bad)
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
          Error "checksum failed -- likely a typo in one word"
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

(* PBKDF2 is deliberately slow. Derive once per session and cache the result;
   it must never sit in the per-request path. *)
let derive_key ~mnemonic ~passphrase =
  match validate_mnemonic mnemonic with
  | Error e -> raise (Bad_mnemonic e)
  | Ok () ->
      let words = split_words (normalize_mnemonic mnemonic) in
      let seed =
        Crypto.pbkdf2_sha512
          ~password:(String.concat " " words)
          (* Verbatim, per BIP-39. Not normalised: see normalize_mnemonic. *)
          ~salt:("mnemonic" ^ passphrase)
          ~count:2048 ~dklen:64
      in
      Crypto.hkdf_sha256 ~ikm:seed ~salt:hkdf_salt ~info:hkdf_info ~len:32

(* ------------------------------------------------------------- addresses *)

let address_to_string (w1, w2, w3, n) =
  Printf.sprintf "%s.%s.%s.%04d" Wordlist.words.(Z.to_int w1)
    Wordlist.words.(Z.to_int w2) Wordlist.words.(Z.to_int w3) (Z.to_int n)

(* Exact match, else unique four-letter prefix. BIP-39 guarantees the first
   four letters identify a word, so 'slic' resolves to 'slice'. *)
let resolve_word w =
  match Hashtbl.find_opt Wordlist.index w with
  | Some i -> Some i
  | None ->
      if String.length w < 4 then None
      else
        let p = String.sub w 0 4 in
        let hits =
          Array.to_list Wordlist.words
          |> List.filteri (fun _ _ -> true)
          |> List.mapi (fun i x -> (i, x))
          |> List.filter (fun (_, x) ->
                 String.length x >= 4 && String.sub x 0 4 = p)
        in
        (match hits with [ (i, _) ] -> Some i | _ -> None)

let split_address s =
  let norm =
    String.map (function ',' | '/' | ' ' | '-' | '_' -> '.' | c -> c)
      (String.trim (String.lowercase_ascii s))
  in
  String.split_on_char '.' norm |> List.filter (fun p -> p <> "")

let address_of_string s =
  match split_address s with
  | [ a; b; c; num ] ->
      let is_digits t =
        String.length t = 4 && String.for_all (fun ch -> ch >= '0' && ch <= '9') t
      in
      if not (is_digits num) then
        raise (Invalid_address (Printf.sprintf "'%s' is not a four-digit number" num));
      let idx w =
        match resolve_word w with
        | Some i -> Z.of_int i
        | None -> raise (Invalid_address (Printf.sprintf "'%s' is not a BIP-39 word" w))
      in
      (idx a, idx b, idx c, Z.of_int (int_of_string num))
  | parts ->
      raise
        (Invalid_address
           (Printf.sprintf "expected 3 words and a number, got %d parts"
              (List.length parts)))

(* ------------------------------------------------------------ public API *)

let check_range lat lon =
  if Z.lt lat lat_min || Z.gt lat lat_max then
    invalid_arg (Printf.sprintf "latitude %s out of range" (Z.to_string lat));
  if Z.lt lon lon_min || Z.gt lon lon_max then
    invalid_arg (Printf.sprintf "longitude %s out of range" (Z.to_string lon))

let encode_z ~key ~lat ~lon =
  check_range lat lon;
  address_to_string (Api.encode Crypto.round_fn key tweak lat lon)

let encode ~key ~lat_ns ~lon_ns =
  encode_z ~key ~lat:(Z.of_int lat_ns) ~lon:(Z.of_int lon_ns)

let decode ~key addr =
  match Api.decode Crypto.round_fn key tweak (address_of_string addr) with
  | None ->
      Error
        "address does not correspond to any location (about 35% of word \
         combinations do not; check for a typo)"
  | Some (lat, lon) -> Ok (Z.to_int lat, Z.to_int lon)

(* Cell corners for the grid overlay: (lat_lo, lat_hi, lon_lo, lon_hi),
   half-open at the high edge. *)
let cell_bounds_z ~lat ~lon =
  check_range lat lon;
  Api.bounds_of_point lat lon

let cell_bounds ~lat_ns ~lon_ns =
  let a, b, c, d = cell_bounds_z ~lat:(Z.of_int lat_ns) ~lon:(Z.of_int lon_ns) in
  (Z.to_int a, Z.to_int b, Z.to_int c, Z.to_int d)

(* Every cell overlapping a bounding box, for the map's grid overlay.

   This is a driver over `bounds_of_point`, not a second implementation of the
   grid: it walks by taking each cell's upper edge as the next cell's lower
   edge, which is exact because `cell_bounds` is half-open at the high edge.

   It lives here rather than in the UI because the alternative is stepping
   across cell boundaries in JavaScript floats, and a boundary that lands one
   unit out is the exact bug this project was built to rule out. In integer
   nanodegrees there is no rounding to get wrong.

   [limit] bounds the work: the caller asks for a viewport, and a viewport
   zoomed out far enough covers more cells than any renderer wants. Truncation
   is reported rather than silent. *)
let cells_in_bounds ~lat_lo ~lon_lo ~lat_hi ~lon_hi ~limit =
  let clamp lo hi v = if Z.lt v lo then lo else if Z.gt v hi then hi else v in
  let lat_lo = clamp lat_min lat_max lat_lo
  and lat_hi = clamp lat_min lat_max lat_hi
  and lon_lo = clamp lon_min lon_max lon_lo
  and lon_hi = clamp lon_min lon_max lon_hi in
  if Z.gt lat_lo lat_hi || Z.gt lon_lo lon_hi then ([], false)
  else
    let rec rows lat acc count =
      if Z.gt lat lat_hi || count >= limit then (acc, Z.leq lat lat_hi)
      else
        (* Within one row every cell shares the row's latitude bounds, so the
           row's upper edge comes out of the first cell in it. *)
        let rec cols lon acc count row_top =
          if Z.gt lon lon_hi || count >= limit then (acc, count, row_top)
          else
            let a, b, c, d = cell_bounds_z ~lat ~lon in
            (* A cell whose upper edge does not advance would loop forever.
               It cannot happen -- widths are positive -- but the guard costs
               nothing and a hung tab costs a lot. *)
            if Z.leq d lon then (acc, count, b)
            else cols d ((a, b, c, d) :: acc) (count + 1) b
        in
        let acc, count, row_top = cols lon_lo acc count (Z.add lat Z.one) in
        if Z.leq row_top lat then (acc, true) else rows row_top acc count
    in
    let cells, truncated = rows lat_lo [] 0 in
    (List.rev cells, truncated)
