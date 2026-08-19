# Machine-integer bounds for the Low*/KaRaMeL port

The port replaces unlimited-precision naturals (zarith, after extraction)
with `uint64_t`. That is sound only if no intermediate value can reach
2^64, and F* will demand a proof at every operation -- this document is
the advance survey of those proofs, worked from the shipped constants.
The verdict: **the entire core fits unsigned 64-bit arithmetic.** No
128-bit arithmetic is needed anywhere, including the HMAC reduction.

## Constants (from Tessarium.Spec and Tessarium.Table.Data)

| constant        | value              | bits    |
|-----------------|--------------------|---------|
| addr_space      | 85,899,345,920,000 | < 2^47  |
| fe_a            | 6,553,600          | < 2^23  |
| fe_b            | 13,107,200         | < 2^24  |
| rows            | 6,553,600          | < 2^23  |
| rows_per_band   | 1,600              | < 2^11  |
| bands           | 4,096              | = 2^12  |
| total_cells     | 55,692,067,744,000 | < 2^46  |
| max_col_count   | 13,343,409         | < 2^24  |
| cum[bands]      | 34,807,542,340     | < 2^36  |
| lat_span        | 180,000,000,000    | < 2^38  |
| lon_span        | 360,000,000,000    | < 2^39  |

## Feistel -- PORTED AND PROVED (Tessarium.Low.Feistel)

Halves stay under fe_b < 2^24 (the loop invariant); `l + fr` < 2^25;
`join` peaks at `(fe_a-1)*fe_b + (fe_b-1)` < addr_space < 2^47. The test
round function adds `x*31` (< 2^29), `i*1000003` (< 2^24) and `k + t`
(< 2^33 under the key64 bound). Every claim here is now a discharged
refinement, not an estimate.

## Real round function (HMAC-SHA256, later phase)

ocaml/lib/crypto.ml takes 128 bits of HMAC output and reduces mod m,
where m is fe_a or fe_b -- always < 2^24. Splitting the 128 bits as
`h = hi*2^64 + lo`:

    h mod m = ((hi mod m) * (2^64 mod m) + lo mod m) mod m

`hi mod m` and `2^64 mod m` are each < 2^24, so their product is < 2^48;
adding `lo mod m` stays < 2^49. And since m only ever takes two values,
`2^64 mod fe_a` and `2^64 mod fe_b` are compile-time constants pinned by
assert_norm. **No 128-bit division, no 128-bit type** -- plain U64 on the
two halves.

## Grid -- PORTED AND PROVED (Tessarium.Low.Grid)

Every bound below is now a discharged refinement. Coordinates cross the C
boundary as unsigned offsets from the domain corner (the spec subtracts
the corner first anyway; signed machine ints would drag in library
internals the zero-admit flag rejects). The band table crosses as a
function parameter (`cum_low`) whose result refinement pins it to T.cum --
the round-function pattern again -- so every grid theorem holds for any
conforming lookup. The unproved plumbing on this path, all of it: the C
lookup and harness lines, gen_check's emission of the table and vectors
(including the signed-to-offset shift), krml and the C compiler. What
watches each: gen_check re-parses every literal it writes and compares it
against memory (the emission); the harness sweeps the whole table's shape
-- base 0, strictly increasing, steps <= max_col_count, the hand-pinned
grand total -- and replays 13 vectors that read ~2% of the entries
directly (the values Check.Table pins are Expected.fst's copy of the same
list, a DIFFERENT serialization from cum_table's); CI's byte diff pins
stability. band_search extracts as genuine C recursion, depth <= 12 --
measured, closing the spike's emission-shape obligation for this walk. A
proved in-memory table (LowStar buffer) remains the recorded upgrade
path.

`bucket(v, v_min, span, k) = (v - v_min) * k / span`, always with
`0 <= v - v_min <= span`:

- latitude: d <= lat_span, k = rows       -> d*k <= 1.18e18 < 2^61
- longitude: d <= lon_span, k <= max_col_count -> d*k <= 4.81e18 < 2^63
- `edge`: called with i up to AND INCLUDING k (`cell_bounds` asks for
  `edge (c+1)`, and `lemma_edge_inverse` evaluates `edge (i+1)` at
  i+1 = k), so the numerator peaks at k*span + k - 1 ~ 4.80e18 < 2^63.
  A port typing edge's index as i < k would fail at cell_bounds.
- cell midpoint: `(2i+1) * span` <= 9.61e18 -- **the tightest spot in
  the core**: above 2^63 (9.22e18) but under 2^64 (1.84e19) with a 1.92x
  margin. Must be computed UNSIGNED; a signed 64-bit port would overflow
  here and nowhere else.

Coordinates arrive signed (nanodegrees, |v| <= 1.8e11 < 2^38): subtract
v_min first (non-negative by the domain refinement), then everything is
unsigned. Table arithmetic peaks at `offsets(b) + row_in_band*cols + col`
< total_cells < 2^46. Codec divisions are by the constants 2048 and
10,000 on values < 2^47. All comfortably clear.

## What the spike established about the toolchain

- krml ships with the F* release and works; its prebuilt runtime archive
  does not, so the harness compiles the emitted C directly (it needs
  headers only).
- Codegen must be narrowed to our namespace (`--extract '-* +Tessarium.Low'`):
  elaborating ulib's machine-int internals trips `--report_assumes error`
  on upstream's own admits.
- A value-dependent type abbreviation (`round_low rf_ghost`) as a
  DECLARED type makes KaRaMeL silently drop the definition and then fail
  the build for the missing symbol; explicit binders with the same
  refinements extract cleanly.
- The spec round function travels as a `G.erased` ghost index; the
  machine round function's result refinement carries the agreement proof
  call by call. This is the pattern the HMAC phase will reuse.
- krml emits the loops as genuine C recursion through a function pointer
  (no specialization, no guaranteed tail call). Depth 16 here is
  harmless; the table phases must re-check the emission shape before
  walking 4,097 entries this way. This survey covers arithmetic width,
  never stack.
- Refinements erase at the C boundary: the emitted signatures are plain
  uint64_t, so C callers outside the proved envelope (keys < 2^32,
  inputs < addr_space) are unchecked by anything. The harness keys are
  <= 195.
