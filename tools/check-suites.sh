#!/usr/bin/env bash
# Assert that every test suite actually ran.
#
# This exists because of a real failure: the differential check redirected its
# output to a file, which made it a build target, and the build system caches
# targets — so it stopped running and everything stayed green. A suite that
# quietly stops running is worse than one that fails, because nothing says so.
#
# Grepping the output for each suite's own report line is crude and catches
# exactly that: if a suite did not run, its line is absent.

set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# name : the pattern its report line must match
#
# Match on something the suite says about ITSELF, never on how many checks it
# contains. A pattern like "^58 checks" makes adding a test indistinguishable
# from a suite that stopped running, which is the exact failure this script
# exists to catch.
suites=(
  "native vectors|all vectors reproduce"
  "js_of_ocaml bundle|js_of_ocaml bundle: [0-9]+ checks"
  "independent js implementation|checks passed, 0 failed"
  "server decisions|server decisions hold"
  "coverage answers|coverage answers (hold|FAILED)"
  "tile set|tile set (holds|FAILED)"
  "region files|regions are files"
  "bundle seeding|bundle seeding (holds|FAILED)"
  "shipped word lookup|the shipped word lookup agrees with the proved one"
  "runtime laws|proved laws hold at runtime over [1-9][0-9]*"
  "pmtiles round-trip|pmtiles round-trips"
  "vector regeneration|vectors reproduce exactly from the verified core"
  "differential sweep|[1-9][0-9]* points checked"
  "C core side by side|agree on [1-9][0-9]* side-by-side checks"
  "wasm core|wasm core: [1-9][0-9]* points checked, 0 disagreements expected, 0 found"
  "argon2 kdf|argon2 kdf: wasm and noble agree on [1-9][0-9]* derivations"
  "argon2 known answers|argon2id answers for [1-9][0-9]* known-answer checks"
  "browser worker|worker differential: [1-9][0-9]* checks, 0 failures"
)

out="$(dune build @runtest --force 2>&1)"
status=$?
echo "$out"

echo
echo "==> suite presence"
missing=0
for entry in "${suites[@]}"; do
  name="${entry%%|*}"
  pattern="${entry#*|}"
  if printf '%s' "$out" | grep -qE "$pattern"; then
    printf '    ok   %s\n' "$name"
  else
    printf '    MISSING  %s\n' "$name"
    missing=$((missing + 1))
  fi
done

# A suite reporting failures is caught by dune's exit status; this only adds
# the case dune cannot see, which is a suite that produced no output at all.
if [ "$missing" -gt 0 ]; then
  echo
  echo "error: $missing suite(s) produced no output — they did not run." >&2
  echo "       Check for a dune rule that declares a target: those are cached" >&2
  echo "       and will not re-run under --force." >&2
  exit 1
fi

if [ "$status" -ne 0 ]; then
  echo "error: a suite reported failures" >&2
  exit "$status"
fi

echo "    all $((${#suites[@]})) dune suites ran"
echo
echo "note: the browser end-to-end suite is NOT run here -- it needs a live"
echo "      server and Playwright. Run 'make test' for everything, or"
echo "      'make test-ui' for that suite alone. A grid change that stales a"
echo "      constant in it will not show up until you do."
