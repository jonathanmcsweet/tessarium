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
#include "Tessarium_Low_Blake2s.h"
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

/* One compress call over a 64-byte block, little-endian words in, chained
   state out. Harness-side scaffolding for the RFC and KAT vectors: a wrong
   shift here fails against the published digests, it cannot make anything
   pass. */
typedef Tessarium_Low_Blake2s_st8 st8;

static void compress_block(uint64_t h[8], const uint8_t b[64], uint64_t t,
                           uint64_t f) {
  uint64_t m[16];
  for (int i = 0; i < 16; i++)
    m[i] = (uint64_t)b[4 * i] | ((uint64_t)b[4 * i + 1] << 8) |
           ((uint64_t)b[4 * i + 2] << 16) | ((uint64_t)b[4 * i + 3] << 24);
  st8 r = Tessarium_Low_Blake2s_compress(
      h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7],
      m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7],
      m[8], m[9], m[10], m[11], m[12], m[13], m[14], m[15], t, f);
  h[0] = r.fst; h[1] = r.snd; h[2] = r.thd; h[3] = r.f3;
  h[4] = r.f4;  h[5] = r.f5;  h[6] = r.f6;  h[7] = r.f7;
}

/* General keyed BLAKE2s-256 rebuilt over the extracted compress (RFC 7693
   section 3.3): the zero-padded key block first when a key is present, then
   the message in 64-byte blocks, the byte counter at the true count, the
   finalization word all-ones on the last block only. Exercises the general
   chaining the fixed-shape blake2s43 never uses -- which is the point: a
   wrong sigma or rotation cannot hide behind the production layout. */
static void blake2s256(const uint8_t *key, size_t klen, const uint8_t *msg,
                       size_t len, uint64_t out[8]) {
  uint64_t h[8] = { Tessarium_Low_Blake2s_iv0 ^ 0x01010000ULL ^
                        ((uint64_t)klen << 8) ^ 32ULL,
                    Tessarium_Low_Blake2s_iv1, Tessarium_Low_Blake2s_iv2,
                    Tessarium_Low_Blake2s_iv3, Tessarium_Low_Blake2s_iv4,
                    Tessarium_Low_Blake2s_iv5, Tessarium_Low_Blake2s_iv6,
                    Tessarium_Low_Blake2s_iv7 };
  uint8_t b[64];
  if (klen > 0) {
    for (size_t i = 0; i < 64; i++) b[i] = i < klen ? key[i] : 0;
    compress_block(h, b, 64, len == 0 ? 0xffffffffULL : 0);
  }
  if (klen == 0 || len > 0) {
    uint64_t base = klen > 0 ? 64 : 0;
    size_t off = 0;
    do {
      size_t chunk = len - off > 64 ? 64 : len - off;
      for (size_t i = 0; i < 64; i++) b[i] = i < chunk ? msg[off + i] : 0;
      compress_block(h, b, base + off + chunk,
                     off + chunk == len ? 0xffffffffULL : 0);
      off += chunk;
    } while (off < len);
  }
  for (int i = 0; i < 8; i++) out[i] = h[i];
}

/* RFC 7693 appendix B ("abc", unkeyed) and the reference implementation's
   keyed KAT (key = 00..1f, message bytes 00,01,..): the empty-message row
   is the KAT's published first entry; the 47-, 64- and 129-byte rows are
   re-derived with hashlib and cross-checked against digestif before being
   hardcoded (47 is the production message length, 64 the block boundary,
   129 a three-block chain). These pin compress -- the IV, the sigma
   wiring, the rotations, the parameter block -- independently of the MAC
   layout above it. Words are the digest's little-endian words, which are
   the state words themselves. */
static const uint64_t kat_abc[8] = {
  0x8c5e8c50ULL, 0xe2147c32ULL, 0xa32ba7e1ULL, 0x2f45eb4eULL,
  0x208b4537ULL, 0x293ad69eULL, 0x4c9b994dULL, 0x82596786ULL,
};
static const struct { size_t mlen; uint64_t d[8]; } kat_keyed[4] = {
  { 0, { 0x7d99a848ULL, 0x6b8707a4ULL, 0xd9c0793dULL, 0x3bad2523ULL,
         0x54b7cb89ULL, 0x1ab76ad8ULL, 0xd37a04eeULL, 0x492cfd45ULL } },
  { 47, { 0xe26355d0ULL, 0xc4a0cbb1ULL, 0xbde8a1a2ULL, 0xd9a0a1e3ULL,
          0x850cb4f5ULL, 0xf5d670a0ULL, 0x6e0621fbULL, 0x01065dadULL } },
  { 64, { 0x57b07589ULL, 0x6655d37fULL, 0x62b350d7ULL, 0x267a89b0ULL,
          0x6d1399c3ULL, 0xabab7bf0ULL, 0x3f20e6bdULL, 0xd44e95f2ULL } },
  { 129, { 0x8d3aa746ULL, 0x590fe7d3ULL, 0x012c94d3ULL, 0xef9d59dfULL,
           0xa89d3c78ULL, 0x2232d82fULL, 0x532b66cdULL, 0xdfdbe7dcULL } },
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
  {
    uint64_t d[8];
    uint8_t pat[256];
    for (int i = 0; i < 256; i++) pat[i] = (uint8_t)i;
    blake2s256(NULL, 0, (const uint8_t *)"abc", 3, d);
    for (int j = 0; j < 8; j++) {
      if (d[j] != kat_abc[j]) {
        fprintf(stderr, "RFC 7693 abc word %d: got %" PRIx64 "\n", j, d[j]);
        bad = 1;
      }
    }
    for (int i = 0; i < 4; i++) {
      blake2s256(pat, 32, pat, kat_keyed[i].mlen, d);
      for (int j = 0; j < 8; j++) {
        if (d[j] != kat_keyed[i].d[j]) {
          fprintf(stderr, "keyed KAT len %zu word %d: got %" PRIx64 "\n",
                  kat_keyed[i].mlen, j, d[j]);
          bad = 1;
        }
      }
    }
  }

  /* digestif's answers for the production keyed-BLAKE2s layout, replayed
     through the proved machine round function. */
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
     against what the extracted OCaml core with digestif computed -- which
     is what generates the committed vectors, and no longer what the
     server's HTTP API answers from. */
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
         "%d rejections, with compress pinned to the RFC 7693 digest "
         "and 4 keyed KAT rows\n",
         FE_COUNT, GRID_COUNT, CODEC_COUNT, E2E_COUNT, NONE_COUNT,
         REAL_RF_COUNT, REAL_E2E_COUNT, REAL_NONE_COUNT);
  return 0;
}
