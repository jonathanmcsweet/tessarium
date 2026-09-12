# OCaml style review — readability and expressiveness


Scope: all of `core/lib/` and `core/bin/main.ml` (~5,500 lines), reviewed
2026-07-11 against the conventions of well-regarded OCaml codebases (see
"Reference code" at the end). Architecture and security were reviewed
separately in `ocaml-review.md` (since deleted — git history keeps it; its
findings were fixed); this review is only about how the code reads. This doc
is kept because AGENTS.md points here for the house style's rationale and
worked examples.

## Verdict

The code is in better shape than a first skim suggests. Its strengths are the
hard ones to retrofit: every function has a purpose comment, parsing is
strict ("parse, don't validate"), naming is consistent, and `domain.ml` with
its `to_text`/`of_text` companion modules is genuinely exemplary. The
weaknesses are the *easy* kind — mechanical patterns that accumulated without
a shared toolkit — and they cluster into a small number of fixes.

Priority order below; items 1–3 change how the whole codebase reads.

## 1. Adopt ocamlformat (highest leverage, zero risk)

There is no `.ocamlformat`. Every widely admired OCaml codebase (Jane Street,
Mirage/Eio, dune, ocaml-lsp) formats mechanically. Hand-formatting shows in
drifting match indentation (`workflow.ml:231-233`), inconsistent record
layouts, and long lines. One file fixes it forever:

```
profile = default
version = 0.27.0
```

Then `dune build @fmt --auto-promote` once, and formatting stops being a
review topic.

## 2. One shared Result syntax — kill the match pyramids

Four modules privately define `let ( let* ) = Result.bind`; `frontmatter.ml`
uses explicit `Result.bind` callbacks; `main.ml` uses *neither* and pays for
it. `save_schedule` (main.ml:907) nests five `match ... | Error m -> ... | Ok x ->`
levels deep. Compare:

```ocaml
(* current shape (abridged) *)
match trigger_of_json ~existing j with
| Error m -> validation_error m
| Ok trigger -> (
    match rec_result with
    | Error m -> validation_error m
    | Ok recurrence -> (
        match Run_mode.of_text (Dto.to_str (Dto.member "mode" j)) with
        | Error m -> validation_error m
        | Ok mode -> ...))
```

```ocaml
(* with let* in scope *)
let result =
  let* trigger = trigger_of_json ~existing j in
  let* recurrence = recurrence_of_json_or_cron ~trigger j in
  let* mode = Run_mode.of_text (Dto.to_str (Dto.member "mode" j)) in
  ...
```

Fix: a single `lib/syntax.ml` (or extend `json.ml`) exporting `let*`/`let+`
for `result`, plus one `traverse : ('a -> ('b, 'e) result) -> 'a list ->
('b list, 'e) result`. The hand-rolled recursions `parse_all`
(workflow.ml:315), the tool-option `fold` (workflow.ml:255), and
`check_references` all become one-liners over it. `containers`' `CCResult`
and Eio's pervasive `let*` show the target shape.

## 3. workflow.ml: extract the `{{...}}` scanner (written 3×)

`placeholders`, `render`, and `command_of_template` each hand-roll the same
inner loop (`find` the closing `}}`, slice, recurse) — ~70 duplicated lines
and three places for a lexing bug to hide. Extract one segmenter:

```ocaml
type segment = Text of string | Placeholder of string
val segments : string -> segment list
```

Then: `placeholders` = `List.filter_map`, `render` = `List.iter` into a
Buffer, `command_of_template` = a fold that tags provenance per segment. The
provenance tracking also simplifies: per-*segment* origin instead of the
current per-*character* `origins` ref list + array.

## 4. Use stdlib combinators where matches spell them out

Recurring patterns with one-call replacements:

| Current | Replace with |
|---|---|
| `match x with Some o -> o \| None -> ""` (dto.ml ×4) | `Option.value ~default:"" x` (already used at dto.ml:129 — be consistent) |
| `match x with Some c -> `String c \| None -> `Null` (×5) | one `json_opt : string option -> Yojson.Safe.t` helper |
| `List.map (fun s -> `String s) xs` (×6) | one `json_strings` helper |
| `starts` / `chop` hand-rolled (workflow.ml:236-239) | `String.starts_with ~prefix` + one shared `chop_prefix` |
| step-line `Printf` duplicated (dto.ml:106 and :283) | one `step_line` function |
| `one_line` defined twice (workflow.ml:356, schedule.ml:146) | share it |
| O(n²) duplicate check (workflow.ml:321, frontmatter.ml:44) | sort + compare adjacent, or a fold over a seen-list |

None are bugs; all are friction. A ~30-line addition to the existing
`json.ml` (or a small `util.ml`) absorbs them.

## 5. Small naming and expression nits

- `private_kind_label` (evaluator.ml:43) — `private` is a C#-ism here; call it
  `kind_label`.
- `let* r = r in` (schedule.ml:71) — restructure so the bind happens once.
- `Money.(state'.remaining > Money.zero)` (delegation.ml:137) — inside
  `Money.(...)` write `zero`, not `Money.zero`.
- `Routing.decide` is computed twice per run (delegation.ml:119 and :147) —
  bind the decision once; the second call re-derives what the first knew.
- delegation.ml's `attempt` builds four near-identical `step` records — a
  `mk_step ?output ?cost ~note kind model outcome` constructor reads better.

## 6. Interfaces: add .mli to the pure "library" modules

3 of 25 modules have interfaces (store, security, sandbox — added during the
remediation). In the best OCaml code the `.mli` is where the documentation
lives (Bünzli's `ptime.mli` is the canonical example — already in our deps;
read it once and the appeal is obvious). Recommended next: `workflow`,
`recurrence`, `cron`, `frontmatter`, `delegation`, `evaluator`,
`command_safety`, `resource_check` — all pure, all stable. Skip `domain`/
`dto` (type-heavy re-export surfaces; an .mli would be a copy).

## 7. main.ml is a 1,578-line monolith (structural, do last)

It contains six separable concerns (its own section headers say so):
OpenRouter HTTP client, tool-runner assembly, webhook crypto, scheduler
fiber, daemon supervisor, router + bootstrap. Each section is fine
internally; the file is simply six modules living in one. Mechanical split,
no behavior change: `bin/openrouter_http.ml`, `bin/webhook_auth.ml`,
`bin/scheduler.ml`, `bin/supervisor.ml`, `bin/router.ml`, leaving `main.ml`
as ~100 lines of bootstrap. Do this after 1–2 so the moves are clean diffs.

## What NOT to change

- `domain.ml` — model file; leave as the template for new code.
- The injected-dependency seams (`chat_client`, `tool_runner`, `git_hook`) —
  this is the right OCaml idiom (records/functions over functors here).
- The comment density — unusually good; keep the standard.
- `store.ml`'s length — it is one cohesive concern with an .mli contract;
  splitting it would scatter the single-writer invariant.

## Reference code to emulate

- **`ptime`** (Daniel Bünzli) — already a dependency. The `.mli`-first,
  small-total-function style; read `ptime.mli` for documentation voice.
  Same author: `cmdliner`, `fmt`, `logs` — the high-water mark for
  stdlib-only readability.
- **`eio`** (already a dependency) — modern direct-style code, pervasive
  `let*`, capability-passing; its `.mli` docs are the standard for
  explaining invariants.
- **`containers`** (`CCResult`, `CCList`) — the combinator vocabulary worth
  copying locally (`traverse`, `map_l`) without taking the dependency.
- **Jane Street style guide** (opensource.janestreet.com/standards) — naming
  and formatting norms; principles carry even though we use the stdlib, not
  Base.
- **Real World OCaml**, ch. "Error Handling" — the Result-plumbing patterns
  item 2 applies.

## Suggested execution order

| Phase | Items | Size | Risk |
|---|---|---|---|
| 1 | ocamlformat + shared `let*`/`traverse` syntax module | small | none (mechanical + tests) |
| 2 | combinator/helper dedup (item 4) + nits (item 5) | small | none |
| 3 | workflow.ml segmenter (item 3) + main.ml `save_schedule` flattening | medium | low (unit-tested paths) |
| 4 | .mli for the eight pure modules (item 6) | medium | none |
| 5 | main.ml split (item 7) | medium | low |

Each phase leaves the tree green (`dune build` warnings-as-errors + 153
tests) and commits separately.
