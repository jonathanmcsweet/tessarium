(* Unicode NFKD, which BIP-39 requires before hashing.

   Two strings that look identical on screen can be different byte sequences:
   "é" is either one code point or an "e" followed by a combining accent, and
   which one you get depends on the keyboard, the operating system and the
   clipboard. Without normalisation the same typed passphrase derives two
   different keys on two different machines, and the user is told nothing --
   they simply get a map they do not recognise, with no way to find out why.

   ASCII is unaffected: NFKD is the identity on it. That is exactly why this
   went unnoticed for so long, and why the vectors now include a passphrase
   with a decomposable character in it. *)

let nfkd (s : string) : string =
  let nf = Uunf.create `NFKD in
  let buf = Buffer.create (String.length s) in
  (* uunf is a pull machine: feed one value, then drain until it asks for the
     next. *)
  let rec drain v =
    match Uunf.add nf v with
    | `Uchar u ->
        Buffer.add_utf_8_uchar buf u;
        drain `Await
    | `Await | `End -> ()
  in
  let i = ref 0 in
  while !i < String.length s do
    let d = String.get_utf_8_uchar s !i in
    (* Malformed input decodes to U+FFFD rather than raising. A passphrase is
       whatever the user typed; this is not the place to reject it, and
       silently truncating it would be worse than replacing one character. *)
    drain (`Uchar (Uchar.utf_decode_uchar d));
    i := !i + Uchar.utf_decode_length d
  done;
  drain `End;
  Buffer.contents buf
