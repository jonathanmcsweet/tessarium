(* The vendored Argon2id answering for its known-answer vectors.

   The digests below were generated from the reference C at the pinned
   release and INDEPENDENTLY recomputed by noble's argon2id (the audited
   community JS implementation the differential oracle uses) before being
   hardcoded -- two implementations agreeing on every row. They pin the
   production parameter set (t=3, m=64 MiB, p=1, 32 bytes), which is baked
   in the stubs: a parameter drift changes every digest and rings here.
   The salt prefixes are the real kdf-4 shapes on purpose, so these rows
   double as regression pins for the derivation inputs. Recomputed the same
   two ways when the salt moved from kdf-3 to kdf-4 on 2026-08-23; a row
   taken from one implementation alone would pin nothing but itself. *)

let hex s =
  String.concat "" (List.map (fun c -> Printf.sprintf "%02x" (Char.code c))
    (List.init (String.length s) (String.get s)))

let checks = ref 0

let expect what got want =
  incr checks;
  if got <> want then (
    Printf.eprintf "argon2 %s:\n  got  %s\n  want %s\n" what got want;
    exit 1)

let () =
  expect "kat 1"
    (hex (Tessarium_argon2.kdf ~password:"abandon abandon art"
            ~salt:"tessarium-kdf-4"))
    "4ab37670c89a3d270d0e245f3eb0bbc6edaf7ebbc844f2fe6d562302a008d1a0";
  expect "kat 2 (empty password)"
    (hex (Tessarium_argon2.kdf ~password:"" ~salt:"tessarium-kdf-4TREZOR"))
    "2af8e10980bded1389251bd8eda151f9b62fde690f54817b9253fc6f08bebfe8";
  expect "kat 3 (salt with spaces)"
    (hex (Tessarium_argon2.kdf ~password:"legal winner thank year"
            ~salt:"tessarium-kdf-4pass phrase with spaces"))
    "b58143810640d5697e2d29f79dbbf269bd6be60f4e4a4076d020cca40099e1d3";
  (incr checks;
   match Tessarium_argon2.kdf ~password:"x" ~salt:"short" with
   | _ -> Printf.eprintf "argon2: a 5-byte salt was accepted\n"; exit 1
   | exception Invalid_argument _ -> ());
  Printf.printf "argon2id answers for %d known-answer checks (t=3, m=64MiB, p=1)\n"
    !checks
