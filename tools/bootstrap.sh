#!/usr/bin/env bash
# Everything a bare checkout needs before the app can run, in one command:
# the toolchain, node modules for both packages, a basemap, and the compile.
#
#   tools/bootstrap.sh              install what is missing, then build
#   tools/bootstrap.sh --check      report what is missing, change nothing
#   tools/bootstrap.sh -- CMD...    do that, then run CMD with the toolchain
#                                   on PATH -- which is what the root
#                                   package.json's scripts are
#
# Every step asks whether it has already been done, so this is cheap to put in
# front of something else -- which is what tools/dev.sh does. That is the point:
# `pnpm run dev` on a fresh clone is the whole story rather than the last of
# five steps, and the four before it are the ones a newcomer does not know to
# take. Warm, it costs about a second.
#
# What it does NOT do: verify the F* (`make verify`), re-extract, or build the
# UI into the server binary (`make ui && make build`). Development serves the
# UI from Vite and the core from committed artifacts; those three are for
# changing the proofs and for shipping.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

check_only=false
run_after=false
case "${1:-}" in
  --check) check_only=true ;;
  --) run_after=true; shift; [ $# -gt 0 ] || { echo "bootstrap: -- needs a command" >&2; exit 2; } ;;
  "") ;;
  *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()  { printf '    \033[32mok\033[0m   %s\n' "$1"; }
no()  { printf '    \033[31mmiss\033[0m %s\n' "$1"; }

missing=0

# shellcheck disable=SC1091
. tools/env.sh

# tools/setup.sh owns every question about the toolchain -- F*, the opam
# switch, its dependencies, node, and the vendored F* support library that
# `dune build` cannot link without. Asked here rather than restated: a second
# list of prerequisites is a list that goes stale.
say "toolchain"
if report="$(tools/setup.sh --check 2>&1)"; then
  ok "F*, opam switch, dependencies, node, F* support library"
else
  printf '%s\n' "$report"
  if $check_only; then
    missing=$((missing + 1))
  else
    say "installing the toolchain -- this is the slow one, and it runs once"
    tools/setup.sh
    # setup.sh may have just installed node; this shell's PATH predates that.
    # shellcheck disable=SC1091
    . tools/env.sh
    if ! report="$(tools/setup.sh --check 2>&1)"; then
      printf '%s\n' "$report"
      echo "bootstrap: the toolchain is still incomplete -- see above" >&2
      exit 1
    fi
  fi
fi

# Two packages: ui/ is the app, and the root holds @noble/hashes for the
# differential oracle. Both are pinned, so both install frozen.
#
# pnpm here is corepack's shim, which fetches the version package.json pins the
# first time it sees a new one -- and asks before it does. Nothing can answer
# that from a script, so it is answered in advance.
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
say "node modules"
$check_only || command -v pnpm >/dev/null 2>&1 || {
  echo "bootstrap: pnpm is not on PATH, and tools/setup.sh reported it was" >&2
  exit 1
}
for pkg in . ui; do
  if $check_only; then
    if [ -d "$pkg/node_modules" ]; then
      ok "$pkg/node_modules"
    else
      no "$pkg/node_modules"; missing=$((missing + 1))
    fi
  else
    (cd "$pkg" && pnpm install --frozen-lockfile)
  fi
done

# Through `make basemap`, which owns what a missing, partial or deliberately
# skipped map means. TESSARIUM_NO_BASEMAP=1 skips it.
say "basemap"
if $check_only; then
  # The stamp's path comes from the Makefile, which owns what a complete map
  # is and when a half-finished fetch may be recorded as one.
  if [ -f "$(make -s print-basemap-stamp)" ]; then
    ok "basemap"
  else
    no "basemap (make basemap)"; missing=$((missing + 1))
  fi
else
  make basemap
fi

say "compile"
if $check_only; then
  echo "    not checked here -- dune decides that in about a second"
else
  dune build
  ok "the core, the server and the js bundle"
fi

if $check_only; then
  say "result"
  if [ "$missing" -eq 0 ]; then
    echo "    ready. pnpm run dev"
  else
    echo "    $missing missing. run tools/bootstrap.sh to install."
    exit 1
  fi
else
  say "ready"
  if $run_after; then exec "$@"; fi
fi
