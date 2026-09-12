#!/usr/bin/env bash
# How deep a PMTiles archive actually goes.
#
#   tools/archive-max-zoom.sh FILE     prints one integer
#
# Asked by the two places that care whether an overview on disk is the one
# this project ships: tools/fetch-basemap.sh, deciding whether the file it
# found is deep enough to keep, and tools/stage-bundle.sh, refusing to build
# a package around a source that cannot reach the shipped depth.
#
# The answer comes from the archive's own header, through the fetcher's
# --describe. The alternative was reading the byte at the offset the PMTiles
# spec puts max_zoom at, which would give this layout a second home in a
# shell script -- and the first home, ocaml/pmtiles, is the one that gets
# updated when the format moves.
#
# Silent on failure, because both callers treat "cannot tell" as "not deep
# enough" and say so in their own words.

set -euo pipefail

file="${1:-}"
if [ -z "$file" ]; then
  echo "usage: tools/archive-max-zoom.sh FILE" >&2
  exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

[ -f "$file" ] || exit 1

fetcher="_build/default/ocaml/pmtiles/bin/main.exe"
if [ ! -x "$fetcher" ]; then
  dune build ocaml/pmtiles/bin/main.exe >/dev/null 2>&1 || exit 1
fi

# "  zooms 0-6, 341 tiles, 5.7 MB" -- the second number.
depth="$("$fetcher" "$file" --describe 2>/dev/null \
  | sed -n 's/^ *zooms [0-9]\{1,\}-\([0-9]\{1,\}\),.*/\1/p' | head -1)"

[ -n "$depth" ] || exit 1
printf '%s\n' "$depth"
