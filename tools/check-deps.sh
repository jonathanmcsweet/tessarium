#!/usr/bin/env bash
# Every library a dune file names must be declared in dune-project.
#
# A dependency satisfied only transitively is satisfied by accident. It works
# until the package that happened to pull it drops it, and in the meantime a
# fresh `opam install . --deps-only` builds a switch this project cannot
# compile in. That is invisible to CI, whose switch is restored from cache and
# therefore still holds whatever an earlier solve happened to install -- so
# the person who finds it is someone setting up from nothing, which is the
# worst audience for it.
#
# The comparison is opam-dune-lint's: dune's own view of each stanza's
# external libraries against the generated tessarium.opam, with the
# library-to-package mapping resolved from real metadata rather than
# guessed from the name. A hand-rolled version of this check lived here
# once, parsing the S-expressions with regexes and mapping sub-libraries
# by splitting on the first dot -- which is wrong for any library whose
# package carries a different name (findlib lives in ocamlfind). The
# ecosystem's own tool is the authority on its own file formats.
#
# tools/setup.sh installs the tool; it is not in tessarium.opam because it
# exists to check that file.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if ! command -v opam-dune-lint >/dev/null 2>&1; then
  echo "    error: opam-dune-lint is not on PATH" >&2
  echo "    run tools/setup.sh, or: opam install opam-dune-lint" >&2
  exit 1
fi

# The opam file is generated from dune-project; regenerate before judging it,
# or the check would compare against whatever the last build left behind.
dune build tessarium.opam

opam-dune-lint
