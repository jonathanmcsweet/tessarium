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

*OCaml 5.3.0, not 5.4.1 as previously recorded — by convenience, not by
constraint.* The F\* distribution ships its ulib support library as precompiled
`.cmi`/`.cmx`, and OCaml has no stable ABI: objects carry a version magic number
and cross-module inlining details, so they cannot be linked by a different
compiler. Matching 5.3.0, the compiler F\* itself was built with, lets
extraction link those objects directly with no rebuild step.

It is not a hard pin. The distribution also ships complete sources — 129
compiled units against 129 `.ml` files, none missing — so any OCaml version F\*
supports is available at the cost of rebuilding the support library. An earlier
draft of this entry claimed a third of the units had no source and that the pin
was forced; that was a miscount. `lib/ulib.ml` is a *directory*, and `ls *.ml`
listed its contents rather than matching files, which made the sources look both
fewer and misplaced. Every other constraint clears regardless: `eio` needs
>= 5.2.0, `zarith_stubs_js` needs >= 5.1.0.

*Node 24, not 22.* 22 entered Maintenance on 2025-10-21; 24 has been Active LTS
since 2025-10-28. Managed by nvm rather than a system package so the version is
per-project and needs no root.

**Follow-on:** `Tessarium.Grid.fsti` needs rewriting — it predates the
cumulative encoding, declaring `col_counts` and `offsets` as separate abstract
tables with contiguity as a lemma, and it opens the removed `FStar.Mul`.

---

### 2026-08-17 — Core verifies, extracts, and runs in both targets

**Phase:** 1–5

**What:** The whole core is through `fstar.exe` with no admits —
`Tessarium.Table`, `.Grid`, `.Feistel`, `.Codec` and `.Api` join `.Spec`,
`.Scan` and `.Table.Data`. It extracts to OCaml, and the extracted OCaml
reproduces all 199 committed vector checks natively. The *same* extraction,
compiled by `js_of_ocaml`, reproduces 46 vector checks under Node in 0.84 s —
so the browser and the server demonstrably run one implementation.

What the refinement types buy, stated precisely: `point_to_cell` returns a
value provably below `total_cells`, `band_search` provably returns the unique
band containing a row, `cell_to_point` provably returns coordinates in range,
and `theorem_no_overflow` discharges the 1.92x int64 headroom. These are
type-level guarantees, discharged at verification time. The three grid
*theorems* — containment, injectivity across band seams, round-trip — are still
unwritten, and remain in `roadmap.md`.

**Rationale:** five findings, each from running the pipeline rather than
reasoning about it.

- *`--extract` silently skipped the band table.* F\* walks what it calls a
  "possibly-partial dependency graph": a module that has an interface is loaded
  from that interface alone, so its implementation is never elaborated and does
  not come out. `Tessarium.Table.Data` is exactly that shape and is the module
  holding the table. The build now invokes `--extract_module` once per module.
  A whole-program flag that silently emits *less* than asked is worth
  remembering.
- *F\*'s shipped `.cmi` files read as corrupt against an identical compiler.*
  Same OCaml 5.3.0, same magic `Caml1999I035`, still rejected. OCaml 5.3
  compresses `.cmi` with zstd when the compiler has it; F\*'s build did and ours
  did not. `make -C fstar fstarlib` now vendors the eight support modules from
  the shipped *sources* and builds them with our switch, which sidesteps the
  question rather than chasing the flag.
- *`js_of_ocaml` compiles OCaml's `int` to 32 bits.* Longitude reaches
  1.8 x 10¹¹ nanodegrees, so this is not a corner case, and it produced three
  separate failures: the four bound constants silently truncated
  (`-90000000000` became `194313216`), a module-level `Z.to_int total_cells`
  raised `Z.Overflow` at load, and every exact value crossing the JS boundary
  would have wrapped. Bounds are `Z.of_string`, and nanodegrees cross as decimal
  strings. The degree helpers convert at the edge, which is the one place the
  no-floating-point rule permits it.
- *`batteries` drags OCaml threads into the bundle.* F\*'s support modules use a
  sliver of it; `js_of_ocaml` has no `caml_thread_initialize`, so the bundle
  loaded and immediately died. A twelve-line `BatList` shim replaces it, and the
  bundle fell from 5.8 MB to 4.4 MB.
- *`Prims.int` is `Z.t`, and that is the right default.* Extracted arithmetic is
  Zarith throughout rather than native int. Slower than necessary — the values
  all fit in 63 bits — but it is what makes the same extraction correct in a
  32-bit JS runtime, and correctness before speed here is not a close call. If a
  profiler ever objects, the answer is Low\* -> C (Phase 8), not hand-editing
  extracted code.

**Measured:** full verification 12 s; extraction 8 modules; native vectors 199
checks / 0 failures; JS bundle 4.4 MB, 46 checks / 0 failures / 0.84 s.

**Follow-on:** the three grid theorems and the Feistel/codec round-trip
theorems stay open in Phases 1–3, now against implementations that exist rather
than against interfaces. CI is the gating item: until it runs, no verification
claim in the README is reproducible by anyone else.

---

### 2026-08-17 — Working map prototype: server, UI, offline basemap, CI

**Phase:** 0, 5–6

**What:** The thing the project set out to build works. Enter a 24-word
phrase, the map opens under it, click a square and get its address, paste an
address and fly back to that square. Four pieces landed:

- **Eio + cohttp-eio server.** Static assets, health, PMTiles over byte
  ranges, and an encode/decode API that is off by default. Routing, path
  safety and range parsing are pure and separately tested.
- **Vite + React + MapLibre GL UI**, with the verified core in a Web Worker
  that owns the derived key. The grid overlay is drawn from a new
  `cells_in_bounds` in the core.
- **PMTiles reader and region extractor in OCaml** — the offline basemap.
- **CI**, verifying from a pinned F\* release and re-extracting on every push.

**Rationale:** four decisions, three of them forced by something breaking.

- *PMTiles in OCaml rather than the Go `pmtiles` tool.* Raised by the user as
  a preference and it turned out to be the load-bearing choice: the desktop
  target is meant to be one static binary, and the Phase 6 region downloader
  has to run *inside* it. Shelling out to a Go binary would have made Go a
  runtime dependency of the shipped app in all but name. Serving tiles never
  needed it — that is plain range requests over an opaque file — so the Go
  tool was only ever doing the one job the app itself must do.
- *The key lives in the worker and there is no way to read it back.* The main
  thread sends coordinates and receives addresses. This started as a way to
  keep PBKDF2 off the render thread and became a real boundary: the main
  thread has the DOM, which is where an injected script would be looking. The
  browser test asserts a second worker in the same page has no key.
- *Content-Security-Policy defaults to `connect-src 'self'`.* A seed phrase is
  typed into this page, so the question is not whether the code is trustworthy
  but whether a compromised dependency would have anywhere to send it. With no
  remote origin permitted, it does not. Widening it takes a flag, which is why
  the basemap had to be served locally rather than from a CDN.
- *The access log is a closed variant of route shapes, not a format string.*
  There is no free-form field, so there is nowhere for a phrase, key or
  address to be interpolated even by accident, and query strings are dropped
  before logging. Structural rather than disciplinary.

**Bugs found, each by a test that existed to find it:**

- *Worker errors were resolved as successes.* Operational failures came back
  nested inside `result`, and the client only rejected on a top-level `error`.
  So an address decoding to nothing — about 35% of them, by design — reported
  success, and the map flew to `NaN`. The valid path worked perfectly, which
  is exactly why this survived until a test looked up a deliberately invalid
  address. Refusals now throw.
- *A relative PMTiles offset used as an absolute one.* Directory entries store
  offsets relative to the data section. The extractor added nothing, so it
  copied tile bytes out of the root directory. The output had a correct
  header, correct tile count, correct bounds, and every tile was garbage — no
  error anywhere, just a map that renders blank. Caught by reading the output
  back with the reference JavaScript implementation.
- *An `assert` that was a bad test, not a bad implementation.* A lookup of
  `pig.night.notaword.7473` was expected to name the unknown word; it decoded
  instead, because four-letter prefix matching resolved `nota` to `notable`.
  The feature working as designed.

**Measured:** 349 checks across five suites — 199 native vectors, 55 in the JS
bundle, 57 server, 38 PMTiles, 17 in headless Chromium. Extraction is
byte-identical on re-run. A 0.25° × 0.10° London extract at zoom 15 is 31 MB
of tiles out of a 128 GB planet build, plus 15 MB of glyphs.

**Follow-on:** Phase 5 narrows to session expiry and rate-limiting the one
endpoint that runs PBKDF2. Phase 6 keeps the in-app region downloader, label
placement above zoom 20.5, and keyboard access. Phase 7's "single binary" is
not yet true — assets are read from `ui/dist` at runtime. The basemap
distribution question narrowed: no one needs to host extracts, but
`demo-bucket.protomaps.com` is a demo bucket with no availability promise.

---

### 2026-08-17 — Every theorem proved

**Phase:** 1–3

**What:** The theorem set is complete, with no admits.
`Grid.theorem_containment`, `theorem_injective` and `theorem_roundtrip`;
`Feistel.theorem_roundtrip`, `theorem_injective`, `theorem_surjective`;
`Codec.theorem_roundtrip` both directions and `theorem_injective`; and
`Api.theorem_end_to_end`, which composes all three layers into the property a
user would state — decoding an encoded point names that point's own square.

**Rationale:** three things worth keeping.

- *Band-seam injectivity reduces to one lemma.* `lemma_band_unique`: offsets is
  strictly increasing, so the half-open interval each band owns is disjoint
  from every other's, and no two bands can claim an index. The seam question
  the design worried about for months is four lines once the table stores
  cumulative counts, which is a return on that encoding decision rather than a
  coincidence.
- *The Feistel induction needed no second loop.* The obvious approach — a
  decryption loop with an adjustable endpoint, so both directions range over
  the same segment — would have added a function to the extracted surface for
  the sake of a proof. Stating it as *decryption from the last round collapses
  onto decryption from round i* avoids that entirely, and at i = 0 it is
  exactly the round trip, since `dec_loop` at 0 is the identity.
- *Zero admits is enforced by F\*, not by a grep.* `--report_assumes error`
  makes every escape hatch an error. The grep that preceded it was wrong twice:
  it fired on the word "assume" in a prose comment, and it would have missed a
  hatch reached through an abbreviation.

**Checked non-vacuous.** Every theorem was re-run against a deliberately false
variant, and each was rejected: a point falling below its own cell, a round
trip landing on `index + 1`, injectivity concluding two equal indices came from
different rows, end-to-end decoding to `None`. The sharpest control was setting
`rounds` to 9 — the parity invariant breaks, exactly as the design's
"must be even" note says it should, which shows the proof depends on the
round count rather than merely tolerating it.

**Dropped:** a `theorem_encode_total` that verified but asserted nothing — its
second disjunct held by the return type. A theorem that looks meaningful and
is not is worse than an absent one, because it reads as coverage.

**Follow-on:** two narrower gaps in Phases 1–3. Nothing proves the extracted
OCaml matches the F\* it came from — the extraction pipeline is trusted, and
199 vectors are all that bridge it. And `theorem_containment` carries
`requires lat < lat_min + lat_span`, because exactly +90° is clamped rather
than bucketed; `lemma_pole_clamp` covers the pole separately.

---

### 2026-08-17 — Vectors re-anchored to F\*; Python reference deleted

**Phase:** 4

**What:** `vectors/vectors.json` is now generated by the verified core, and
`reference/` is gone. The trust ordering the architecture exists to establish
finally holds: nothing in the tree computes an answer that the F\* is then
checked against.

**Rationale:** three decisions.

- *Split the questions from the answers.* `vectors/inputs.json` holds the
  points, mnemonics and Feistel inputs and is committed;
  `ocaml/tools/gen_vectors.ml` computes the outputs. The alternative —
  regenerating inputs too — would have meant reproducing Python's Mersenne
  Twister in OCaml to keep the same 47 points, which is absurd work for no
  gain. Which points to test is arbitrary; what the answers are is the thing
  under test. `--check` runs in CI, so the core drifting from its own committed
  answers is a build failure rather than a silent regeneration.
- *The regenerated file was semantically identical to the Python's*, which was
  the stated precondition for deletion and the reason for doing it in that
  order. Verified three ways afterwards: the OCaml `--check`, all five other
  suites, and the Python itself before it was removed.
- *`js/` stays, and the open question is closed.* With `reference/` gone it is
  the only thing in the tree that could catch a bug in the F\* extraction by
  disagreeing with it — the pipeline is trusted, not verified, and an
  independently written implementation checks something no second extraction
  target can. It is now wired into `dune test` (150 checks) rather than run by
  hand, which converts it from a copy that might drift into a live oracle.

**Found on the way:** `ocaml/lib/wordlist.ml` carried a "GENERATED — do not
edit" header with nothing in the tree able to generate it, and its only source
was the file about to be deleted. That is hand-written code wearing a
misleading comment. The BIP-39 list moved to `wordlist/english.txt` with its
canonical checksum recorded, and the module is now produced by a dune rule and
not committed at all, so it cannot drift. The generator refuses a list that is
not exactly 2048 words — a short one would build cleanly and produce wrong
addresses, since the codec's radix depends on the count.

**Measured:** six suites under one `dune test` — 199 native, 150 independent
JS, 55 js_of_ocaml, 57 server, 38 PMTiles, plus the vector regeneration check.

**Follow-on:** Phase 4 keeps the benchmark and a large randomised differential
sweep; the 47 committed points are a floor, and the extraction is the trusted
part worth stressing.

---

### 2026-08-17 — Differential sweep against the extraction; encode benchmarked

**Phase:** 4

**What:** The extracted core and the independently written JavaScript
implementation agree on **512,298 points, with zero disagreements** —
`point_to_cell`, `cell_to_point`, `encode`, and `decode` landing in the same
square. A 14,298-point version runs in CI.

**Rationale:** the corpus is deliberately unbalanced. Uniformly random points
essentially never land on a band seam — there are 4096 of them across
1.8 × 10¹¹ nanodegrees — and seams are exactly where two bands could both claim
a point or leave a gap. So the generator straddles every seam explicitly, three
points each, giving 12,287 seam points in every run including the small CI one.
That is the case `theorem_injective` rules out in the F\*, and the case where a
bug introduced *by extraction* would be least visible.

This matters because the extraction pipeline is trusted rather than verified.
The F\* is proved and nothing proves the OCaml that came out of it says the
same thing. An independently written implementation disagreeing is the only
signal available, which is the argument for keeping `js/` and the reason it is
now pointed at half a million points rather than 47.

**Measured, and the roadmap's estimate was wrong:** an encode costs **53 µs**,
not the 3–6 µs recorded. The breakdown says why, and it is not what the
estimate assumed:

| | |
|---|---|
| `round_fn`, one HMAC-SHA256 | 5.12 µs |
| ten rounds | 51.2 µs |
| `point_to_cell`, whole grid | 0.06 µs |

So 97% of the cost is the hash, and the Zarith arithmetic the estimate worried
about is negligible. The 3–6 µs figure implicitly assumed a C hash; the pure
OCaml backend was chosen deliberately, so that the browser and the server run
one implementation, and roughly a tenfold slowdown is what that costs. The
grid being 0.06 µs is the useful part: no future performance discussion needs
to look at the extracted core.

**Follow-on:** Phase 4 becomes a single entry weighing a native round function
against having two implementations of the hash.

---

### 2026-08-17 — Single binary and release tarball

**Phase:** 7

**What:** The UI is compiled into the server binary, so the desktop target is
genuinely one file. Extracted from the tarball into an empty directory, it
serves the app with no `--ui` flag and no asset directory anywhere; the browser
suite passes against it. `tools/package.sh` produces a 13 MB tarball holding
two executables, a licence and a README.

**Rationale:** three choices.

- *Assets are stored gzipped and served with `Content-Encoding: gzip`.* The
  js_of_ocaml core is 4.4 MB, and an OCaml source file containing a 4.4 MB
  escaped string literal is slow to compile and large in the binary. Gzipped it
  is 990 KB, which is also what a browser wants over the wire, so nothing is
  decompressed at startup and the common path does no work. A client that will
  not accept gzip gets it decompressed rather than a 406 — browsers all accept
  it, but curl and scripts should still work.
- *`make ui` copies `ui/dist` to `ocaml/server/ui_dist` rather than dune
  depending on `ui/dist` directly.* The direct route would put
  `ui/node_modules` in dune's view, and scanning ten thousand files on every
  build to reach four is a poor trade.
- *Embedded assets are checked before the directory, not after.* That way a
  `--ui` directory overrides the built-in copy, so `npm run dev` against this
  server works without rebuilding the binary; and a fresh clone that has never
  built the UI still compiles, because the generated module comes out empty and
  everything falls through to disk.

**Also:** gzip had appeared in three places — PMTiles directories, the asset
embedder, and the server decompressing for non-gzip clients — so it moved to
one `ocaml/gzip` library. The compressor uses a fixed timestamp, or an embedded
asset would make the binary irreproducible for no reason.

**Caveat, stated rather than hidden:** the binary dynamically links `libgmp`
through Zarith, so "a clean machine needs nothing installed" is not quite true.
It needs `libgmp10`, which Python and GnuPG already pull in nearly everywhere.
Recorded in the tarball's README and left open in Phase 7 rather than quietly
dropped.

**Measured:** 6 assets embedded, 5.4 s to compile them in, 15.2 MB server
binary, 13 MB tarball. The served core is byte-identical to the built bundle.

**Follow-on:** Phase 7 keeps `.deb`, AppImage, a desktop entry, and the libgmp
question.

---

### 2026-08-17 — Server hardening and a toolchain setup script

**Phase:** 0, 5

**What:** Sessions expire (1 hour TTL, 1024 ceiling, swept on write) and
`/api/session` is rate limited (token bucket, 10 burst, 1/s, `429` with
`retry_after`). `tools/setup.sh` installs the pinned toolchain from nothing,
with `--check` to report without changing anything.

**Rationale:**

- *Only one endpoint is rate limited, deliberately.* PBKDF2 is the only
  expensive thing the server does — that slowness is the point of it — and
  that is exactly what makes an unauthenticated route calling it a lever for
  exhausting the host. Limiting cheap routes would cost latency for no
  security.
- *The limiter is a pure function of state and time,* with the clock injected.
  That makes refill, exhaustion, the burst ceiling and a backwards clock
  testable directly rather than by sleeping through them. The backwards-clock
  case is the one worth having: a naive elapsed-time refill mints tokens when
  the clock steps back.
- *Sessions are swept on write, not on a timer.* There is nothing to tidy when
  nothing is happening, and an idle server should not wake up to do it. A TTL
  alone still admits unbounded growth inside one window, hence the ceiling too.
- *`setup.sh` compares its versions against `ci.yml` and refuses to run if they
  disagree.* Two copies of a pinned version drift; this makes the drift a hard
  error rather than a contributor proving something CI does not. It will not
  install opam itself — how you get the package manager is a decision about
  your machine, not one this repository should make.

**Follow-on:** Phase 0 is closed.

---

### 2026-08-17 — Rounds raised to 16; grid version bumped to 2

**Phase:** 2 (locked decision revised)

**What:** The Feistel round count went from 10 to 16, and the grid version
string from `tessarium-grid-1` to `tessarium-grid-2`. Every address
changed. All nine modules re-verify, all seven suites pass, and the
independently written implementation agrees on the new addresses.

**Rationale.** The construction is the family underlying FF1/FF3, which has a
real attack literature. Those attacks need query counts far beyond what this
threat model exposes, and 10 rounds matched FF1. But the parameters have not
been checked against the published bounds, addresses are permanent once
issued, and the cost of margin is linear and small. Buying it was free today
and impossible later — the same argument that justified the rename.

Measured: 180 µs per encode in the browser build, up from about 112 µs. A
full grid redraw with labels is roughly 216 ms, which runs in a worker and
never touches the render thread.

*The version string had to move with it.* The rule was written for
regenerating the band table, but it exists for a broader reason: an address
issued under the old parameters must fail loudly rather than quietly resolve
somewhere new. Changing the round count has exactly that effect, so the string
bumped too.

**Worth keeping:** the proof is round-count agnostic but not parity-agnostic.
An earlier negative control set `rounds` to 9 and verification failed, because
the halves swap domains each round and only an even count returns them. So
changing this number is checked by the prover rather than by inspection.

**Measured, and it reframes the key-derivation question:** the browser build
takes 241 ms per derivation at 2048 iterations, while an optimised GPU does
~244,000 per second — about 59,000x faster. Raising the iteration count scales
both sides equally and never closes that gap. The gap only closes by making
our own implementation fast, which means a native hash in each target. Now an
explicit Phase 4 item rather than an assumption that "PBKDF2 is slow, so we
are fine".

**Follow-on:** three Phase 4 items — a fast key derivation, in-app phrase
generation (the highest-value one, since a made-up phrase is the only case
where derivation cost decides anything), and writing the FE1 parameter
analysis down properly. Coarse precision moved to Phase 8 with the measurement
that killed the cheap version.

### 2026-08-17 — In-app phrase generation, privacy mode, and a UI/UX baseline

**Phase:** 4 and 6

**What:** `Tessarium.mnemonic_of_entropy` turns 32 bytes into 24 BIP-39
words, pinned to BIP-39's own published 256-bit vectors. The worker draws the
bytes from `crypto.getRandomValues` and the UI offers "Generate one for me".
Cell addresses are no longer drawn on the map at any zoom, and the bulk
address operation that fed them is gone. The panel gained an eye toggle that
removes the address from the DOM and a copy button that still works while it
is hidden. The passphrase explanation was rewritten for a non-technical
reader. The map is keyboard-operable: Enter takes the centre square.

The UI was rebuilt against the standards added to `CLAUDE.md` mid-task:
React Query for everything crossing into the worker, Zustand for app state,
Paraglide for messages in six locales (en-US/GB/CA, fr-FR/CA, es-US), Sonner
toasts for action outcomes, a banner for site-wide conditions, a shared
`IconButton` over Radix Tooltip, lucide icons, zod at the worker boundary,
Biome for linting and dprint for formatting.

**Rationale:**

- *Addresses come off the map entirely.* The item on the roadmap was about
  label placement above z20.5. Removing them is better than placing them: an
  attacker's search needs (address, real place) pairs, and a screenshot of a
  labelled grid is fifty pairs in one image from a user who thought they were
  sharing a picture of a street. One square at a time, in the panel, and the
  eye toggle takes that to none.
- *Generation stays pure.* `mnemonic_of_entropy` takes entropy rather than
  producing it. Where the bytes come from is the only thing that decides
  whether a phrase is worth 2^256 guesses or 2^40, and it is the one thing
  that cannot be judged from the output — a phrase from a counter is
  indistinguishable from one from a hardware RNG. Keeping randomness at the
  edge leaves it visible and leaves the encoding testable against BIP-39.
- *Paraglide, not a runtime dictionary.* Messages compile to typed functions,
  so a key that does not exist fails the build. Configured with
  `globalVariable` + `preferredLanguage` and no cookie or localStorage,
  because this application persists nothing and the end-to-end test asserts
  it. A language choice therefore lasts for the session only.

**Bugs found and fixed, each with a test that fails without the fix:**

- `zoo.zoo.zoo.9999` was invalid under grid version 1 and is valid under
  version 2, so the end-to-end check that it is refused had silently stopped
  testing anything. Invalid addresses are now generated into `vectors.json`
  by the core and track the grid.
- `check-suites.sh` identified the js_of_ocaml suite by its check count, so
  adding a test was indistinguishable from a suite that had stopped running —
  the exact failure that script exists to catch. It matches a name now.
- A generated phrase landed ~200 ms after the click and overwrote anything
  typed in the meantime. The field is read-only while the request is out.
- Two end-to-end waits were satisfied by state that predated the action they
  were waiting on, which left requests in flight to land later and race.

**Follow-on:** The translations are unreviewed; Paraglide fetches its plugin
from a CDN at build time, which conflicts with shipping offline. Both are in
`roadmap.md`.

### 2026-08-17 — Privacy mode on by default; Paraglide builds offline

**Phase:** 4 and 6

**What:** A newly selected square shows a masked address; the eye reveals it.
Paraglide's message-format plugin is now a pinned npm dependency referenced by
path instead of a CDN URL, so a clean checkout builds with no network after
`npm ci`.

**Rationale:**

- *Concealed by default.* The two states do not cost the same. Revealing an
  address the user did not ask to reveal hands it to whoever is behind them;
  hiding one they wanted costs a click. Copy still works while concealed, so
  the common case — get the address, send it to someone — needs no reveal at
  all.
- *Plugin from npm, not a CDN.* Closes the open question. The alternatives were
  committing 120 KB of compiled third-party JavaScript that nobody had read, or
  keeping a build-time network dependency in a project that otherwise ships
  offline. The npm package is the same artifact, pinned in the lockfile and
  installed by a step the build already runs.

**Bug found and fixed, with a test that fails without the fix:** Paraglide
treats a plugin it cannot import as a warning and then reports success, having
compiled nothing at all. The message test now checks the compiled output
against the catalogue, so that becomes a failure instead of an empty UI.

### 2026-08-17 — Adversarial review of the translations

**Phase:** 6

**What:** Two independent reviewers went over the French and Spanish against
the English source. Both returned "not safe to ship". Every finding is applied.

**Rationale:** The defects were not style. In French, `gate_passphrase_what`
attached "celle-ci" to the wrong noun, so the sentence written to stop people
confusing the passphrase with a second seed phrase said "your 24 words and
this second seed phrase decide"; and the wallet warning said `graine de
portefeuille`, a calque no French speaker uses for the thing every other
string called a `phrase de récupération` — a user could read the warning,
agree with it, and paste their wallet seed anyway. In Spanish, the wallet
warning's dropped subject resolved to the attacker ("if *they* also hold
funds"), and `contraseña` filed an unrecoverable secret under the same mental
heading as a password you can reset. Both files also named the Enter key as
the verb "to enter" in the screen-reader label.

The English changed too: "Click any square" became "Tap or click", because the
UI rules require touch parity and the source string did not have it.

**Follow-on:** A native speaker should still read all three. Recorded in
`roadmap.md`.

### 2026-08-17 — Hardened key derivation and NFKD passphrases

**Phase:** 4

**What:** One key-derivation version bump carrying two changes. Passphrases are
NFKD-normalised before hashing, as BIP-39 requires. A second PBKDF2-SHA512
stage of 200,000 iterations now derives the Feistel key from the BIP-39 seed,
replacing HKDF. The browser derives with WebCrypto instead of the bundled core.
`derivation_version` is `tessarium-kdf-2`; every address changed.

**Rationale:**

- *Argon2id was the plan and was rejected on measurement.* Pure-OCaml Argon2id
  at 64 MiB costs 21 s in a browser (BLAKE2b through js_of_ocaml: 9.2 MiB/s
  against 72.6 MiB/s native). Browser-viable parameters would be ~8 MiB, too
  little memory to justify the primitive. Kept on the roadmap with the numbers.
- *Hardened PBKDF2 instead.* BIP-39 fixes its own stage at 2048 iterations
  forever, but the seed is an intermediate here, so a second stage costs an
  attacker linearly and leaves the phrase standard BIP-39. 2048 -> 202,048 is
  98.7x: the ~10^14 single-pair forgery search goes from ~47 days on a 100-GPU
  farm to ~13 years.
- *WebCrypto in the browser.* Measured: our PBKDF2 through js_of_ocaml does
  ~8,500 iterations/s, WebCrypto 4.1 million — about 480x. That is what makes
  the new cost affordable: unlock measured at **289 ms**, against 241 ms for
  the old 2048-iteration derivation. The browser now runs different code from
  the server for this one step, which the coordinate checks below pin.
- *Iteration count by measurement.* 200,000 costs 1.2 s natively, paid only by
  the opt-in `--api` mode and the build. Higher counts are browser-cheap and
  natively expensive; this is where the two meet.

**Bugs found and fixed, each with a test that fails without the fix:**

- **The end-to-end suite never verified the browser's key.** Looking up an
  address, flying to it and clicking the square is a decode-then-encode round
  trip, which returns the address you started with under ANY key — a wrong key
  decodes it to a different place and re-encodes that place to the same words.
  The suite would have passed with the derivation completely wrong. It now
  reads the panel's coordinates back and compares them to the vector's point,
  which is the only output a wrong key changes.
- **The first NFKD test was hollow.** It unlocked with the decomposed
  passphrase, but NFKD's *output* is the decomposed form, so it passed with
  normalisation removed entirely. Reversed: it now feeds the precomposed form,
  which is the direction that can fail.
- Test points were (0, 0), which is also what a failed coordinate parse
  produces. Both the main sample and the NFKD vectors now use ordinary
  mid-latitude points.

**Follow-on:** Argon2id stays open, now with the measurements that rejected it.

### 2026-08-17 — Version-skew detection moved out of the UI

**Phase:** 6

**What:** The mapping-version line lasted one commit. The panel now shows only
`Tessarium v0.1.0` (baked from package.json at build time); the grid and
derivation versions are checked by the end-to-end suite against the vectors —
a direct worker probe, no DOM. Verifiable build identity went to the roadmap
as a Phase 7 item with the design constraint recorded: self-reported hashes
are theater, verification must happen outside the app.

**Rationale:** The skew that motivated the display was a development-phase
event (two mapping bumps in one day). A test catches it wherever it recurs;
a footer line taxes every user forever for it. Reversed on user direction.


### 2026-08-17 — In-app region downloader

**Phase:** 6

**What:** "Download maps for this view", end to end. Server: POST
/api/basemap-{estimate,download,status,cancel}, reachable without --api (they
carry a bounding box, never key material); tile and asset sources are the
`--basemap-source` / `--basemap-assets` flags, never the client; an Eio fiber
writes map.pmtiles.part and renames on completion; glyphs and sprites are
fetched and untarred once, if missing. Shared plumbing landed first as
`pmtiles_source` (the CLI's byte sources as a library), `Basemap_job` (pure
state machine) and `Untar` (pure, escape-safe). UI: a download button on the
map and an action on the missing-basemap banner open a non-modal card —
estimate, confirm, progress, cancel — all network state in React Query,
15 new message keys in all six locales. On completion the style is swapped
with a cache-busting query string and the grid/selection overlay re-added,
with no page reload, because a reload drops the key. The e2e now boots TWO
server instances: the one under test starts with an empty basemap directory
and downloads from the second, which serves a generated fixture (tiny valid
PMTiles of hand-encoded MVT tiles + sprite/glyph tarball, from
`gen_basemap_fixture`), so the suite drives our Range client against our own
Range server with no external network. 59 e2e checks, 100 server checks.

**Bugs found while building it, each now pinned by a test:**
- A POST whose declared body was never drained left its bytes in the
  keep-alive connection, where they were parsed as the start of the next
  request — every later status poll on that connection returned 405. The
  reverse mistake (reading a body that was never declared) hangs a bodyless
  curl until timeout. `Serve.declares_body` decides from the headers; unit
  tests cover both directions, and the e2e's polling loop is the integration
  regression.
- A small download can run idle-to-done entirely between two 1 s status
  polls, so "did my download finish?" was unanswerable from states alone.
  The status envelope now carries a generation counter that increments per
  start; the e2e's fixture download completes near-instantly on purpose.
- The missing-basemap banner never fired: it sniffed MapLibre error messages
  for "pmtiles", and the real messages name nothing. The UI now asks the
  server directly (HEAD /basemap/map.pmtiles); the e2e starts with an empty
  basemap directory, so the banner path runs every time.
- `make test-ui`'s cleanup trap ran after `cd ui`, so its `kill $(cat
  .server.pid)` found no file and the test server leaked. The e2e now runs
  in a subshell.

**Follow-on:** one region at a time — a new download replaces the archive —
recorded as an open roadmap item, with region merging as the likely shape.

### 2026-08-18 — World map first, merged downloads, and the speed fix

**Phase:** 6

**What:** The downloader reworked around the way people actually use offline
maps, on user feedback that a grey screen gives nothing to aim a download at.
Three pieces. (1) `Pmtiles.Merge`: downloads now merge into the archive on
disk instead of replacing it — union of tile sets, base copy wins, directories
rebuilt — so the world map survives every city added on top, estimates quote
only the bytes you do not already hold, and an area you have reports
"covered" (the UI says "you already have this" and disables the button). The
generic writer under both extract and merge is `Extract.write_tiles`;
`Archive.entries` enumerates an archive for merging. (2) World-first UI: with
no basemap on disk the card leads with "Download world map" — the whole world
at zoom 6, measured at ~44 MB against the Protomaps planet build (z7 is
187 MB, z8 551 MB) — and drops the offer once an archive exists. From there:
find the place on the world map, zoom, download the view. (3) Speed: every
range request was its own TLS connection, so a city download was thousands of
handshakes; `Pmtiles_source.with_readahead` fetches 1 MiB windows that the
small ascending reads (directories, then clustered blobs) land in. The real
world download now completes in ~30 s. The e2e drives the full sequence
offline against the fixture server: world at generation one, view detail
MERGED at generation two (header proven to span z0–15 by its own bytes),
covered-state on the third ask. 64 e2e checks, 45 pmtiles checks (merge
mutation-verified: dropping the data-offset translation fails the
byte-for-byte check).

**Rationale:** "There's so much of the world not filled in — no idea what to
download since the whole screen is gray." The world overview is what makes
every later choice visible, and merging is what makes it affordable.

**Follow-on:** base-wins means held tiles never refresh and the archive only
grows; recorded as an open roadmap item (refresh action + eviction story).

### 2026-08-18 — Tile budget and the country picker

**Phase:** 6

**What:** Two follow-ons to the world-first downloader, both from live use.
(1) The wedge: "download this view" over half a continent asked for street
level across the whole box — ~40 million tile ids to plan, minutes of
grinding during which the single-domain server answered nothing (and the
likely cause of an earlier unexplained server death, via memory). New
`Tile_id.depth_for` caps every plan at 8,192 tiles: depth follows area, so a
city view still gets z15, a continent stops at regional detail, and the
whole world lands exactly on the overview zoom. The estimate reports the
depth it chose; the card says "stops at regional detail — zoom in and
download again for street level" when it clamps. The continental estimate
that hung for minutes now answers in 1.6 s. Client requests also carry a
120 s abort so a wedged server can never again present as "checking…"
forever. (2) The picker: download a country or state by name, as the
established offline map apps do. Catalogue committed at ui/src/regions.json
(Natural Earth, public domain; 177 countries, 294 subdivisions across nine
federations), regenerated offline by tools/gen-regions.py; names localised
at runtime with Intl.DisplayNames from ISO codes, so no message keys per
country. The card's three offers (world, this view, picked region) now run
through one shared Offer component — estimate, covered, depth hint, confirm
— so they cannot drift. e2e: UK picked by its localised name merges in at
generation three; the US select exposes 51 states. 67 e2e checks, 49
pmtiles checks, 938 message checks.

**Rationale:** "Several minutes now" — the estimate was not slow, the server
was wedged planning an impossible request; the budget makes the impossible
request mean something sensible instead of refusing it. The picker is the
answer to "most open source android maps have this option".

**Follow-on:** full-depth country downloads (yieldful planning, resume) and
polygon-clipped regions, both on the roadmap.

### 2026-08-18 — Full-depth country and state downloads

**Phase:** 6

**What:** An explicit country or state pick now downloads the WHOLE thing at
street level, on user direction ("if a person picks a whole country, they
need to literally get the entire country down to the lowest level of
detail"). `Tile_id.download_depth` replaces the flat 8,192-tile clamp with
two tiers: any request that plans within 6,000,000 tile ids gets its full
depth — verified live: France 9.4 GB / 2.3M tiles / z15 (estimate in 16 s),
California 1.5 GB / z15 — and only boxes beyond the ceiling (Brazil, a
world-spanning viewport) fall back to a quick 131,072-id regional plan, with
the card's hint now saying to zoom in or pick a state or province. The
million-id planning loops yield to the scheduler (`Extract.plan ?on_tile`,
`Merge.plan ?on_entry`, injected closures with cancel polling), proven live:
healthz answered in 34 ms while a second France plan was mid-flight, and
planning is now cancellable. Depth-decision mutation-tested in the pmtiles
suite (France/California unclamped at 15, Brazil clamped, world quick).
67 e2e checks (UK now merges at true z15 against the fixture), 53 pmtiles
checks, 938 message checks, all suites green.

**Rationale:** "It keeps tailoring the view to this level of detail and then
when I zoom in more, I have to download again." Tailoring is now the
exception with an honest explanation, not the rule.

**Follow-on:** the giants (Brazil-scale boxes, Alaska's antimeridian bbox)
need chunked resumable downloads; the final directory build blocks briefly;
a country plan holds ~300–400 MB transiently. All in the roadmap item.

### 2026-08-18 — Multi-select downloads and the city catalogue

**Phase:** 6

**What:** The picker is now a filterable tree: every country expands to its
states and its cities (Natural Earth 50m populated places joined into the
committed catalogue — 1,198 cities across 173 countries; boxes drawn by
prominence and latitude, since the source carries points), and any mix of
checkboxes across any number of countries rides in ONE download.
`Merge.plan` takes a list of fresh regions and dedups them against each
other by tile id exactly as against the base, so a country plus one of its
cities pays for the overlap once — proven byte-for-byte in the pmtiles
suite (both boxes in one request equal extract-then-merge) and through the
UI in the e2e (adding London to a UK selection leaves the price unchanged).
The API now takes {"regions": [...]} (a bare box is refused) and answers
per-region max_zooms, so the card names exactly which picks are too big for
street level (Intl.ListFormat) while each region is depth-budgeted on its
own — one giant pick no longer drags the states beside it down to regional
detail. Estimates fire after the selection settles for 500 ms, not per tap.
71 e2e / 56 pmtiles / 105 server / 962 message checks, all suites green.

**Rationale:** "I'd like some sort of expanded view where I can select
multiple states or cities at the same time." Built on native
details/summary and checkboxes rather than a component library: every
behavior in the tree — disclosure, toggling, keyboard focus — is the
browser's own, per the house rule of taking primitives instead of
re-implementing behavior.

**Follow-on:** several full-depth countries in one selection plan
sequentially and can outlive the client's 120 s estimate timeout — noted on
the giants roadmap item. City boxes are drawn, not boundaries — noted on
the boxes item.

### 2026-08-18 — Grid overlay lost after a download's style swap

**Phase:** 6

**What:** After any completed download the map rebuilt its style, and the
grid and selection overlay never came back: when MapLibre's style diff
succeeds it fires style.load synchronously inside the setStyle call, and
rebuildBasemap registered its once-listener after the call — too late,
every time. Each missed listener stayed armed and repaired the NEXT swap,
so back-to-back downloads masked the loss and a single download (the
real-world case — reported over a fresh Georgia download) lost the grid
until reload. Fix: register the listener before setStyle (serves both the
synchronous diff path and the asynchronous rebuild fallback), plus an
idempotence guard in addOverlay. Regression test per the hard rule, shown
failing first: the e2e now asserts the overlay's sources and layers survive
the FIRST download's swap and that the grid refills, via a
window.__tessarium_map test handle (the map holds tiles and geometry,
never the key or an address). 73 e2e checks.

**Rationale:** checked after the first download deliberately — the leaked
listeners made any later swap look healthy.

### 2026-08-18 — Resumable multi-part downloads for the giants

**Phase:** 6

**What:** Boxes too big to plan in one piece (over 6M tile ids) now split
into at most eight parts that each fit the proven single-part envelope
(`Tile_id.split`: bisect the worst offender along its longer tile axis;
coverage proven exactly in the pmtiles suite -- union of part ids equals the
box's ids). Parts fetch sequentially, each merged into the archive and
renamed atomically; an interruption or cancel keeps every finished part, and
a re-request finds a held part covered and skips it after planning alone --
that is the resume, proven in e2e against a third server instance running
`--tile-budget 1024,256,8` (split download completes with parts >= 2;
re-download skips every part and says "already have"). Single-box regions
still ride one merge so overlapping picks keep deduping. `Merge.plan`
rewritten from hashtable to sorted-array merge-join (~3x less memory on
giant bases; byte-for-byte identical output under the existing round-trip
checks). Job states carry part/parts; the UI bar tracks the current part
("Part 2 of 4"). Estimates plan units one at a time and discard them
(bounded memory); client estimate timeout raised to 300 s. Live against the
planet build: Brazil 6.03 GB / 17.9M tiles / z15 estimated in 52 s;
continental US 19.1 GB / 21.7M tiles / z15; healthz under 1 s mid-plan.
77 e2e / 61 pmtiles / 106 server / 974 message checks green.

**Rationale:** sequential atomic part-merges reuse the entire existing merge
machinery -- resume falls out of base-wins dedup rather than a new on-disk
format. The write amplification that buys is recorded on the roadmap item.

### 2026-08-18 — Polygon-clipped countries and honest antimeridian boxes

**Phase:** 6

**What:** Country downloads now stop at the border instead of the bounding
box. The catalogue carries each country's outer rings (Natural Earth 110m,
Douglas-Peucker simplified to a 300-point budget, 2-decimal quantised;
229 KB total), and the picker sends them with each region. The server
validates polygons at the door (64 rings / 2048 points / in-range, tested),
plans them with a quadtree walk (`Tile_id.clip_walk`: prune outside
subtrees, enumerate inside subtrees arithmetically, per-tile tests only on
the border -- proven equal to the per-tile definition by brute force in the
pmtiles suite), and budgets and splits giants with clipped counts.
Antimeridian countries become two honest boxes clustered from polygon
parts (Russia: 19..180 plus -180..-169.9; Fiji likewise) riding the
existing multi-region API -- no server change at all. Live: France
polygon-clipped is 5.23 GB / 1.14M tiles / z15 in 12.9 s, versus 9.36 GB
for the metropolitan box alone, and now includes Guiana and Corsica;
clipped Canada (~36M ids) fits the giant ceiling its 112M-id box never
could. 79 e2e / 66 pmtiles / 110 server / 974 message checks green.

**Rationale:** clipping in the planner (quadtree, O(border)) rather than
per-tile keeps a z15 country affordable -- a ray cast per candidate tile
would be billions of tests. Holes deliberately unmodelled: downloading the
Lesotho-shaped sliver inside South Africa is harmless; missing an enclave
would not be.

### 2026-08-18 — Polygon branch review findings fixed

**Phase:** 6

**What:** Adversarial review found the border simplifier silently dropping
rings (Canada lost Vancouver Island; the US lost Molokai; 122 cities in all
fell outside their simplified borders) and the clipped planner burning
unyielding, unbounded CPU (a within-caps sawtooth polygon could wedge the
server for hours). Fixed: ring simplification is anchored on a real chord
and a collapsed ring survives as its bounding quad; the generator escalates
each country's point budget until every catalogued city sits inside the
simplified border, appending a city's drawn box as an extra ring when its
point sits off the coarse 110m coastline; a committed data-invariant suite
(ui/test/regions.mjs, 1,691 checks, in npm run check) ray-casts every city
against its country's polygon -- it failed 122 ways against the old data.
The quadtree walk gained a yield hook wired to the server's breathe/cancel
closure and a work budget (2^28 ring-point operations) that kills
pathological polygons cleanly. Antarctica, which encircles a pole and
defeats lon/lat ray casting, ships no polygon and two hemisphere boxes.
Plus: polygon null and [lon,lat,elev] positions accepted; classify gets
direct unit checks; a multi-box country's depth warning stays named.

**Rationale:** cities are the acceptance test for a border because they are
exactly what a country download must contain.

### 2026-08-18 — Contrast audit enforced; error toasts wait to be read

**Phase:** 6

**What:** Every foreground/background pair the stylesheet uses is now
measured against WCAG AA by ui/test/contrast.mjs (41 checks, wired into
npm run check), reading the palette live from styles.css so drift fails the
build; literal-presence checks keep the hand-listed pairs honest. The audit
found the active palette already passing -- --accent's 3.95:1 is only ever
the 19px/600 address line, which is large text at a 3:1 bar, and that
rationale is now pinned in the test -- and one genuinely illegible pair:
disabled button labels at 1.63:1 (WCAG-exempt, but unreadable), now 5.66:1.
Review fixes went further: the large-text exemption
for the accent died entirely (a mobile media query renders the address at
17px, under the bold threshold) -- the address now uses --accent-text at
4.84:1; sonner's richColors was dropped because its red-on-pink error text
sat at 4.35:1 outside the stylesheet where no audit can see it; input and
select borders moved to --line-strong (3.44:1, non-text 3:1) from a 1.33:1
hairline; placeholders are pinned to the audited hint colour. Error toasts
persist until dismissed (ui/src/toast.ts wraps every toast.error call; the
e2e asserts a toast carries the close button): a five-second auto-dismiss
is shorter than a long error read aloud through sonner's live region.
Out of the audit's reach, recorded here: canvas-drawn grid and selection
colours over arbitrary map imagery are not statically checkable. 51
contrast checks, 80 e2e checks green.

**Rationale:** an audit that runs once rots; this one runs on every check.

### 2026-08-18 — FE1 security write-up

**Phase:** 4

**What:** docs/fe1-security.md, linked from the README: the construction's
exact parameters (a ≈ 2^22.6, b ≈ 2^23.6, 16 rounds, HMAC-SHA256, fixed
tweak); the two oracles and their arithmetic (raw encode 81 µs, measured
at 16 rounds by the new ocaml/tools/bench_encode.ml; with the 1/s-burst-10
limiter, a million queries ≈ 11.6 days, the full codebook ≈ 2.7 million
years); Bellare–Hoang–Tessaro 2016,
Durak–Vaudenay 2017 and Hoang–Miller–Trieu 2019 each named with why it
does not reach these parameters (small-domain data requirements; chosen
tweaks against a compile-time tweak constant; 8-round FF3 structure); the
codebook-is-not-the-key endgame; the two key-search spaces stated together
(KDF prices phrase guessing only; the raw 2^256 keyspace needs no pricing
and yields no phrase); the quantum dismissal with citations
(Kuwakado–Morii needs superposition queries; offline-Simon targets
Even–Mansour/FX, not 16-round PRF Feistel). Every number cross-checked
against the source before writing.

**Rationale:** the roadmap demanded the dismissal read as informed, with
the load-bearing role of the rate limiter written down rather than assumed.

### 2026-08-18 — Writing the security doc found the limiter gap

**Phase:** 4

**What:** Adversarial review of the FE1 write-up refuted its central
quantitative claim against the code: only /api/session was rate-limited;
encode and decode were raw oracles answering at full speed, so "a million
queries ≈ 11.6 days" described a control that did not exist. The limiter
now covers every key-touching endpoint via a pure, tested
rate_limited_endpoint predicate applied at dispatch (mutation-tested: the
suite fails three ways when encode/decode leave the set). Scripting
consequence, deliberate: the opt-in API now answers at most 1 encode or
decode per second sustained. Also corrected from the same review: the KDF
chain is two PBKDF2 stages (HKDF text was stale in the locked decisions and
copied into the doc); encode is 81 µs at 16 rounds, measured by the new
committed bench, not the ten-round-era 53 µs; the 2:1 split is
"near-balanced, tolerated", not "balanced"; attack families are
round-parameterized (demonstrations at 8-10 rounds), stated as such; the
offline-Simon citation no longer absorbs Hosoyamada-Sasaki's separate
six-round classical-query Feistel work. CLAUDE.md still names the tweak
tessarium-grid-1 (code says -2); left for the user, per its own rule.

**Rationale:** the write-up exists to be checked against the code; being
falsified by its own review and forcing the code to match is that working.

### 2026-08-18 — Desktop packaging: static gmp, .deb, AppDir, repro CI

**Phase:** 7

**What:** libgmp is now linked statically into both binaries -- via a
search-path trick (a build directory holding only libgmp.a outranks the
system's .so for every -lgmp), because zarith's cmxa embeds its own flag
ahead of anything the command line can say -- so the tarball's "needs
nothing installed" claim is finally true, and its README says so (GMP is
LGPL; the repository's full source alongside is what keeps that
compliant). tools/package.sh now emits a bit-deterministic tarball (sorted,
root-owned, fixed mtimes, gzip -n) carrying the new desktop entry and icon;
tools/package-deb.sh builds a deterministic .deb (SOURCE_DATE_EPOCH;
depends on libc6 alone) with menu integration; tools/package-appimage.sh
builds a complete AppDir and hands off to appimagetool, which CI images do
not carry -- the residue is a roadmap line. Determinism proven locally:
tarball and .deb hashes identical across rebuilds, the UI bundle identical
across clean builds, and CI gained a `reproducible` job that builds and
packages twice from clean and diffs the checksums -- the first rung of
verifiable builds, leaving that item blocked on a release key only.
`make package-deb` and `make package-appimage` wired. Full wall green
(80 e2e / 51 contrast / 1691 catalogue / all 7 dune suites).

**Rationale:** published checksums are worthless if the build is not
bit-reproducible; the CI job is what keeps that property from rotting.

### 2026-08-18 — Packaging review findings fixed

**Phase:** 7

**What:** The reproducible-CI job could never pass -- its git clean deleted
the vendored fstarlib modules the second build needed (now excluded). The
.deb's hardcoded libc6 floor understated reality (binaries import
GLIBC_2.35; the floor is now computed from objdump at build time). Both
artifacts inherited the packager's umask (077 broke dpkg-deb outright; 002
shipped group-writable /usr) -- both scripts now set umask 022 and tar
normalizes modes. The .deb gained md5sums and a copyright file naming GMP's
LGPL and source now that it is statically embedded; the tarball README
likewise. AppRun no longer makes --basemap unrepeatable. Installed-Size
uses apparent size. Determinism claims scoped honestly: bit-identity holds
per-toolchain; cross-machine identity needs the ~60 absolute opam paths
scrubbed from the binaries first (recorded on the verifiable-builds item).

**Rationale:** a reproducibility check that cannot pass, guarding a
dependency floor that cannot hold, is worse than none -- it certifies.

