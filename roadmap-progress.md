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
