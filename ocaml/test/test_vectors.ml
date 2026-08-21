(* Differential test of the extracted core against the committed vectors.

   The vectors are generated from the verified core by
   `ocaml/tools/gen_vectors.ml`, so agreement here says the extraction still
   reproduces the design it was extracted from. Phrase generation is the
   exception: it is pinned to BIP-39's own published vectors, because a
   generator checked only against itself proves nothing. *)

let vectors_path = "../../vectors/vectors.json"

let failures = ref 0
let checks = ref 0

let check name ok =
  incr checks;
  if not ok then begin
    incr failures;
    Printf.printf "  FAIL  %s\n" name
  end

(* The extracted core: this suite's job is to check that the EXTRACTION
   still reproduces its committed vectors. The C core is checked against
   this one separately, in test_c_core.ml. *)
let core = Tessarium.extracted_core

(* The production KDF, injected once for the whole suite. *)
let derive_key = Tessarium.derive_key ~kdf:Tessarium_argon2.kdf

let check_eq name a b =
  check (Printf.sprintf "%s (got %s, want %s)" name a b) (String.equal a b)

let hex s =
  String.concat "" (List.map (fun c -> Printf.sprintf "%02x" (Char.code c))
                      (List.init (String.length s) (String.get s)))

let member k = function
  | `Assoc l -> List.assoc k l
  | _ -> failwith "expected object"

let to_int = function
  | `Int i -> i
  | `Intlit s -> int_of_string s
  | _ -> failwith "expected int"

let to_str = function `String s -> s | _ -> failwith "expected string"
let to_list = function `List l -> l | _ -> failwith "expected list"

let () =
  let json = Yojson.Safe.from_file vectors_path in

  (* constants agree with the extracted table *)
  check_eq "grid_version" Tessarium.grid_version (to_str (member "grid_version" json));
  check "total_cells"
    (Z.equal Tessarium.total_cells (Z.of_int (to_int (member "total_cells" json))));
  check "address_space"
    (Z.equal Tessarium.address_space (Z.of_int (to_int (member "address_space" json))));

  (* key derivation *)
  let keys = Hashtbl.create 8 in
  List.iter
    (fun v ->
      let name = to_str (member "name" v) in
      let mnemonic = to_str (member "mnemonic" v) in
      let passphrase =
        match member "passphrase" v with `String p -> p | _ -> ""
      in
      let key = derive_key ~mnemonic ~passphrase in
      Hashtbl.replace keys name key;
      check_eq (Printf.sprintf "derive_key[%s]" name) (hex key) (to_str (member "key" v)))
    (to_list (member "key_derivation" json));

  (* grid: point -> cell -> centre *)
  List.iter
    (fun v ->
      let lat_ns = to_int (member "lat_ns" v) and lon_ns = to_int (member "lon_ns" v) in
      let cell = Z.to_int (Tessarium_Grid.point_to_cell (Z.of_int lat_ns) (Z.of_int lon_ns)) in
      check
        (Printf.sprintf "point_to_cell(%d,%d) = %d want %d" lat_ns lon_ns cell
           (to_int (member "cell" v)))
        (cell = to_int (member "cell" v));
      let clat, clon = Tessarium_Grid.cell_to_point (Z.of_int cell) in
      check
        (Printf.sprintf "cell_to_point(%d) lat" cell)
        (Z.to_int clat = to_int (member "centre_lat_ns" v));
      check
        (Printf.sprintf "cell_to_point(%d) lon" cell)
        (Z.to_int clon = to_int (member "centre_lon_ns" v)))
    (to_list (member "grid_vectors" json));

  (* feistel permutation, under the fixed key the vectors were generated with
     -- not a derived one *)
  let unhex h =
    String.init (String.length h / 2) (fun i ->
        Char.chr (int_of_string ("0x" ^ String.sub h (2 * i) 2)))
  in
  let zero_key =
    unhex "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
  in
  List.iter
    (fun v ->
      let x = to_int (member "x" v) and y = to_int (member "y" v) in
      let enc =
        Z.to_int
          (Tessarium_Feistel.encrypt Tessarium.round_fn zero_key Tessarium.grid_version
             (Z.of_int x))
      in
      check (Printf.sprintf "encrypt(%d) = %d want %d" x enc y) (enc = y);
      let dec =
        Z.to_int
          (Tessarium_Feistel.decrypt Tessarium.round_fn zero_key Tessarium.grid_version
             (Z.of_int y))
      in
      check (Printf.sprintf "decrypt(%d) round-trips" y) (dec = x))
    (to_list (member "feistel_vectors" json));

  (* end to end *)
  List.iter
    (fun v ->
      let key = Hashtbl.find keys (to_str (member "mnemonic" v)) in
      let lat_ns = to_int (member "lat_ns" v) and lon_ns = to_int (member "lon_ns" v) in
      let want = to_str (member "address" v) in
      let got = Tessarium.encode ~core ~key ~lat_ns ~lon_ns in
      check_eq (Printf.sprintf "encode(%d,%d)" lat_ns lon_ns) got want;
      match Tessarium.decode ~core ~key want with
      | Error e -> check (Printf.sprintf "decode(%s): %s" want e) false
      | Ok (dlat, dlon) ->
          let cell p q = Tessarium_Grid.point_to_cell (Z.of_int p) (Z.of_int q) in
          check
            (Printf.sprintf "decode(%s) lands in the same cell" want)
            (Z.equal (cell dlat dlon) (cell lat_ns lon_ns)))
    (to_list (member "addresses" json));

  (* The BIP-39 passphrase is case-sensitive and used verbatim. An earlier
     version folded it through the mnemonic's normaliser, so "MySecret" and
     "mysecret" produced the same map and every letter's case was thrown away.
     Nothing failed; it just quietly weakened the passphrase. *)
  let m = to_str (member "mnemonic" (List.hd (to_list (member "key_derivation" json)))) in
  let k p = hex (derive_key ~mnemonic:m ~passphrase:p) in
  check "passphrase case is significant" (k "MySecret" <> k "mysecret");
  check "passphrase case is significant (upper)" (k "MYSECRET" <> k "mysecret");
  check "passphrase whitespace is significant" (k " mysecret " <> k "mysecret");
  check "an empty passphrase is unaffected"
    (String.equal (k "") (hex (derive_key ~mnemonic:m ~passphrase:"")));
  (* And the mnemonic itself stays forgiving: its words are lowercase by
     definition, so how it was pasted must not matter. *)
  check "mnemonic case and padding do not matter"
    (String.equal
       (hex (derive_key ~mnemonic:("  " ^ String.uppercase_ascii m ^ "  ") ~passphrase:""))
       (k ""));

  (* Addresses that name no location must be refused, not resolved to
     something. Taken from the vectors, where they are generated, because
     which combinations are invalid is decided by the permutation and changes
     completely with the grid version. *)
  let addr_key =
    Hashtbl.find keys
      (to_str (member "mnemonic" (List.hd (to_list (member "addresses" json)))))
  in
  List.iter
    (fun a ->
      let addr = to_str a in
      check
        (Printf.sprintf "%s names no location" addr)
        (match Tessarium.decode ~core ~key:addr_key addr with Error _ -> true | Ok _ -> false))
    (to_list (member "invalid_addresses" json));

  (* ------------------------------------------------ unicode passphrases *)

  (* BIP-39 requires NFKD before hashing. Two passphrases that are identical on
     screen can be different byte sequences -- a precomposed "é" versus an "e"
     followed by a combining accent -- and which one a user gets depends on
     their keyboard and their clipboard, not on any choice they made. Without
     normalisation they derive different keys and the user is told nothing:
     they just get a map they do not recognise.

     Every earlier passphrase vector was ASCII, where NFKD is the identity,
     which is precisely why this survived so long. *)
  check "NFKD makes a precomposed and a decomposed accent one string"
    (String.equal (Tessarium.nfkd "caf\xc3\xa9") (Tessarium.nfkd "cafe\xcc\x81"));
  check "NFKD leaves ASCII alone"
    (String.equal (Tessarium.nfkd "mnemonic") "mnemonic");
  (* NFKD, not NFD: compatibility characters fold too. Half-width katakana is
     the case BIP-39's own Japanese vectors exercise. *)
  check "NFKD folds compatibility characters"
    (not (String.equal (Tessarium.nfkd "\xef\xbd\xb1") "\xef\xbd\xb1"));

  let key_named name =
    List.find (fun v -> String.equal (to_str (member "name" v)) name)
      (to_list (member "key_derivation" json))
  in
  let derived name =
    let v = key_named name in
    hex
      (derive_key
         ~mnemonic:(to_str (member "mnemonic" v))
         ~passphrase:(to_str (member "passphrase" v)))
  in
  check "the same passphrase in two encodings gives one key"
    (String.equal (derived "pass-nfc") (derived "pass-nfd"));
  check "a non-ASCII passphrase still changes the key"
    (not (String.equal (derived "pass-nfc") (derived "zero")));

  (* ------------------------------------------------- phrase generation *)

  (* BIP-39's own published 256-bit vectors. This is the one function here
     whose output cannot be judged by looking at it -- a phrase built from a
     counter is indistinguishable from one built by a hardware RNG -- so it is
     pinned to the standard rather than to this project's own output. Getting
     it wrong would produce phrases that look perfect and are not BIP-39. *)
  let repeat b = String.make 32 (Char.chr b) in
  let rep w n = String.concat " " (List.init n (fun _ -> w)) in
  List.iter
    (fun (entropy, want) ->
      check_eq
        (Printf.sprintf "mnemonic_of_entropy(%02x repeated)" (Char.code entropy.[0]))
        (Tessarium.mnemonic_of_entropy entropy)
        want)
    [
      (repeat 0x00, rep "abandon" 23 ^ " art");
      ( repeat 0x7f,
        rep "legal winner thank year wave sausage worth useful" 2
        ^ " legal winner thank year wave sausage worth title" );
      ( repeat 0x80,
        rep "letter advice cage absurd amount doctor acoustic avoid" 2
        ^ " letter advice cage absurd amount doctor acoustic bless" );
      (repeat 0xff, rep "zoo" 23 ^ " vote");
    ];

  (* Whatever the generator emits, the application must accept. A generator
     whose phrases fail their own checksum is worse than no generator: the
     user writes down 24 words and then cannot get back in. *)
  let generated =
    List.init 256 (fun i ->
        (* 31 is odd, so i -> 31i mod 256 is a bijection and these 256
           entropy blocks are genuinely distinct. *)
        Tessarium.mnemonic_of_entropy
          (String.init 32 (fun j -> Char.chr (((i * 31) + (j * 7)) land 0xff))))
  in
  check "every generated phrase passes validation"
    (List.for_all (fun m -> Tessarium.validate_mnemonic m = Ok ()) generated);
  check "every generated phrase is 24 words"
    (List.for_all (fun m -> List.length (String.split_on_char ' ' m) = 24) generated);
  (* Distinct inputs give distinct phrases. Cheap, and it would catch a
     generator that had been wired to a constant. *)
  check "distinct entropy gives distinct phrases"
    (List.length (List.sort_uniq compare generated) = 256);
  check "entropy of the wrong length is refused"
    (try ignore (Tessarium.mnemonic_of_entropy (String.make 16 '\x00')); false
     with Invalid_argument _ -> true);

  Printf.printf "\n%d checks, %d failures\n" !checks !failures;
  if !failures > 0 then exit 1 else print_endline "all vectors reproduce"
