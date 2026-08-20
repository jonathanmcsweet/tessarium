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
#include "Tessarium_Low_Core.h"
#include "Tessarium_Low_Hmac.h"
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
_Static_assert(REAL_RF_COUNT == 16, "sixteen real round function draws");
_Static_assert(REAL_E2E_COUNT == 14, "seven real end-to-end points, two keys");
_Static_assert(REAL_NONE_COUNT == 2, "one real rejected address per key");

/* The table lookup handed to the extracted grid: the one unproved seam on
   this path (three lines, and the array contents are cross-examined
   against the proved source by check/Tessarium.Check.Table). */
static uint64_t cum_lookup(uint64_t b) { return cum_table[b]; }

/* One compress call over a byte block, big-endian words in, chained state
   out. Harness-side scaffolding for the NIST vectors: a wrong shift here
   fails against the published digests, it cannot make anything pass. */
typedef K___uint64_t_uint64_t_uint64_t_uint64_t_uint64_t_uint64_t_uint64_t_uint64_t st8;

static void compress_block(uint64_t st[8], const uint8_t b[64]) {
  uint64_t w[16];
  for (int i = 0; i < 16; i++)
    w[i] = ((uint64_t)b[4 * i] << 24) | ((uint64_t)b[4 * i + 1] << 16) |
           ((uint64_t)b[4 * i + 2] << 8) | (uint64_t)b[4 * i + 3];
  st8 r = Tessarium_Low_Hmac_compress(
      st[0], st[1], st[2], st[3], st[4], st[5], st[6], st[7],
      w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7],
      w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15]);
  st[0] = r.fst; st[1] = r.snd; st[2] = r.thd; st[3] = r.f3;
  st[4] = r.f4;  st[5] = r.f5;  st[6] = r.f6;  st[7] = r.f7;
}

/* SHA-256 of a short message (len <= 55 fits one padded block; the NIST
   two-block vector is exactly 56 and takes the second branch). */
static void sha256_short(const uint8_t *msg, size_t len, uint64_t out[8]) {
  uint64_t st[8] = { Tessarium_Low_Hmac_iv0, Tessarium_Low_Hmac_iv1,
                     Tessarium_Low_Hmac_iv2, Tessarium_Low_Hmac_iv3,
                     Tessarium_Low_Hmac_iv4, Tessarium_Low_Hmac_iv5,
                     Tessarium_Low_Hmac_iv6, Tessarium_Low_Hmac_iv7 };
  uint8_t b[128] = { 0 };
  for (size_t i = 0; i < len; i++) b[i] = msg[i];
  b[len] = 0x80;
  size_t nblocks = (len + 1 + 8 <= 64) ? 1 : 2;
  uint64_t bits = (uint64_t)len * 8;
  for (int i = 0; i < 8; i++)
    b[nblocks * 64 - 1 - i] = (uint8_t)(bits >> (8 * i));
  compress_block(st, b);
  if (nblocks == 2) compress_block(st, b + 64);
  for (int i = 0; i < 8; i++) out[i] = st[i];
}

/* FIPS 180-4 vectors: empty, "abc", and the two-block message. Constants
   below are the published digests (re-derived with hashlib before being
   hardcoded). These pin compress -- the round constants, the sigmas, the
   schedule -- independently of the HMAC layout above it. */
static const struct { const char *msg; uint64_t d[8]; } nist[3] = {
  { "", { 0xe3b0c442ULL, 0x98fc1c14ULL, 0x9afbf4c8ULL, 0x996fb924ULL,
          0x27ae41e4ULL, 0x649b934cULL, 0xa495991bULL, 0x7852b855ULL } },
  { "abc", { 0xba7816bfULL, 0x8f01cfeaULL, 0x414140deULL, 0x5dae2223ULL,
             0xb00361a3ULL, 0x96177a9cULL, 0xb410ff61ULL, 0xf20015adULL } },
  { "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
    { 0x248d6a61ULL, 0xd20638b8ULL, 0xe5c02693ULL, 0x0c3e6039ULL,
      0xa33ce459ULL, 0x64ff2167ULL, 0xf6ecedd4ULL, 0x19db06c1ULL } },
};


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


  /* ------------------------------------------------ the REAL round function */
  for (int i = 0; i < 3; i++) {
    uint64_t d[8];
    size_t len = 0;
    while (nist[i].msg[len]) len++;
    sha256_short((const uint8_t *)nist[i].msg, len, d);
    for (int j = 0; j < 8; j++) {
      if (d[j] != nist[i].d[j]) {
        fprintf(stderr, "NIST vector %d word %d: got %" PRIx64 "\n", i, j, d[j]);
        bad = 1;
      }
    }
  }

  /* digestif's answers for the production HMAC layout, replayed through
     the proved machine round function. */
  for (int i = 0; i < REAL_RF_COUNT; i++) {
    /* The draws must exercise the moduli the Feistel actually uses --
       gen_check duplicates F.modulus's parity convention, and this pin
       plus Check.RealRound's is what watches that duplication. */
    if (rvec_m[i] != (rvec_i[i] % 2 == 1 ? 6553600ULL : 13107200ULL)) {
      fprintf(stderr, "real rf draw %d: modulus %" PRIu64 " is not modulus(%" PRIu64 ")\n",
              i, rvec_m[i], rvec_i[i]);
      bad = 1;
    }
    st8 k = { .fst = rvec_k0[i], .snd = rvec_k1[i], .thd = rvec_k2[i],
              .f3 = rvec_k3[i], .f4 = rvec_k4[i], .f5 = rvec_k5[i],
              .f6 = rvec_k6[i], .f7 = rvec_k7[i] };
    uint64_t r = Tessarium_Low_Core_rf_real_low(k, rvec_i[i], rvec_x[i], rvec_m[i]);
    if (r != rvec_r[i]) {
      fprintf(stderr, "real rf draw %d: got %" PRIu64 ", want %" PRIu64 "\n",
              i, r, rvec_r[i]);
      bad = 1;
    }
  }

  /* The production composition: encode and decode under real 32-byte keys,
     against what the OCaml server (extracted core + digestif) computed. */
  for (int i = 0; i < REAL_E2E_COUNT; i++) {
    K___uint64_t_uint64_t_uint64_t_uint64_t a = Tessarium_Low_Core_core_encode(
        cum_lookup, revec_k0[i], revec_k1[i], revec_k2[i], revec_k3[i],
        revec_k4[i], revec_k5[i], revec_k6[i], revec_k7[i],
        revec_dlat[i], revec_dlon[i]);
    if (a.fst != revec_w1[i] || a.snd != revec_w2[i] ||
        a.thd != revec_w3[i] || a.f3 != revec_n[i]) {
      fprintf(stderr, "real e2e point %d: encode mismatch\n", i);
      bad = 1;
    }
    K___uint64_t_uint64_t_uint64_t d = Tessarium_Low_Core_core_decode(
        cum_lookup, revec_k0[i], revec_k1[i], revec_k2[i], revec_k3[i],
        revec_k4[i], revec_k5[i], revec_k6[i], revec_k7[i],
        revec_w1[i], revec_w2[i], revec_w3[i], revec_n[i]);
    if (d.fst != 1ULL || d.snd != revec_cdlat[i] || d.thd != revec_cdlon[i]) {
      fprintf(stderr, "real e2e point %d: decode mismatch\n", i);
      bad = 1;
    }
  }

  for (int i = 0; i < REAL_NONE_COUNT; i++) {
    K___uint64_t_uint64_t_uint64_t d = Tessarium_Low_Core_core_decode(
        cum_lookup, rnvec_k0[i], rnvec_k1[i], rnvec_k2[i], rnvec_k3[i],
        rnvec_k4[i], rnvec_k5[i], rnvec_k6[i], rnvec_k7[i],
        rnvec_w1[i], rnvec_w2[i], rnvec_w3[i], rnvec_n[i]);
    if (d.fst != 0ULL || d.snd != 0ULL || d.thd != 0ULL) {
      fprintf(stderr, "real rejected address %d: decode did not reject cleanly\n", i);
      bad = 1;
    }
  }

  if (bad) return 1;
  printf("the C core agrees on %d feistel vectors, %d grid points, "
         "%d codec vectors, %d end-to-end points, %d rejections and the "
         "whole band table, both directions; the REAL round function "
         "answers for digestif on %d draws, %d end-to-end points and "
         "%d rejections, with compress pinned to 3 NIST vectors\n",
         FE_COUNT, GRID_COUNT, CODEC_COUNT, E2E_COUNT, NONE_COUNT,
         REAL_RF_COUNT, REAL_E2E_COUNT, REAL_NONE_COUNT);
  return 0;
}
