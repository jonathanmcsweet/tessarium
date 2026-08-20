/* OCaml FFI over the KaRaMeL-emitted verified core (vendor/).

   The unproved plumbing on this path, all of it here: the band-table
   copy at init, the little-endian key packing, and the value conversions.
   Each is watched by the side-by-side wall (ocaml/test/test_c_core.ml),
   which drives every entry point against the extracted-OCaml core with
   digestif injected, over corners and generated corpora.

   The emitted C's refinements are erased (BOUNDS.md: callers outside
   the proved envelope are unchecked by anything), so every argument is
   checked HERE before the proved code runs -- scalar ranges below, and
   the band table's whole shape at init. */

#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <stdint.h>

#include "Tessarium_Low_Core.h"

#define CUM_ENTRIES 4097
#define LAT_SPAN 180000000000ULL
#define LON_SPAN 360000000000ULL
#define WORDS 2048ULL
#define NUM_MAX 10000ULL

static uint64_t cum_table[CUM_ENTRIES];
static int cum_ready = 0;

static uint64_t cum_lookup(uint64_t b) { return cum_table[b]; }

/* The proved code's erased precondition on the table is cum_low: the
   lookup answers exactly T.cum. What a wrong table costs is not a wrong
   answer but undefined behaviour (a flat band makes col_counts 0 and the
   grid divides by it), so init enforces the same shape the C harness
   pins: base 0, strictly increasing, steps within max_col_count, the
   proved grand total at the top. A table that passes this and still
   differs from T.cum is caught by the side-by-side wall, value by
   value. */
value caml_ccore_init(value vtable) {
  CAMLparam1(vtable);
  if (Wosize_val(vtable) != CUM_ENTRIES)
    caml_invalid_argument("c_core: the band table must have 4097 entries");
  for (int i = 0; i < CUM_ENTRIES; i++) {
    intnat e = Long_val(Field(vtable, i));
    if (e < 0) caml_invalid_argument("c_core: negative band table entry");
    cum_table[i] = (uint64_t)e;
  }
  if (cum_table[0] != 0ULL)
    caml_invalid_argument("c_core: band table must start at 0");
  if (cum_table[CUM_ENTRIES - 1] != 34807542340ULL)
    caml_invalid_argument("c_core: band table grand total is wrong");
  for (int i = 0; i < CUM_ENTRIES - 1; i++)
    if (cum_table[i] >= cum_table[i + 1] ||
        cum_table[i + 1] - cum_table[i] > 13343409ULL)
      caml_invalid_argument("c_core: band table is not a cumulative column table");
  cum_ready = 1;
  CAMLreturn(Val_unit);
}

static void key_words(value vkey, uint64_t kw[8]) {
  if (!cum_ready) caml_failwith("c_core: not initialised");
  if (caml_string_length(vkey) != 32)
    caml_invalid_argument("c_core: the key must be exactly 32 bytes");
  const unsigned char *k = (const unsigned char *)String_val(vkey);
  /* BLAKE2s's own byte order: eight LITTLE-endian words. */
  for (int i = 0; i < 8; i++)
    kw[i] = (uint64_t)k[4 * i] | ((uint64_t)k[4 * i + 1] << 8) |
            ((uint64_t)k[4 * i + 2] << 16) | ((uint64_t)k[4 * i + 3] << 24);
}

static uint64_t offset_arg(value v, uint64_t span, const char *what) {
  intnat d = Long_val(v);
  if (d < 0 || (uint64_t)d > span) caml_invalid_argument(what);
  return (uint64_t)d;
}

value caml_ccore_encode(value vkey, value vdlat, value vdlon) {
  CAMLparam3(vkey, vdlat, vdlon);
  CAMLlocal1(res);
  uint64_t kw[8];
  key_words(vkey, kw);
  uint64_t dlat = offset_arg(vdlat, LAT_SPAN, "c_core: latitude offset");
  uint64_t dlon = offset_arg(vdlon, LON_SPAN, "c_core: longitude offset");
  K___uint64_t_uint64_t_uint64_t_uint64_t a = Tessarium_Low_Core_core_encode(
      cum_lookup, kw[0], kw[1], kw[2], kw[3], kw[4], kw[5], kw[6], kw[7],
      dlat, dlon);
  res = caml_alloc_tuple(4);
  Store_field(res, 0, Val_long((intnat)a.fst));
  Store_field(res, 1, Val_long((intnat)a.snd));
  Store_field(res, 2, Val_long((intnat)a.thd));
  Store_field(res, 3, Val_long((intnat)a.f3));
  CAMLreturn(res);
}

value caml_ccore_decode(value vkey, value vw1, value vw2, value vw3, value vn) {
  CAMLparam5(vkey, vw1, vw2, vw3, vn);
  CAMLlocal1(res);
  uint64_t kw[8];
  key_words(vkey, kw);
  uint64_t w1 = offset_arg(vw1, WORDS - 1, "c_core: word index");
  uint64_t w2 = offset_arg(vw2, WORDS - 1, "c_core: word index");
  uint64_t w3 = offset_arg(vw3, WORDS - 1, "c_core: word index");
  uint64_t n = offset_arg(vn, NUM_MAX - 1, "c_core: number");
  K___uint64_t_uint64_t_uint64_t d = Tessarium_Low_Core_core_decode(
      cum_lookup, kw[0], kw[1], kw[2], kw[3], kw[4], kw[5], kw[6], kw[7],
      w1, w2, w3, n);
  res = caml_alloc_tuple(3);
  Store_field(res, 0, Val_long((intnat)d.fst));
  Store_field(res, 1, Val_long((intnat)d.snd));
  Store_field(res, 2, Val_long((intnat)d.thd));
  CAMLreturn(res);
}

value caml_ccore_bounds(value vdlat, value vdlon) {
  CAMLparam2(vdlat, vdlon);
  CAMLlocal1(res);
  if (!cum_ready) caml_failwith("c_core: not initialised");
  uint64_t dlat = offset_arg(vdlat, LAT_SPAN, "c_core: latitude offset");
  uint64_t dlon = offset_arg(vdlon, LON_SPAN, "c_core: longitude offset");
  K___uint64_t_uint64_t_uint64_t_uint64_t b =
      Tessarium_Low_Core_core_bounds(cum_lookup, dlat, dlon);
  res = caml_alloc_tuple(4);
  Store_field(res, 0, Val_long((intnat)b.fst));
  Store_field(res, 1, Val_long((intnat)b.snd));
  Store_field(res, 2, Val_long((intnat)b.thd));
  Store_field(res, 3, Val_long((intnat)b.f3));
  CAMLreturn(res);
}
