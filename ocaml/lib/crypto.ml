(* Hash primitives, and the Feistel round function built from them.

   digestif's pure-OCaml backend, deliberately: the same code has to run
   natively and under js_of_ocaml, and C stubs do not cross into the browser.
   One implementation, no drift between server and client.

   The round function is keyed BLAKE2s (RFC 7693) and the KDF is Argon2id
   (ocaml/argon2, injected at the edges) -- community-vetted primitives,
   chosen when the project moved its security functions off NIST designs
   (see the ledger). SHA-256 remains below in ONE non-security role: the
   BIP-39 wordlist checksum, typo detection fixed by that standard. *)

let sha256 s = Digestif.SHA256.(to_raw_string (digest_string s))

(* ------------------------------------------------------- integer plumbing *)

let z_of_be_bytes s =
  String.fold_left (fun acc c -> Z.add (Z.mul acc (Z.of_int 256)) (Z.of_int (Char.code c)))
    Z.zero s

(* BLAKE2s serializes little-endian; reading its digest low byte first keeps
   the whole v2 protocol swap-free on every implementation. *)
let z_of_le_bytes s =
  String.fold_right (fun c acc -> Z.add (Z.mul acc (Z.of_int 256)) (Z.of_int (Char.code c)))
    s Z.zero

let be_bytes_of_z z n =
  let b = Bytes.create n in
  let v = ref z in
  for i = n - 1 downto 0 do
    Bytes.set b i (Char.chr (Z.to_int (Z.logand !v (Z.of_int 0xff))));
    v := Z.shift_right !v 8
  done;
  Bytes.to_string b

(* --------------------------------------------------------- round function *)

(* The Feistel round function, injected into the verified core: keyed
   BLAKE2s-256 over the fixed 43-byte message, first 16 digest bytes as a
   little-endian integer, reduced mod m.

   128 bits are taken before reduction. With m < 2^24 the modulo bias is around
   2^-104, far below anything that matters. *)
let round_fn (key : string) (tweak : string) (i : Z.t) (x : Z.t) (m : Z.t) : Z.t =
  let buf = Buffer.create 64 in
  (* Every address depends on these exact bytes, and its LENGTH is
     load-bearing: fstar/low/Tessarium.Low.Blake2s.fst transcribes the whole
     message as sixteen literal words and a byte counter, all derived from
     this prefix being 16 bytes and the tweak 16. Changing either re-does
     that transcription -- see the v2-to-v3 entry in roadmap-progress.md for
     what it takes. *)
  Buffer.add_string buf "tessarium/v3/fe1";
  let tl = String.length tweak in
  Buffer.add_char buf (Char.chr ((tl lsr 8) land 0xff));
  Buffer.add_char buf (Char.chr (tl land 0xff));
  Buffer.add_string buf tweak;
  Buffer.add_char buf (Char.chr (Z.to_int i land 0xff));
  Buffer.add_string buf (be_bytes_of_z x 8);
  let digest =
    Digestif.BLAKE2S.(to_raw_string (Keyed.mac_string ~key (Buffer.contents buf)))
  in
  Z.rem (z_of_le_bytes (String.sub digest 0 16)) m
