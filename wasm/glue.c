/* The browser face of the KaRaMeL-emitted verified core.

   Compiled from the SAME vendored C the server's HTTP API now answers
   from over the FFI (ocaml/c_core/vendor) to wasm32-wasi by a pinned
   zig -- one verified artifact chain, two hosts. `make sync-wasm`
   rebuilds; CI rebuilds and byte-diffs the committed module. Local
   `make test` runs the COMMITTED module: an edit to this file or to
   the vendored C is invisible to every local test until sync-wasm is
   run -- CI's rebuild-and-diff is what catches a stale artifact.

   The compiled paths are pure arithmetic. The module's single import
   is wasi random_get, wanted once by the prebuilt libc init (crt) for
   its stack guard; consumers must call _initialize first (the wasi
   reactor ABI) and provide random_get -- the wall gives deterministic
   zeros and allow-lists exactly that import, so anything new appearing
   rings. The only buffer this file indexes is bounds-checked above
   each access.

   This shim mirrors ocaml/c_core/c_core_stubs.c: the emitted C's
   refinements are erased, so every argument is checked here before the
   proved code runs -- scalar ranges below, the band table's whole shape
   at seal_cum. The table arrives value by value from JS (the caller owns
   which table; the wall feeds prefix sums of the independent
   implementation's bands.json, so a drift between the two tables rings).

   NOT wired into the UI yet: the app still answers from the js_of_ocaml
   core. This module runs beside it under js/wasm-differential.mjs until
   the switch phase, exactly like the server-side story. The eventual UI
   switch also needs 'wasm-unsafe-eval' in the CSP; noted in the roadmap. */

#include <stdint.h>

#include "Tessarium_Low_Core.h"

#define CUM_ENTRIES 4097

static uint64_t cum_table[CUM_ENTRIES];
static int cum_ready = 0;

static uint64_t cum_lookup(uint64_t b) { return cum_table[b]; }

__attribute__((export_name("set_cum"))) int32_t set_cum(uint32_t i,
                                                        uint64_t v) {
  if (i >= CUM_ENTRIES) return 0;
  cum_ready = 0;
  cum_table[i] = v;
  return 1;
}

/* The same shape the C harness pins and the FFI stub enforces: base 0,
   strictly increasing, steps within max_col_count, the proved grand
   total. A wrong-but-well-shaped table is caught by the wall, value by
   value. */
__attribute__((export_name("seal_cum"))) int32_t seal_cum(void) {
  if (cum_table[0] != 0ULL) return 0;
  if (cum_table[CUM_ENTRIES - 1] != 34807542340ULL) return 0;
  for (int i = 0; i < CUM_ENTRIES - 1; i++)
    if (cum_table[i] >= cum_table[i + 1] ||
        cum_table[i + 1] - cum_table[i] > 13343409ULL)
      return 0;
  cum_ready = 1;
  return 1;
}

/* Results cross as a fixed block in linear memory: wasm exports return
   one scalar, and this avoids multi-value plumbing. */
static uint64_t out[4];

__attribute__((export_name("out_ptr"))) uint32_t out_ptr(void) {
  return (uint32_t)(uintptr_t)out;
}

__attribute__((export_name("encode"))) int32_t
wasm_encode(uint64_t k0, uint64_t k1, uint64_t k2, uint64_t k3, uint64_t k4,
            uint64_t k5, uint64_t k6, uint64_t k7, uint64_t dlat,
            uint64_t dlon) {
  if (!cum_ready) return 0;
  if ((k0 | k1 | k2 | k3 | k4 | k5 | k6 | k7) >> 32) return 0;
  if (dlat > 180000000000ULL || dlon > 360000000000ULL) return 0;
  K___uint64_t_uint64_t_uint64_t_uint64_t a = Tessarium_Low_Core_core_encode(
      cum_lookup, k0, k1, k2, k3, k4, k5, k6, k7, dlat, dlon);
  out[0] = a.fst;
  out[1] = a.snd;
  out[2] = a.thd;
  out[3] = a.f3;
  return 1;
}

/* Returns 1 with the point in out[0..1], 0 for a rejected address, -1
   for an argument outside the domain (the caller's bug, distinct from a
   rejection on purpose). */
__attribute__((export_name("decode"))) int32_t
wasm_decode(uint64_t k0, uint64_t k1, uint64_t k2, uint64_t k3, uint64_t k4,
            uint64_t k5, uint64_t k6, uint64_t k7, uint64_t w1, uint64_t w2,
            uint64_t w3, uint64_t n) {
  if (!cum_ready) return -1;
  if ((k0 | k1 | k2 | k3 | k4 | k5 | k6 | k7) >> 32) return -1;
  if (w1 >= 2048 || w2 >= 2048 || w3 >= 2048 || n >= 10000) return -1;
  K___uint64_t_uint64_t_uint64_t d = Tessarium_Low_Core_core_decode(
      cum_lookup, k0, k1, k2, k3, k4, k5, k6, k7, w1, w2, w3, n);
  out[0] = d.snd;
  out[1] = d.thd;
  return d.fst == 1ULL ? 1 : 0;
}

/* (lat_lo, lat_hi, lon_lo, lon_hi) as offsets, in out[0..3]. */
__attribute__((export_name("bounds"))) int32_t wasm_bounds(uint64_t dlat,
                                                           uint64_t dlon) {
  if (!cum_ready) return 0;
  if (dlat > 180000000000ULL || dlon > 360000000000ULL) return 0;
  K___uint64_t_uint64_t_uint64_t_uint64_t b =
      Tessarium_Low_Core_core_bounds(cum_lookup, dlat, dlon);
  out[0] = b.fst;
  out[1] = b.snd;
  out[2] = b.thd;
  out[3] = b.f3;
  return 1;
}
