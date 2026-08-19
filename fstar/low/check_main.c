/* Replays gen_check's Feistel vectors against the KaRaMeL-emitted core.

   The triangle this closes: the EXTRACTED OCaml computed these numbers
   (check_vectors.h), F*'s evaluator re-derives them from the proved source
   (make check-extraction), and the C emitted from the machine-integer port
   must reproduce them here. The port's agreement with the spec is a
   THEOREM (Tessarium.Low.Check.theorem_check_encrypt); this harness is
   the cheap runtime tripwire that the emitted C and the C compiler kept
   that agreement. */

#include <inttypes.h>
#include <stdio.h>

#include "Tessarium_Low_Check.h"
#include "check_vectors.h"

int main(void) {
  int bad = 0;
  for (int i = 0; i < FE_COUNT; i++) {
    uint64_t y = Tessarium_Low_Check_check_encrypt(vec_k[i], vec_t[i], vec_x[i]);
    if (y != vec_y[i]) {
      fprintf(stderr, "encrypt vector %d: got %" PRIu64 ", want %" PRIu64 "\n",
              i, y, vec_y[i]);
      bad = 1;
    }
    uint64_t x = Tessarium_Low_Check_check_decrypt(vec_k[i], vec_t[i], vec_y[i]);
    if (x != vec_x[i]) {
      fprintf(stderr, "decrypt vector %d: got %" PRIu64 ", want %" PRIu64 "\n",
              i, x, vec_x[i]);
      bad = 1;
    }
  }
  if (bad) return 1;
  printf("the C core agrees on %d feistel vectors, both directions\n", FE_COUNT);
  return 0;
}
