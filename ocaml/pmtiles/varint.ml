(* LEB128 varints, as PMTiles directories use them.

   Values stay in OCaml's native int. That is 63 bits here, and the largest
   thing encoded is a byte offset into the archive -- a planet build is around
   10^11 -- so there is a factor of 10^7 in hand. This code is never compiled
   to JavaScript, where int is 32 bits; the browser reads PMTiles through
   pmtiles.js, not through this. *)

let decode s pos =
  let rec go acc shift pos =
    if pos >= String.length s then invalid_arg "varint: truncated"
    else
      let b = Char.code (String.unsafe_get s pos) in
      let acc = acc lor ((b land 0x7f) lsl shift) in
      if b land 0x80 = 0 then (acc, pos + 1)
      else if shift > 56 then invalid_arg "varint: too long"
      else go acc (shift + 7) (pos + 1)
  in
  go 0 0 pos

let encode buf n =
  if n < 0 then invalid_arg "varint: negative";
  let rec go n =
    if n < 0x80 then Buffer.add_char buf (Char.unsafe_chr n)
    else begin
      Buffer.add_char buf (Char.unsafe_chr ((n land 0x7f) lor 0x80));
      go (n lsr 7)
    end
  in
  go n
