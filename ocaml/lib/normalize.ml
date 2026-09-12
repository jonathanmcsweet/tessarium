(* Unicode NFKD, which BIP-39 requires before hashing.

   Two strings that look identical on screen can be different byte sequences:
   "é" is either one code point or an "e" followed by a combining accent, and
   which one you get depends on the keyboard, the operating system and the
   clipboard. Without normalisation the same typed secret derives two
   different keys on two different machines, and the user is told nothing --
   they simply get a map they do not recognise, with no way to find out why.

   Since the passphrase came out of the derivation, the only string that
   reaches this is a phrase that has already passed validation against the
   English BIP-39 list, which is ASCII -- and NFKD is the identity on ASCII.
   So it changes nothing today. Kept because the derivation is BIP-39-shaped
   and this is where that requirement lives: dropping it is a decision about
   the format, not a tidy-up, and it would have to be taken again by anyone
   adding a wordlist that is not English. *)

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
    (* Malformed input decodes to U+FFFD rather than raising. This is not the
       place to reject what the user typed, and silently truncating it would
       be worse than replacing one character. *)
    drain (`Uchar (Uchar.utf_decode_uchar d));
    i := !i + Uchar.utf_decode_length d
  done;
  drain `End;
  Buffer.contents buf
