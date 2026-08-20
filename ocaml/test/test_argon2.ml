(* The vendored Argon2id answering for its known-answer vectors.

   The digests below were generated from the reference C at the pinned
   release and INDEPENDENTLY recomputed by noble's argon2id (the audited
   community JS implementation the differential oracle uses) before being
   hardcoded -- two implementations agreeing on every row. They pin the
   production parameter set (t=3, m=64 MiB, p=1, 32 bytes), which is baked
   in the stubs: a parameter drift changes every digest and rings here.
   The salt prefixes are the real kdf-3 shapes on purpose, so these rows
   double as regression pins for the derivation inputs. *)

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
            ~salt:"tessarium-kdf-3"))
    "ec324348c08e1f2ef1358769f4cc18049f65cadf6b5db22e30137d833789b402";
  expect "kat 2 (empty password)"
    (hex (Tessarium_argon2.kdf ~password:"" ~salt:"tessarium-kdf-3TREZOR"))
    "483ff9aa34f5a9116b285b65a9e280369c024326e2d58db01db1223a6bed4c39";
  expect "kat 3 (salt with spaces)"
    (hex (Tessarium_argon2.kdf ~password:"legal winner thank year"
            ~salt:"tessarium-kdf-3pass phrase with spaces"))
    "7cd269b5d936a19ce8d4c4a8235247dbaeea96fc446af6a1306d2c4b1f5fe369";
  (incr checks;
   match Tessarium_argon2.kdf ~password:"x" ~salt:"short" with
   | _ -> Printf.eprintf "argon2: a 5-byte salt was accepted\n"; exit 1
   | exception Invalid_argument _ -> ());
  Printf.printf "argon2id answers for %d known-answer checks (t=3, m=64MiB, p=1)\n"
    !checks
