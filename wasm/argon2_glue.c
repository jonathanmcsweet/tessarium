/* The browser face of the KDF.

   Compiled from the SAME vendored Argon2 reference C the server links
   (ocaml/argon2/vendor) to wasm32-wasi by the pinned zig -- one
   implementation of the primitive, two hosts, byte-identical answers.
   `make sync-argon2-wasm` rebuilds; CI rebuilds and byte-diffs the
   committed module. Unlike wasm/core.wasm this IS wired into the UI:
   the worker feeds it the KDF inputs the js_of_ocaml core builds
   (kdfInputs -- one normalization authority) and reads the 32-byte key.

   The parameters are baked here exactly as in ocaml/argon2/argon2_stubs.c
   -- Argon2id, t=3, m=64 MiB, p=1, 32 bytes out -- so the two hosts
   cannot drift apart by configuration; js/argon2-differential.mjs rings
   if they drift by code. Same wasi story as core.wasm: single random_get
   import from the crt stack guard, callers run _initialize first.

   Fixed input buffers rather than an allocator: a 24-word phrase is under
   300 bytes and the salt is the 17-byte version prefix plus a passphrase.
   1024 covers both with a wide margin, and the range checks below turn an
   overflow into an error return instead of a truncated secret. */

#include <stdint.h>
#include <string.h>

#include "argon2.h"

static unsigned char password[1024];
static unsigned char salt[1024];
static unsigned char out[32];

__attribute__((export_name("password_ptr"))) unsigned char *password_ptr(void) {
  return password;
}
__attribute__((export_name("salt_ptr"))) unsigned char *salt_ptr(void) {
  return salt;
}
__attribute__((export_name("out_ptr"))) const unsigned char *out_ptr(void) {
  return out;
}

__attribute__((export_name("kdf"))) int32_t kdf(uint32_t plen, uint32_t slen) {
  if (plen > sizeof password || slen > sizeof salt) return -100;
  if (slen < ARGON2_MIN_SALT_LENGTH) return -101;
  int rc = argon2id_hash_raw(3, 65536, 1, password, plen, salt, slen, out,
                             sizeof out);
  /* The password buffer held phrase bytes; keep their lifetime one call. */
  memset(password, 0, sizeof password);
  memset(salt, 0, sizeof salt);
  return rc;
}
