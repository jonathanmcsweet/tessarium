# Instructions for Claude Code

Read `README.md` for what this project is, `roadmap.md` for what's next.

## Your behavior
- Never modify this document without consulting the user first
- Explain things in concise, plain english free of technical jargon. 
- Use technical terms accurate to the domain terms in the codebase
- When making technical decisions, do not give weight to development cost or development hours. Instead prefer readability, quality, simplicity, robustness, scalability, testability, and long term maintainability
- When writting code comments or commit messages, be extremely concise. Favor concision over proper grammar.
- Do not write code comments unless they're approved by me. You must justify their existence. Code is inherently a form of documentation
- never use em dash

## In-app text and user documentation

- Write as one person telling another something useful, not as a specification.
- Let related facts share a sentence with commas or appositives. Don't give each fact its own sentence.
- Say what a thing is and what it's good for, not what it isn't.
- Don't add a paragraph explaining how to interpret what you just said.
- Cut any detail that doesn't change what the reader thinks or does.
- Never end a paragraph on a short punchy line.
- Never use gnomic aphorisms

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

These hold in all languages
- Always use a function-first immutability-first coding style unless the developer approves of you not doing so
- Use pure functional programming style unless the developer approves of you not doing so. A function is pure when:
  1. the function return values are identical for identical arguments (no variation with local static variables, non-local variables, mutable reference arguments or input streams, i.e., referential transparency), and
  2. the function has no side effects (no mutation of non-local variables, mutable reference arguments or input/output streams).
- Effects that cannot be avoided belong at the edges. The core injects them
- Use the DRY principle (reducing redundancy by ensuring that every piece of knowledge has a single, authoritative representation in a system) unless the excess abstraction complicates the code by creating unnecessary layers that make it harder to understand, modify, test. 
- Avoid undefined and null whenever possible

## Hard rules

**Work tracking lives in exactly two files.** All future work in `roadmap.md`;
completed work moves to `roadmap-progress.md` (removed from the roadmap, not
left checked off in both). Do not create `TODO.md`, `NOTES.md`, `PLAN.md`,
`CHANGELOG.md`, or an issues directory. Do not use code comments as a backlog.
If a decision is worth keeping, it belongs in the roadmap's *Locked decisions*
section or in a progress entry's rationale field.

**No dates in documentation.** `README.md`, `docs/` and roadmap items say
what is true, not when it became true no "as of", no "since 2026-08-20",
no "landed on." Git records when a thing changed, `roadmap.md` and `roadmap-progress.md`
records dates.

**Never hand-edit extracted code.** `ocaml/extracted/` is a build artifact,
like an object file. Changes belong upstream in `fstar/`, or they are silently
overwritten at the next extraction. CI regenerates and diffs, so a hand edit
fails the build rather than surviving quietly.

**No new hand-written implementations of the algorithm.** One proved F\*
source, several extraction targets. `reference/` (Python) was deleted once the
F\* could act as the oracle. `js/` is kept deliberately, as a differential
oracle rather than as architecture: the extraction pipeline is trusted rather
than verified, so an independently written implementation checks something no
second extraction target can. It runs in CI over half a million points. Do not
add features to it, and do not add a third.

**No floating point in the encode/decode path.** Integer nanodegrees
throughout. This is what makes a browser and a server agree exactly. Floats
appear only in `design/grid_design.py`, which runs offline and emits a data
table; in `Pmtiles.Tile_id`, which picks which map tiles to download and never
touches an address; and at the UI boundary, where degrees are converted for
display. `ocaml/server/rate_limit.ml` and `ocaml/server/http_cache.ml` also use
them, both for time, which is not the encode path. If you find yourself
reaching for a float in `fstar/`, `ocaml/lib/` or the grid parts of `js/`,
stop.

**Say exactly what is proved, and no more.** Every module in `fstar/` verifies
with zero admits, enforced by `--report_assumes error` AND by
`tools/check-fstar-assumes.sh`. Both, because the flag covers only the escape
hatches reached through a term -- `admit`, `assume (p)`, `magic`, `admitP` --
and is silent on `assume val`, `assume type` and an interface whose
implementation is missing. The script covers exactly that remainder. Neither
alone is the rule. The theorems themselves are the `theorem_*` declarations in
`fstar/`; `README.md` summarises them in plain English and is not a list of
them. What is NOT proved: that the mapping is unguessable (that rests
on keyed BLAKE2s behaving as a PRF, which is an assumption); the F\* extraction
pipeline and `ocamlopt`; `digestif`'s BLAKE2s and SHA-2, which are
vector-tested; `ocaml/pmtiles/`, `ui/`, and all of `ocaml/server/` except
which files it will open -- `resolve` in `url_path.ml` is a wrapper over
extracted F\* since 2026-08-22, and the rest of that file, `content_type`
included, is not.
(`Tessarium.Words`): a typed word only ever resolves to one it spells the
beginning of, and an abbreviation only when a single word could have been
meant. Its EXACT-match fast path is not proved -- that is a hashtable in
front of the proved lookup, carrying the same property as a one-comparison
runtime check, over a load-time check that the list holds no duplicate so
the two paths cannot disagree. Say it that way; "the word lookup is proved"
is one clause too few.

Do not let a summary blur the line between "the core is proved" and "the
program is correct".

**A theorem that asserts nothing is worse than a missing one**, because it
reads as coverage. Before adding one, check it can fail: state a false variant
and confirm the solver rejects it.

**Every bug outside the proof's reach gets a test.** The theorems cover the
grid, the permutation, the codec and which files the server will open. They
cover nothing else in the server, nor the UI, the PMTiles code, key derivation,
or the build. When a bug is found in any of
those, land a unit or end-to-end test that fails without the fix — in the same
commit, not later. Two from this project, both of which passed every existing
test at the time they shipped:

- the BIP-39 passphrase was case-folded, so `MySecret` and `mysecret` gave the
  same map. Every committed vector used an empty passphrase, so nothing looked
  at it.
- worker errors were returned nested inside a success value, so an address
  that decodes to nothing reported success. The valid path was perfect.

A new test must be shown to fail before the fix, or it is decoration.

**Clean room.** Do not consult, reference or vendor what3words' wordlist,
grid or algorithm.

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
tools/setup.sh          # install the toolchain; --check to report only
eval "$(make env)"      # F* 2026.08.09 + Z3 4.13.3, opam switch, nvm on PATH
```

```bash
make verify             # prove every module; zero admits is enforced here
make extract            # regenerate ocaml/extracted from the proved source
make build              # native binaries and the js_of_ocaml bundle
make ui                 # build the web UI
make test               # all five suites
make run                # serve on 127.0.0.1:7373 and open a browser
make package            # release tarball

tools/fetch-basemap.sh  # offline tiles, glyphs and sprites
cd design && python3 grid_design.py    # regenerate the band table
```

Regenerating the band table changes every address. The tweak string
(`tessarium-grid-3`) must be bumped if it ever changes, and the vectors regenerated.

Four protocol constants carry the project name. Three are hashed into every
address — the tweak above, the round-function domain prefix
(`tessarium/v3/fe1`) and the Argon2id salt (`tessarium-kdf-4`) — and the
fourth (`tessarium_ledger`) names a blob inside downloaded map archives.
Changing any of the three invalidates every address anyone holds, so bump
the version number rather than reusing it. The domain prefix and the tweak
also have their LENGTHS baked into the message transcription in
`fstar/low/Tessarium.Low.Blake2s.fst`; changing either length means redoing
that transcription by hand and re-verifying. The numbers themselves live in
that file and in `ocaml/lib/crypto.ml`, which refuses to load if a length is
wrong — and nowhere else, because when this warning carried its numbers in
five places, two of them went stale. All four constants moved once, on
2026-08-23, with the project's rename — see the ledger for what that took.

## Where to start

`roadmap.md`. The largest open gap is that nothing proves the extracted OCaml
matches the F\* it came from — the extraction pipeline is trusted, and the
committed vectors plus the differential sweep are the only things bridging it.

Toolchain: F\* 2026.08.09 with Z3 4.13.3 from a binary release in `$HOME`,
OCaml 5.3.0 via the `tessarium` opam switch, Node 24.19.0 via nvm. OCaml
5.1+ is a hard floor — `zarith_stubs_js`, which is what makes the extracted
core's bignum arithmetic work in a browser, requires it.

## Things that are open, not decided

Listed at the bottom of `roadmap.md`. Notably: whether `js/` survives now that
it is the only independent check on the extracted core, and whether basemap
tiles need a self-hosted mirror rather than Protomaps' daily builds, which
carry no availability promise. Don't quietly settle these — put the
reasoning in a progress entry.

Questions that WERE here are now closed, and reopening one needs a note in
the ledger: the server never sees a seed phrase by default (keys are derived
in the browser; the opt-in API exists for scripting); the round function
(keyed BLAKE2s since 2026-08-20, HMAC-SHA256 before -- the move off NIST
primitives is ledgered) comes from `digestif`'s pure-OCaml backend rather
than HACL\*, because HACL\*'s C stubs do not cross into js_of_ocaml and
taking it would force a second browser-side crypto implementation; and basemap tiles come from the newest
Protomaps daily build, resolved from the published listing at use time,
because the stable demo-bucket URL was deleted upstream (ledger, 2026-08-18).

## UI / UX
- All network state management needs to be in React Query
- All non-network app state management needs to be managed by Zustand
- For anything with behavior (focus traps, popovers, keyboard handling), take an
  accessible primitive from a vetted library rather than hand-rolling
- All success and failure messages for atomic behaviors like submitting to an API should use Toast messages
- Site-wide notifications for issues that affect the global app should show as banners at the top of the screen
- WCAG compliance is required
  - If a feature can't be WCAG compliant, propose an alternative for users that need it. I.e. a table for those who can't see a graph
- i18n compatability is a must
- **Everything must work on both mobile and desktop.** 
  - Every view and control must be usable with touch and with a mouse/keyboard. 
  - Use responsive layout (relative units, flex/grid) so nothing overflows the viewport on a small screen
  - give touch targets enough size.
- **An icon is never enough on its own.** 
  - Every button or navigation element must have accomanying text, either in the button or as a tooltip
  - Use the shared `IconButton` component (hover, keyboard-focus, and long-press tooltip)
  - Always provide an `aria-label` on an icon-only control, in addition to the
  visible tooltip, so assistive technology announces it.
- Use a shared icon set. Do not hand-roll SVG glyphs for UI icons unless there isn't a sufficient icon available
