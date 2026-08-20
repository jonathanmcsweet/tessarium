/* OCaml FFI over the vendored Argon2 reference code (vendor/).

   The parameters are baked HERE -- Argon2id, t=3, m=64 MiB, p=1, 32 bytes
   out (RFC 9106's second recommended option; measured 108 ms native,
   149 ms as wasm) -- so no caller can weaken them by accident. The wasm
   glue (wasm/argon2_glue.c) and the JS oracle bake the same three numbers;
   the differential walls are what notice the three drifting apart.

   The runtime lock is released around the hash: 64 MiB of memory-hard work
   takes ~100 ms, and the server's other fibers should not stall behind an
   unlock. Inputs are copied out before release; the password copy is wiped
   before free. */

#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <stdlib.h>
#include <string.h>

#include "argon2.h"

CAMLprim value caml_argon2id_kdf(value vpass, value vsalt) {
  CAMLparam2(vpass, vsalt);
  CAMLlocal1(res);
  size_t plen = caml_string_length(vpass);
  size_t slen = caml_string_length(vsalt);
  if (slen < ARGON2_MIN_SALT_LENGTH)
    caml_invalid_argument("argon2: salt shorter than 8 bytes");
  unsigned char out[32];
  unsigned char *p = malloc(plen ? plen : 1);
  unsigned char *s = malloc(slen ? slen : 1);
  if (p == NULL || s == NULL) {
    free(p);
    free(s);
    caml_failwith("argon2: out of memory");
  }
  memcpy(p, Bytes_val(vpass), plen);
  memcpy(s, Bytes_val(vsalt), slen);
  caml_release_runtime_system();
  int rc = argon2id_hash_raw(3, 65536, 1, p, plen, s, slen, out, sizeof out);
  caml_acquire_runtime_system();
  memset(p, 0, plen);
  free(p);
  free(s);
  if (rc != ARGON2_OK) caml_failwith(argon2_error_message(rc));
  res = caml_alloc_initialized_string(sizeof out, (const char *)out);
  CAMLreturn(res);
}
