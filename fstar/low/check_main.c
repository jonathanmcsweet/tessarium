/* Replays gen_check's vectors against the KaRaMeL-emitted core.

   The triangle: the EXTRACTED OCaml computed these numbers
   (check_vectors.h), F*'s evaluator re-derives the Feistel vectors and
   the seven e2e grid points from the proved source (make
   check-extraction; the five generated grid points and the bounds rows
   rest on OCaml-vs-C disagreement alone), and the C emitted from the
   machine-integer port must reproduce them all here. The port's
   agreement with the spec is a THEOREM; this harness is the runtime
   tripwire over the stages after the proof: F*'s .krml emission (whose
   erasure and ML translation are shared with the OCaml extraction -- the
   evaluator leg watches that part), krml itself, the C compiler, and the
   unproved plumbing named below (the table lookup, and gen_check's
   emission -- which re-parses its own output; see check_vectors.h). */

#include <inttypes.h>
#include <stdio.h>

#include "Tessarium_Low_Check.h"
#include "check_vectors.h"

/* A harness that can pass on nothing is not a harness, and a table of the
   wrong size is not the table. All counts and the table's corner values
   pinned HERE, by hand -- a generator that silently shrinks any corpus
   fails to compile. */
_Static_assert(FE_COUNT == 16, "sixteen feistel vectors");
_Static_assert(GRID_COUNT == 13, "thirteen grid vectors");
_Static_assert(CUM_COUNT == 4097, "the band table has 4096 bands");
_Static_assert(CODEC_COUNT == 10, "ten codec vectors");
_Static_assert(E2E_COUNT == 7, "seven end-to-end points");
_Static_assert(NONE_COUNT == 2, "two rejected addresses");

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
  /* The whole table, not just the entries the vectors happen to read:
     strictly increasing, steps within the width bound, both ends pinned
     to hand-written literals (cum[4096] * 1600 is the proved
     total_cells). This is the well-formedness the proofs REQUIRE of the
     lookup; the exact per-entry values are pinned by gen_check's
     write-then-reparse and CI's byte diff. */
  if (cum_table[0] != 0ULL) {
    fprintf(stderr, "cum_table[0] is not 0\n");
    bad = 1;
  }
  if (cum_table[4096] != 34807542340ULL) {
    fprintf(stderr, "cum_table[4096] is not total_cells / 1600\n");
    bad = 1;
  }
  for (int b = 0; b < 4096; b++) {
    if (cum_table[b] >= cum_table[b + 1] ||
        cum_table[b + 1] - cum_table[b] > 13343409ULL) {
      fprintf(stderr, "cum_table step %d out of shape\n", b);
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
    /* The composed overlay query: same numbers, through the Api root. */
    K___uint64_t_uint64_t_uint64_t_uint64_t bp =
        Tessarium_Low_Check_check_bounds_of_point(cum_lookup, gvec_dlat[i],
                                                    gvec_dlon[i]);
    if (bp.fst != gvec_blatlo[i] || bp.snd != gvec_blathi[i] ||
        bp.thd != gvec_blonlo[i] || bp.f3 != gvec_blonhi[i]) {
      fprintf(stderr, "grid vector %d: bounds_of_point mismatch\n", i);
      bad = 1;
    }
  }
  for (int i = 0; i < CODEC_COUNT; i++) {
    K___uint64_t_uint64_t_uint64_t_uint64_t a =
        Tessarium_Low_Check_check_to_address(cvec_i[i]);
    if (a.fst != cvec_w1[i] || a.snd != cvec_w2[i] ||
        a.thd != cvec_w3[i] || a.f3 != cvec_n[i]) {
      fprintf(stderr, "codec vector %d: to_address mismatch\n", i);
      bad = 1;
    }
    uint64_t back = Tessarium_Low_Check_check_from_address(
        cvec_w1[i], cvec_w2[i], cvec_w3[i], cvec_n[i]);
    if (back != cvec_i[i]) {
      fprintf(stderr, "codec vector %d: from_address mismatch\n", i);
      bad = 1;
    }
  }

  /* Key 7, tweak 9: hardcoded HERE as well as in the F* harness and
     gen_check -- three spellings that must keep agreeing. */
  for (int i = 0; i < E2E_COUNT; i++) {
    K___uint64_t_uint64_t_uint64_t_uint64_t a =
        Tessarium_Low_Check_check_encode(cum_lookup, 7, 9,
                                           evec_dlat[i], evec_dlon[i]);
    if (a.fst != evec_w1[i] || a.snd != evec_w2[i] ||
        a.thd != evec_w3[i] || a.f3 != evec_n[i]) {
      fprintf(stderr, "e2e point %d: encode mismatch\n", i);
      bad = 1;
    }
    K___uint64_t_uint64_t_uint64_t d =
        Tessarium_Low_Check_check_decode(cum_lookup, 7, 9, evec_w1[i],
                                           evec_w2[i], evec_w3[i], evec_n[i]);
    if (d.fst != 1ULL || d.snd != evec_cdlat[i] || d.thd != evec_cdlon[i]) {
      fprintf(stderr, "e2e point %d: decode mismatch\n", i);
      bad = 1;
    }
  }

  for (int i = 0; i < NONE_COUNT; i++) {
    K___uint64_t_uint64_t_uint64_t d =
        Tessarium_Low_Check_check_decode(cum_lookup, 7, 9, nvec_w1[i],
                                           nvec_w2[i], nvec_w3[i], nvec_n[i]);
    if (d.fst != 0ULL || d.snd != 0ULL || d.thd != 0ULL) {
      fprintf(stderr, "rejected address %d: decode did not reject cleanly\n", i);
      bad = 1;
    }
  }

  if (bad) return 1;
  printf("the C core agrees on %d feistel vectors, %d grid points, "
         "%d codec vectors, %d end-to-end points, %d rejections and the "
         "whole band table, both directions\n",
         FE_COUNT, GRID_COUNT, CODEC_COUNT, E2E_COUNT, NONE_COUNT);
  return 0;
}
