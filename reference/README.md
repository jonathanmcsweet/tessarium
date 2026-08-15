# Scaffolding — temporary, outranked by F\*

This is a hand-written Python implementation of the algorithm. It is **not**
part of the architecture and should not be treated as one.

## Why it exists

The band table and the address-space arithmetic needed validating before any
F\* could be written, and the F\* toolchain was not available at the time. This
directory was the fastest way to find out whether the design closed.

It earned its keep. Building it caught three wrong numbers in the design
(target resolution, Feistel factor pair, an int64 claim) and one real bug — the
floor/ceiling inversion at cell edges, which produced no crash and no error,
just wrong answers in a one-nanodegree sliver at every cell boundary. Details
in `../roadmap-progress.md`.

## Why it should go

The architecture is one proved F\* source with several extraction targets,
specifically so that no platform reimplements the algorithm by hand. Two
hand-written copies currently exist (this and `../js/`). That is the failure
mode the project is designed to prevent, sitting in the repo.

Worse: `gen_vectors.py` produces `../vectors/vectors.json`, and every future
implementation is checked against those vectors. So this Python is currently
the de facto source of truth for the whole system. It should be the F\*.

## Rules while it exists

- **Do not add features here.** Bug fixes only, and only to keep it agreeing
  with the vectors.
- **Do not cite it as a specification.** `../fstar/` is the specification, even
  though it is not yet proved.
- **If this and the F\* disagree, the F\* is right** and this gets fixed or
  deleted.

## Removal

1. Implement the F\* modules against the interfaces in `../fstar/`.
2. Regenerate `../vectors/vectors.json` from the F\* spec. The file contents
   should not change; if they do, something is wrong and that is the whole
   point of doing it in this order.
3. Delete this directory.

Tracked in `../roadmap.md` under Phase 4.

## Running it meanwhile

```
cd reference
python3 test_reference.py     # property tests
python3 gen_vectors.py        # regenerate vectors (will be removed)
```
