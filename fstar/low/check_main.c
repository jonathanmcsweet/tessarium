/* Replays gen_check's Feistel vectors against the KaRaMeL-emitted core.

   The triangle this closes: the EXTRACTED OCaml computed these numbers
   (check_vectors.h), F*'s evaluator re-derives them from the proved source
   (make check-extraction), and the C emitted from the machine-integer port
   must reproduce them here. The port's agreement with the spec is a
   THEOREM (Tessarium.Low.Check.theorem_check_encrypt); this harness is
   the cheap runtime tripwire over the stages after the proof: F*'s .krml
   emission (whose erasure and ML translation are shared with the OCaml
   extraction -- the evaluator leg watches that part), krml itself, and
   the C compiler. */

#include <inttypes.h>
#include <stdio.h>

#include "Tessarium_Low_Check.h"
#include "check_vectors.h"

/* A harness that can pass on nothing is not a harness, and a table of the
   wrong size is not the table. Both counts pinned HERE, by hand. */
_Static_assert(FE_COUNT > 0, "vector table must not be empty");
_Static_assert(GRID_COUNT > 0, "grid vector table must not be empty");
_Static_assert(CUM_COUNT == 4097, "the band table has 4096 bands");

/* The table lookup handed to the extracted grid: the one unproved seam on
   this path (three lines, and the array contents are cross-examined
   against the proved source by check/Tessarium.Check.Table). */
static uint64_t cum_lookup(uint64_t b) { return cum_table[b]; }

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
  for (int i = 0; i < GRID_COUNT; i++) {
    uint64_t cell =
        Tessarium_Low_Check_check_point_to_cell(cum_lookup, gvec_dlat[i], gvec_dlon[i]);
    if (cell != gvec_cell[i]) {
      fprintf(stderr, "grid vector %d: cell got %" PRIu64 ", want %" PRIu64 "\n",
              i, cell, gvec_cell[i]);
      bad = 1;
    }
    K___uint64_t_uint64_t p =
        Tessarium_Low_Check_check_cell_to_point(cum_lookup, gvec_cell[i]);
    if (p.fst != gvec_cdlat[i] || p.snd != gvec_cdlon[i]) {
      fprintf(stderr, "grid vector %d: centre mismatch\n", i);
      bad = 1;
    }
    K___uint64_t_uint64_t_uint64_t_uint64_t b =
        Tessarium_Low_Check_check_cell_bounds(cum_lookup, gvec_cell[i]);
    if (b.fst != gvec_blatlo[i] || b.snd != gvec_blathi[i] ||
        b.thd != gvec_blonlo[i] || b.f3 != gvec_blonhi[i]) {
      fprintf(stderr, "grid vector %d: bounds mismatch\n", i);
      bad = 1;
    }
  }
  if (bad) return 1;
  printf("the C core agrees on %d feistel vectors and %d grid points, "
         "both directions\n", FE_COUNT, GRID_COUNT);
  return 0;
}
