(* Argon2id over the vendored reference C. Native only -- the browser runs
   the same C as WebAssembly. Parameters live in the stubs; this signature
   is exactly the [kdf] that Tessarium.derive_key injects. *)

external argon2id_kdf : string -> string -> string = "caml_argon2id_kdf"

let kdf ~password ~salt = argon2id_kdf password salt
