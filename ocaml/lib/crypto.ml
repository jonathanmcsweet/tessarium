(* Hash primitives, and the Feistel round function built from them.

   digestif's pure-OCaml backend, deliberately: the same code has to run
   natively and under js_of_ocaml, and C stubs do not cross into the browser.
   One implementation, no drift between server and client.

   PBKDF2 and HKDF are written here rather than taken from a library because
   both are a few lines over HMAC and both are pinned by RFC test vectors. *)

let sha256 s = Digestif.SHA256.(to_raw_string (digest_string s))
let hmac_sha256 ~key msg = Digestif.SHA256.(to_raw_string (hmac_string ~key msg))
let hmac_sha512 ~key msg = Digestif.SHA512.(to_raw_string (hmac_string ~key msg))

let xor a b =
  String.init (String.length a) (fun i ->
      Char.chr (Char.code a.[i] lxor Char.code b.[i]))

(* RFC 2898. dklen here is always 64, one SHA-512 block, but the block loop is
   written out so the function is not silently wrong if that changes. *)
let pbkdf2_sha512 ~password ~salt ~count ~dklen =
  let block i =
    let be32 =
      String.init 4 (fun j -> Char.chr ((i lsr (8 * (3 - j))) land 0xff))
    in
    let u = ref (hmac_sha512 ~key:password (salt ^ be32)) in
    let acc = ref !u in
    for _ = 2 to count do
      u := hmac_sha512 ~key:password !u;
      acc := xor !acc !u
    done;
    !acc
  in
  let buf = Buffer.create dklen in
  let i = ref 1 in
  while Buffer.length buf < dklen do
    Buffer.add_string buf (block !i);
    incr i
  done;
  String.sub (Buffer.contents buf) 0 dklen

(* ------------------------------------------------------- integer plumbing *)

let z_of_be_bytes s =
  String.fold_left (fun acc c -> Z.add (Z.mul acc (Z.of_int 256)) (Z.of_int (Char.code c)))
    Z.zero s

let be_bytes_of_z z n =
  let b = Bytes.create n in
  let v = ref z in
  for i = n - 1 downto 0 do
    Bytes.set b i (Char.chr (Z.to_int (Z.logand !v (Z.of_int 0xff))));
    v := Z.shift_right !v 8
  done;
  Bytes.to_string b

(* --------------------------------------------------------- round function *)

(* The Feistel round function, injected into the verified core.

   128 bits are taken before reduction. With m < 2^24 the modulo bias is around
   2^-104, far below anything that matters. *)
let round_fn (key : string) (tweak : string) (i : Z.t) (x : Z.t) (m : Z.t) : Z.t =
  let buf = Buffer.create 64 in
  Buffer.add_string buf "tessarium/v1/fe1";
  let tl = String.length tweak in
  Buffer.add_char buf (Char.chr ((tl lsr 8) land 0xff));
  Buffer.add_char buf (Char.chr (tl land 0xff));
  Buffer.add_string buf tweak;
  Buffer.add_char buf (Char.chr (Z.to_int i land 0xff));
  Buffer.add_string buf (be_bytes_of_z x 8);
  let digest = hmac_sha256 ~key (Buffer.contents buf) in
  Z.rem (z_of_be_bytes (String.sub digest 0 16)) m
