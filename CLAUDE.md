# Instructions for Claude Code

Read `README.md` for what this project is, `roadmap.md` for what's next.

## Your behavior
- Never modify this document without consulting the user first
- Explain things in concise, plain english free of technical jargon. 
- Use technical terms accurate to the domain terms in the codebase
- When making technical decisions, do not give weight to development cost or development hours. Instead prefer readability, quality, simplicity, robustness, scalability, testability, and long term maintainability
- When writting commit messages, be extremely concise. Favor concision over proper grammar.

## Roadmap and progress — read and update it, don't rely on memory

**`docs/roadmap.md` is the SINGLE SOURCE of open work** — deferred features and known gaps, each with the constraint that motivated deferral. It must survive a compacted or cleared session, so keep it current instead of holding state in your head:

- At the start of a task, read the roadmap to see current status; at the end,update it so the next agent (or the next session) picks up an accurate picture.
- When you finish a roadmap item, record it in **`docs/roadmap-progress.md`**
  (the completions ledger: date, section title, version, branch, short
  as-built note) and DELETE the finished section from roadmap.md
- NO completion notes, RESOLVED markers, or progress pointers
  in roadmap.md, ever
- it holds only open work. A partially finished item keeps a section describing only what is still open, with the
  shipped half recorded in the ledger. 
- When you defer new work, add a roadmap section describing it and why. **Check the ledger before assuming an item is open** 
- Do not create new progress-tracker docs for multi-stage builds without the user asking

## Core coding principles

These hold in both languages — OCaml in `core/`, TypeScript in `dashboard/`.

- Always use a function-first immutability-first coding style unless the developer approves of you not doing so
- Use pure functional programming style unless the developer approves of you not doing so. A function is pure when:
  1. the function return values are identical for identical arguments (no variation with local static variables, non-local variables, mutable reference arguments or input streams, i.e., referential transparency), and
  2. the function has no side effects (no mutation of non-local variables, mutable reference arguments or input/output streams).
- Effects that cannot be avoided belong at the edges of the code: the core injects them (`chat_client`, `tool_runner`, `git_hook`), the dashboard keeps them in React Query and Zustand. The decision itself goes in `core/lib/` or `dashboard/src/lib/`, where it is unit-tested with no browser, no network, and no clock.
- Use the DRY principle (reducing redundancy by ensuring that every piece of knowledge has a single, authoritative representation in a system) unless the excess abstraction complicates the code by creating unnecessary layers that make it harder to understand, modify, test. 

## Hard rules

**Work tracking lives in exactly two files.** All future work in `roadmap.md`;
completed work moves to `roadmap-progress.md` (removed from the roadmap, not
left checked off in both). Do not create `TODO.md`, `NOTES.md`, `PLAN.md`,
`CHANGELOG.md`, or an issues directory. Do not use code comments as a backlog.
If a decision is worth keeping, it belongs in the roadmap's *Locked decisions*
section or in a progress entry's rationale field.

**Never hand-edit extracted code.** Once F\* extraction is running, the
generated OCaml and C are build artifacts. Changes belong upstream in
`fstar/`, or they are silently overwritten at the next extraction. CI should
regenerate and diff.

**No new hand-written implementations of the algorithm.** One proved F\*
source, several extraction targets. `reference/` and `js/` already violate
this and are labelled scaffolding — do not add a third, and do not add
features to the two that exist.

**No floating point in the encode/decode path.** Integer nanodegrees
throughout. This is what makes a browser and a server agree exactly. Floats
appear only in `design/grid_design.py`, which runs offline and emits a data
table. If you find yourself reaching for a float in `fstar/`, `ocaml/`,
`reference/tessarium/` or `js/`, stop.

**Do not claim this is verified.** The F\* files state theorems; nothing has
been through `fstar.exe` yet. The README says so. Keep it that way until CI
proves otherwise.

**Clean room.** Do not consult, reference or vendor what3words' wordlist,
grid or algorithm.

## Current state

Design is settled and validated. The verified implementation is not written.

- `design/` — band table generator. Locked at 6,553,600 rows / 4096 bands.
- `reference/` — Python, passes 30 property checks. **Scaffolding**, see
  `reference/README.md`. Slated for deletion in Phase 4.
- `js/` — independent JS implementation, agrees with the reference on all
  vectors plus 4,000 fuzz cases. Scaffolding; fate decided at Phase 6.
- `vectors/vectors.json` — 150 cross-platform vectors. Currently generated
  from the Python, which is backwards; re-anchoring to F\* is a Phase 4 item.
- `fstar/` — interfaces and theorem statements only. No implementations.
- `ocaml/` — core interface (`lib/tessarium_core.mli`) and Dream server. Never
  compiled; there is no toolchain in the environment where it was written.

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

```bash
cd reference && python3 test_reference.py    # property tests, ~60s
node js/test_vectors.mjs                     # differential vs committed vectors
cd design && python3 grid_design.py          # regenerate the band table
```

Regenerating the band table changes every address. The tweak string
(`tessarium-grid-1`) must be bumped if it ever changes, and the vectors regenerated.

## Where to start

Phase 1 in `roadmap.md`: implement `fstar/Tessarium.Grid.fsti` and prove
`lemma_edge_inverse` first. That lemma corresponds to a real bug the reference
implementation had — inverting a floor-bucket with a floor instead of a
ceiling, putting every cell's upper edge one nanodegree short. It produced no
crash and no error, just wrong answers at cell boundaries, which is the exact
failure mode this project exists to rule out.

You will need `fstar.exe` and Z3 4.13.x, plus OCaml 4.14+ with `dune`,
`dream`, `yojson` and `digestif` for the server. None are installed.

## Things that are open, not decided

Listed at the bottom of `roadmap.md`. Notably: whether the server should ever
see a seed phrase (client-side derivation is the better privacy story and the
API was shaped to keep that door open), and whether to take HMAC-SHA256 from
HACL\* or assume it at the interface. Don't quietly settle these — put the
reasoning in a progress entry.
