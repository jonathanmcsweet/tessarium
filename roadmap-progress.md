# Roadmap progress

Completed work only. Items move here from `roadmap.md` when done — they are
removed from the roadmap, not left checked off in both places.

These two files are the only work-tracking documents in the project.

## Entry format

```
### YYYY-MM-DD — Short title
**Phase:** N
**What:** One or two lines on what actually landed.
**Rationale:** Only if a decision was made or reversed. Otherwise omit.
**Follow-on:** Anything this created that now belongs in roadmap.md.
```

Keep entries short. The rationale field is the valuable part — it is where a
reversed decision gets explained, and it is the reason this file exists rather
than a git log.

---

### 2026-08-15 — Design settled, roadmap opened

**Phase:** 0

**What:** Core architecture agreed and recorded in `roadmap.md`. Address format
(3 BIP-39 words + 4-digit number, ~2.4 m resolution), integer banded grid,
scattered per-seed mapping via generalised Feistel, 24-word mnemonics, F\* core
extracting to OCaml now and C/WASM later, OCaml server.

**Rationale:** Three choices were live and are now closed.

- *Scattered over hierarchical.* Hierarchical gives truncatable precision and
  memorable neighbouring addresses, but a single leaked address exposes the
  entire enclosing 244 m block — all 10,000 squares. Scattered exposes one
  square. Since the product's premise is a private per-seed map, leak blast
  radius dominates the ergonomic win. Coarse precision becomes an explicit mode
  instead.
- *F\* over Rust+hax, Haskell, F#, Idris.* F\* extracts natively to OCaml, C and
  WASM, which covers server and clients from one proved source. Haskell's
  laziness is a liability in a crypto path and it has no F\* backend; F# is
  materially *less* strict than OCaml (no functors, .NET nulls); Rust+hax is the
  strongest alternative but the tooling is young.
- *OxCaml deferred.* Its unboxed types would fix real `int64` boxing in extracted
  code, but extracted code must not be hand-edited, the gain is invisible behind
  HTTP, and the extensions are explicitly experimental with no backwards-
  compatibility guarantee. Low\* → C is the better performance path and is a
  refactor within F\*, not a rewrite.

**Follow-on:** Phases 0–7 and open questions now in `roadmap.md`. The band table
design is the first real blocker — Phase 1 proofs cannot start without it.

---

### 2026-08-15 — Grid designed, reference implementation built and tested

**Phase:** 1–3 (design and reference), unblocking Phase 1 proofs

**What:** Band table solved and locked at 6,553,600 rows / 4096 bands. Python
reference implementation of grid, key derivation, FE1 Feistel and codec,
passing 30 property checks. 150 cross-platform test vectors committed. An
independent JavaScript implementation reproduces every vector and agrees with
the reference on 4,000 randomised cases. F\* interfaces and theorem statements
written for all three core modules. OCaml core interface and Dream server
written.

**Rationale:** Three corrections came out of actually building it.

- *Target resolution 2.4 m → 3 m.* The roadmap carried both "~2.4 m cells" and
  "~5.7 × 10¹³ cells needed, 0.66 of address space", which are inconsistent.
  2.44 m is the side length that consumes the address space exactly; at that
  size the grid needs 103% of the space and does not fit. 3 m fits at 65% fill
  and produces the 35% invalid share that gives free typo rejection. The two
  claims were never compatible and the 2.4 m figure was wrong.
- *Feistel halves rebalanced.* The recorded pair (a = 2¹⁹, b = 2¹⁸ × 625) is a
  250:1 split, which is badly unbalanced for a Feistel network. a = 2¹⁸ × 25
  and b = 2¹⁹ × 25 give the same exact product with a 2:1 ratio.
- *"Core must use unsigned 64-bit" was overstated.* The widest intermediate is
  4.80 × 10¹⁸, which fits signed int64 with 1.92× headroom. Unsigned is
  preferred for margin but is not forced.

**Bug found:** inverting the floor-bucket with a floor instead of a ceiling.
Cell `c` covers `[ceil(c·span/k), ceil((c+1)·span/k))`; using floor put each
cell's upper edge one nanodegree short, so points landing in that sliver tested
as outside their own cell. Surfaced as 15 containment failures in 200,000
samples and 6,144 band-seam collisions — both from the same root cause. This is
exactly the class of bug that motivated verification: no crash, no error, just
a wrong answer at cell boundaries. `theorem_containment` is now stated
separately in `Tessarium.Grid.fsti` because of it.

**Measured:** cells 3.054 m tall, 2.875–3.000 m wide (distortion 1.043); band
table 48 KB; 35.13% of addresses reject against 35.17% predicted; of 1,289
single-word typos that decoded at all, none landed within 100 km.

**Follow-on:** Phase 1 is unblocked — the band table question is closed. Phases
1–3 are now F\* implementation and proof against the written interfaces. Three
new open questions in `roadmap.md`: pole geometry, whether to take HMAC-SHA256
from HACL\*, and whether the JS implementation should survive the WASM port.

---

### 2026-08-15 — Scaffolding labelled and scheduled for removal

**Phase:** 0

**What:** `reference/` and `js/` marked as scaffolding in `README.md` and in a
new `reference/README.md`, with interim rules (no new features, not citable as
a specification, F\* wins any disagreement) and explicit removal criteria.
`design/grid_design.py` recorded as exempt and permanent.

**Rationale:** Both directories are hand-written reimplementations of the
algorithm, which is the exact failure mode the one-proved-source architecture
exists to prevent. They were built because no F\* toolchain was available
during design validation, and they earned that keep — three wrong design
numbers and the floor/ceiling bug came out of them — but the justification is
circumstantial and expires. The sharper issue, missed when they were written:
`vectors/vectors.json` is generated by `reference/gen_vectors.py`, so the
Python is currently the de facto source of truth for every implementation
checked against those vectors. That inverts the intended trust ordering.

**Follow-on:** Phase 4 gains two items — re-anchor the vectors to F\* (contents
must come out byte-identical) and delete `reference/`. The open question about
`js/` narrowed: it has a real argument for surviving, since an independently
written implementation checks the extracted one in a way a second extraction
target cannot. Decide at Phase 6.

---

### 2026-08-15 — Renamed to Tessarium; typo-scatter test corrected

**Phase:** 0

**What:** Project renamed from `w3wx` to `tessarium` across all four domain
separators, every module name, and the docs. Vectors regenerated. Both suites
re-run and a fresh 4,000-case Python/JS fuzz confirms cross-language agreement
under the new separators.

**Rationale:** `w3wx` was literally "w3w" + x, so the association the project
was trying to avoid was baked into its cryptographic domain separators.
Tessarium is crypto + tessera (a mosaic tile), sharing the `t`. Three earlier
candidates were rejected on collision: *tessera* (an existing npm tile server,
adjacent domain), *scytale* (at least eight crypto projects), *cryptile*
(`cryptiles` on npm has 219 dependents). Also considered and rejected:
seed-prefixed names, which read as Bitcoin wallet tooling and would encourage
exactly the seed reuse the README warns against.

Renaming was free today and permanently expensive later. Changing a domain
separator after launch invalidates every address anyone has written down.

**Bug found (in a test, not the design):** `test_typo_scatter` reported 2
near-hits against a threshold of 1. Investigation showed 12 of 13 apparent
near-hits were cases where the random replacement word happened to be the word
already there — leaving the address unchanged, so it "decoded" to distance
zero. Not typos. Genuine typos within 100km: 1, against 0.80 expected under
uniform scattering — exact agreement with the design. The test also used
Euclidean distance in degrees, which is not distance. Now excludes same-word
replacements, uses haversine, and bounds against a Poisson expectation rather
than a magic number. Second check added asserting the map is not hierarchical,
which is the failure the test actually guards against.

**Follow-on:** none. Rename complete, no references remain.

---

### 2026-08-15 — Application architecture settled; repo under version control

**Phase:** 0

**What:** The project gained a target beyond the core: a working app on Linux
desktop and the web, where a 24-word phrase is entered, the map is generated
under it, and clicking a tile yields that tile's address. Settled the delivery
path, the UI stack, the round-function source, the privacy posture, the basemap
and the desktop shape; all now in `roadmap.md` under *Locked decisions*. Phases
5–7 rewritten around them, Android split out as Phase 9. `git init` and a
baseline commit — the repository had never been under version control.

**Rationale:** Six decisions, five of which reverse or narrow something the
roadmap previously left open.

- *`js_of_ocaml` instead of Low\* → C → WASM for the browser.* The original
  plan reached clients through a second extraction target, which made a working
  UI wait on the whole Low\* retarget. `js_of_ocaml` compiles the OCaml already
  being extracted, so the browser and the server run one extraction rather than
  two, with no C toolchain and no KaRaMeL in the critical path. Low\* survives
  in Phase 8 as an optimisation.
- *Round function from `digestif`'s pure-OCaml backend, not HACL\*.* HACL\* is
  verified and was the presumed answer, but it reaches OCaml through C stubs,
  and C stubs do not cross into `js_of_ocaml`. Taking it would have forced a
  separate browser-side crypto implementation — a second hand-written copy, the
  precise failure mode this architecture exists to prevent. `digestif`'s pure
  backend compiles unchanged in both targets, so there is exactly one. The
  interface already anticipated this: `round_fn` is a parameter and bijectivity
  never depended on it.
- *Eio + cohttp-eio, not Dream.* The roadmap carried "Eio or Dream" unresolved.
  This server serves static assets, three JSON routes and PMTiles range
  requests; Dream is at `1.0.0~alpha8`, is Lwt-based, and pulls OpenSSL
  bindings, GraphQL, an HTML parser and a Markdown parser along with it, while
  still leaving range support to be hand-rolled. Eio is direct-style, actively
  maintained and effects-native.
- *OCaml 5.4, not 4.14.* 4.14 was briefly chosen out of caution about Dream's
  OCaml 5 support. That caution was unfounded — Dream declares `ocaml >= 4.08`
  with no upper bound — and the pin was actively harmful: `zarith_stubs_js`
  v0.17.0, which is what makes extracted `Prims.int` arithmetic work in a
  browser, requires `ocaml >= 5.1.0`. Checking the constraint rather than
  assuming it reversed the decision.
- *Vector basemap, not raster.* Offline was a hard requirement, and raster
  cannot meet it at this resolution: planet coverage to z19 is hundreds of
  billions of tiles, and z19 is only 0.30 m/px, which puts a 3 m cell at ten
  pixels with nothing but blur beyond. Vector tiles to z15 cover the planet in
  roughly 100 GB and render crisply at z22. PMTiles also collapses hosting to a
  single file behind HTTP range requests, so desktop-offline and self-hosted
  become one code path.
- *Plain DOM UI, not React Native.* Expo can build web, so the question was not
  capability but commitment: Capacitor wraps a finished web build and can be
  added years later, whereas Expo is a foundational choice that cannot be
  retrofitted onto a DOM app. With Android deferred, the cheapest way to keep it
  open is to not choose a mobile framework at all. React Native would also have
  put `react-native-web` between the app and a DOM/WebGL map library, and made
  awkward the Web Worker that PBKDF2 needs.

Settled two of the roadmap's open questions outright — the round-function source,
and whether the server must exist (it does, as static host, tile server and
desktop shell, but no UI path depends on its encode/decode API; keys are derived
client-side and never transmitted).

**Follow-on:** Phase 0 reduces to toolchain pinning and CI. Phases 5–7 replace
the old Phase 5–6. Android is Phase 9. Two new open questions: whether `js/`
survives now that it is the only independent check on the extracted core, and
who hosts the basemap extracts the in-app downloader will fetch.

---

### 2026-08-15 — First verified module; band table memory limits measured

**Phase:** 1

**What:** `Tessarium.Spec.fst` verifies — all conditions discharged, 0.4 s,
no admits. That covers `lemma_factors`, `lemma_bucket_range`,
`lemma_bucket_monotone`, `lemma_edge_inverse` and `lemma_midpoint_interior`,
plus three new division lemmas (`lemma_div_char`, `lemma_div_le_iff`,
`lemma_ceil_le`) that the rest of the development rests on. `lemma_edge_inverse`
is the one corresponding to the floor/ceiling bug the reference implementation
shipped first time round. F\* toolchain (2026.08.09, Z3 4.13.3) running from a
binary release in `$HOME`, needing no root.

**Rationale:** Two corrections came out of running the prover rather than
reasoning about it.

- *`FStar.Mul` no longer exists.* All four `fstar/*.fsti` files open it, and all
  four would fail on the first line. It was removed from ulib; `*` on integers
  now needs no import. The interfaces were written against an older F\* and had
  never been run.
- *F\* rejects `_` digit separators.* Every geodetic constant used them.

Both are the same class of problem: the F\* in this repository had never been
near a compiler, so nothing about it could be assumed.

**Measured (2 GB RAM, no swap):** F\* memory against band-table size is sharply
super-linear — 256 entries 115 MB, 512 → 166 MB, 1024 → 274 MB, 2048 → 640 MB,
and 4096 is killed by the OOM killer above 1 GB. Splitting the same 4096 entries
into 16 chunks of 256 costs 207 MB and succeeds, a 5× reduction. Sixteen
per-chunk `assert_norm` obligations verify in 241 MB / 2.1 s, and F\*'s
normaliser independently computed the grand total as 55,692,067,744,000,
matching the committed table. But any *single* obligation touching the whole
table exceeds 2 GB, including `FStar.ImmutableArray` variants, because the
array is rebuilt per obligation rather than shared.

**Re-measured at 16 GB.** The memory ceiling was real but was masking the
actual constraint. With headroom, the flat 4096-entry literal elaborates in
1.4 GB / 7.6 s and the generated `Tessarium.BandTable.fst` in 1.9 GB / 9.5 s,
so raw size was never the problem. Two sharper findings replace it:

- *Z3 encoding size is the binding constraint.* A module that defines the
  literals drags them into every SMT query it contains. A trivial index-bound
  check — `b + 1 < length arr` under `b < bands - 1` — fails at 4096 entries
  after 35 s, and the byte-identical code over 4 entries verifies in 0.2 s. The
  fix is `[@@"opaque_to_smt"]`, which removes a definition from the SMT encoding
  while leaving it reducible by the normaliser. Confirmed: chunked lists with
  the attribute verify in 271 MB / 2.07 s.
- *Lists normalise; arrays do not.* The same well-formedness scan takes 2.1 s
  over chunked lists and does not terminate within 10 minutes via
  `FStar.ImmutableArray` lookups. `ImmutableArray` earns its place only as the
  extraction-time O(1) runtime representation, never as the proof vehicle.

A third, smaller trap: an SMT pattern on a closed term (`[SMTPat (length arr)]`
on a unit lemma) contains no bound variable, so Z3 discards it silently and F\*
only warns. Length facts belong in the array's refinement type instead.

**Rationale:** the governing rule is that each proof obligation must touch a
small term — chunking the data is not enough on its own. That pushes the grid
theorems behind an abstract `Tessarium.Table.fsti` carrying only
well-formedness, so injectivity, containment and round-trip never see a literal,
and the concrete table's cost is isolated to one module. That is better
structure independently of the prover's limits, and the existing
`Tessarium.Grid.fsti` already declares the table abstractly, so it matches the
original intent.

**Follow-on:** Phase 1 gains the interface split and a chunked re-emit of the
band table; the current emitter produces one flat literal, which now elaborates
but poisons every SMT query in its module.

---

### 2026-08-17 — Band table verified; toolchain pinned

**Phase:** 0–1

**What:** `Tessarium.Scan` and `Tessarium.Table.Data` both verify with no
admits, in 4.7 s and 304 MB. The band table is now a proved artifact rather than
an assumption: adjacent-difference bounds, length, and the 55,692,067,744,000
grand total all discharged against the committed `bands.json`. Toolchain
complete and pinned — F\* 2026.08.09 with Z3 4.13.3 from a binary release in
`$HOME`, OCaml 5.3.0 via an opam switch, Node 24.19.0 via nvm with a `.nvmrc`.

**Rationale:** three changes, each forced by measurement rather than taste.

- *The table stores cumulative column counts, not the two tables the grid
  consumes.* `offsets[b]` is `cum[b] * rows_per_band` and `col_counts[b]` is
  `cum[b+1] - cum[b]`, so band-offset contiguity — previously a lemma requiring
  a two-list relational scan — becomes true by definition and needs no proof at
  all. One predicate is left over the data, that adjacent differences lie in
  (0, max], and it yields positive column counts and the per-band width bound
  together. The stored values also shrink from 14 digits to 11, and one table
  replaces two.
- *Chunked, with the literals opaque to SMT.* Measured on the same table: one
  whole-table obligation costs 56 s and 6.6 GB; seventeen per-chunk obligations
  folded by data-free lemmas cost 4.7 s and 304 MB. 12x faster, 22x leaner, and
  well inside what a CI runner can be trusted with.
- *`lemma_total` folds `last` across chunks rather than indexing.* Reaching the
  final element with `assert_norm` on `L.index` walks all 4097 cells and cost
  22 s / 4.3 GB on its own. `lemma_unsnoc_is_last` plus `lemma_append_last`
  across the chunk seams leaves one small per-chunk normalisation.

*OCaml 5.3.0, not 5.4.1 as previously recorded.* The F\* distribution ships its
ulib OCaml support library as precompiled `.cmi`/`.cmx` — 129 objects with only
97 `.ml` sources, so roughly a third cannot be rebuilt. OCaml objects are not
portable across compiler versions, so extraction must link against the compiler
F\* itself was built with. Every other constraint still clears: `eio` needs
>= 5.2.0, `zarith_stubs_js` needs >= 5.1.0.

*Node 24, not 22.* 22 entered Maintenance on 2025-10-21; 24 has been Active LTS
since 2025-10-28. Managed by nvm rather than a system package so the version is
per-project and needs no root.

**Follow-on:** `Tessarium.Grid.fsti` needs rewriting — it predates the
cumulative encoding, declaring `col_counts` and `offsets` as separate abstract
tables with contiguity as a lemma, and it opens the removed `FStar.Mul`.
