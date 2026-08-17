# Instructions for Claude Code

Read `README.md` for what this project is, `roadmap.md` for what's next.

## Your behavior
- Never modify this document without consulting the user first
- Explain things in concise, plain english free of technical jargon. 
- Use technical terms accurate to the domain terms in the codebase
- When making technical decisions, do not give weight to development cost or development hours. Instead prefer readability, quality, simplicity, robustness, scalability, testability, and long term maintainability
- When writting commit messages, be extremely concise. Favor concision over proper grammar.

## Roadmap and progress — read and update it, don't rely on memory

**`roadmap.md` is the SINGLE SOURCE of open work** — deferred features and known gaps, each with the constraint that motivated deferral. It must survive a compacted or cleared session, so keep it current instead of holding state in your head:

- At the start of a task, read the roadmap to see current status; at the end,update it so the next agent (or the next session) picks up an accurate picture.
- When you finish a roadmap item, record it in **`roadmap-progress.md`**
  (the completions ledger: date, section title, version, branch, short
  as-built note) and DELETE the finished section from roadmap.md
- NO completion notes, RESOLVED markers, or progress pointers
  in roadmap.md, ever
- it holds only open work. A partially finished item keeps a section describing only what is still open, with the
  shipped half recorded in the ledger. 
- When you defer new work, add a roadmap section describing it and why. **Check the ledger before assuming an item is open** 
- Do not create new progress-tracker docs for multi-stage builds without the user asking

## Core coding principles

These hold in all three languages — F\* in `fstar/`, OCaml in `ocaml/`,
TypeScript in `ui/`.

- Always use a function-first immutability-first coding style unless the developer approves of you not doing so
- Use pure functional programming style unless the developer approves of you not doing so. A function is pure when:
  1. the function return values are identical for identical arguments (no variation with local static variables, non-local variables, mutable reference arguments or input streams, i.e., referential transparency), and
  2. the function has no side effects (no mutation of non-local variables, mutable reference arguments or input/output streams).
- Effects that cannot be avoided belong at the edges. The core injects them:
  `Tessarium.Feistel` takes the round function as a parameter,
  `Pmtiles.Archive` takes a byte-reading function, `Pmtiles.Extract` takes the
  copy. The decision itself goes somewhere it can be unit-tested with no
  socket, no filesystem and no clock — `ocaml/server/route.ml`,
  `http_range.ml` and `url_path.ml` are the pattern to copy.
- Use the DRY principle (reducing redundancy by ensuring that every piece of knowledge has a single, authoritative representation in a system) unless the excess abstraction complicates the code by creating unnecessary layers that make it harder to understand, modify, test. 

## Hard rules

**Work tracking lives in exactly two files.** All future work in `roadmap.md`;
completed work moves to `roadmap-progress.md` (removed from the roadmap, not
left checked off in both). Do not create `TODO.md`, `NOTES.md`, `PLAN.md`,
`CHANGELOG.md`, or an issues directory. Do not use code comments as a backlog.
If a decision is worth keeping, it belongs in the roadmap's *Locked decisions*
section or in a progress entry's rationale field.

**Never hand-edit extracted code.** `ocaml/extracted/` is a build artifact,
like an object file. Changes belong upstream in `fstar/`, or they are silently
overwritten at the next extraction. CI regenerates and diffs, so a hand edit
fails the build rather than surviving quietly.

**No new hand-written implementations of the algorithm.** One proved F\*
source, several extraction targets. `reference/` and `js/` already violate
this and are labelled scaffolding — do not add a third, and do not add
features to the two that exist.

**No floating point in the encode/decode path.** Integer nanodegrees
throughout. This is what makes a browser and a server agree exactly. Floats
appear only in `design/grid_design.py`, which runs offline and emits a data
table; in `Pmtiles.Tile_id`, which picks which map tiles to download and never
touches an address; and at the UI boundary, where degrees are converted for
display. If you find yourself reaching for a float in `fstar/`, `ocaml/lib/`,
`reference/tessarium/` or `js/`, stop.

**Say exactly what is proved, and no more.** Every module in `fstar/` verifies
with zero admits, enforced by `--report_assumes error`. The theorems are listed
in `README.md`. What is NOT proved: that the mapping is unguessable (that rests
on HMAC-SHA256 behaving as a PRF, which is an assumption); the F\* extraction
pipeline and `ocamlopt`; `digestif`'s SHA-2, which is vector-tested; and every
line of `ocaml/server/`, `ocaml/pmtiles/` and `ui/`, none of which is F\* at
all. Do not let a summary blur the line between "the core is proved" and "the
program is correct".

**A theorem that asserts nothing is worse than a missing one**, because it
reads as coverage. Before adding one, check it can fail: state a false variant
and confirm the solver rejects it.

**Clean room.** Do not consult, reference or vendor what3words' wordlist,
grid or algorithm.

## Current state

Working end to end. Enter a 24-word phrase, the map opens under it, click a
square and get its address; paste an address and fly back to that square.

- `fstar/` — the verified core. All modules verify, no admits.
- `ocaml/extracted/` — F\* output. **Build artifact, never edited.**
- `ocaml/lib/` — key derivation, crypto, public API over the extracted core.
- `ocaml/js/` — js_of_ocaml bindings; the browser runs this same extraction.
- `ocaml/server/` — Eio HTTP server. Also the desktop binary.
- `ocaml/pmtiles/` — PMTiles v3 reader and region extractor.
- `ui/` — Vite + React + MapLibre GL. The key lives in a Web Worker.
- `design/` — band table generator. Locked at 6,553,600 rows / 4096 bands.
- `reference/` — Python, passes 30 property checks. **Scaffolding**, see
  `reference/README.md`. Slated for deletion in Phase 4.
- `js/` — independent JS implementation. Scaffolding; fate decided at Phase 6.
- `vectors/vectors.json` — 199 cross-platform checks. Still generated from the
  Python, which is backwards; re-anchoring to F\* is a Phase 4 item.

## Branches and Commit messages — use Conventional Commits

- Follow the spec: <https://www.conventionalcommits.org/en/v1.0.0/#specification>

```
<type>[optional scope][!]: <description>

[optional body]

[optional footer(s)]
```

- **Allowed types:** `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`,
  `build`, `ci`, `chore`, `revert`.
- **description:** imperative mood, lowercase, no trailing period.
- **Breaking changes:** add `!` after the type/scope (e.g. `feat(create)!:`) and/or
  a `BREAKING CHANGE:` footer.
- **Examples:**
  - `feat(security): add container fingerprint hardening`
  - `fix(create): bind sshd to loopback only`
  - `chore: adopt test/ and lib/ layout`
- End messages with the `Co-Authored-By:` trailer naming the AI model used.

## Running things

The toolchain is not on `PATH` by default:

```bash
eval "$(make env)"      # F* 2026.08.09 + Z3 4.13.3, opam switch, nvm
```

```bash
make verify             # prove every module; zero admits is enforced here
make extract            # regenerate ocaml/extracted from the proved source
make build              # native binaries and the js_of_ocaml bundle
make ui                 # build the web UI
make test               # all five suites
make run                # serve on 127.0.0.1:7373 and open a browser

tools/fetch-basemap.sh  # offline tiles, glyphs and sprites
cd design && python3 grid_design.py    # regenerate the band table
```

Regenerating the band table changes every address. The tweak string
(`tessarium-grid-1`) must be bumped if it ever changes, and the vectors regenerated.

## Where to start

`roadmap.md`. The largest open gap is that nothing proves the extracted OCaml
matches the F\* it came from — the extraction pipeline is trusted, and 199
committed vectors are the only thing bridging it.

Toolchain: F\* 2026.08.09 with Z3 4.13.3 from a binary release in `$HOME`,
OCaml 5.3.0 via the `tessarium` opam switch, Node 24.19.0 via nvm. OCaml
5.1+ is a hard floor — `zarith_stubs_js`, which is what makes the extracted
core's bignum arithmetic work in a browser, requires it.

## Things that are open, not decided

Listed at the bottom of `roadmap.md`. Notably: whether `js/` survives now that
it is the only independent check on the extracted core, and whether to keep
depending on `demo-bucket.protomaps.com` for basemap tiles, which is a demo
bucket with no availability promise. Don't quietly settle these — put the
reasoning in a progress entry.

Two questions that WERE here are now closed, and reopening either needs a note
in the ledger: the server never sees a seed phrase by default (keys are derived
in the browser; the opt-in API exists for scripting), and HMAC-SHA256 comes
from `digestif`'s pure-OCaml backend rather than HACL\*, because HACL\*'s C
stubs do not cross into js_of_ocaml and taking it would force a second
browser-side crypto implementation.
