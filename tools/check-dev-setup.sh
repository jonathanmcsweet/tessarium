#!/usr/bin/env bash
# `pnpm run dev` has to work on a machine that has just cloned this.
#
# It did not. tools/dev.sh built the OCaml and started Vite, and assumed
# everything else: ui/node_modules, which nothing but `make ui` installs; the
# vendored F* support library, without which `dune build` cannot link; and
# core.wasm, which the server serves out of the directory `make ui` writes, so
# on a fresh clone the KDF module 404s and a perfectly good phrase is refused
# with no clue why. Three steps a newcomer does not know to take, one of which
# fails silently.
#
# So the scripts are exercised rather than described. tools/bootstrap.sh and
# tools/dev.sh run in a temporary directory against stubs -- setup.sh, pnpm,
# make, dune, curl and the server binary -- which record how they were called.
# That is what makes the interesting cases reachable: "the toolchain is missing
# and cannot be installed" and "the clone has no node_modules" are otherwise
# only reachable by breaking the machine running this.

set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

checks=0
failures=0
# Every check is a name and a status, 0 for pass -- the shell's own convention,
# so `check "..." "$?"` reads off the command above it.
check() {
  checks=$((checks + 1))
  if [ "$2" != "0" ]; then
    failures=$((failures + 1))
    echo "  FAIL  $1"
  fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tools" "$work/bin" "$work/ui" \
  "$work/_build/default/ocaml/server/bin"

cp tools/bootstrap.sh tools/dev.sh "$work/tools/"
echo '{ "name": "root" }'  > "$work/package.json"
echo '{ "name": "ui" }'    > "$work/ui/package.json"

# The toolchain, minus the toolchain. STUB_SETUP says whether --check passes,
# and `fixable` is the ordinary case: the first --check fails, the install runs,
# the next --check passes.
cat > "$work/tools/setup.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> setup-calls.log
case "${STUB_SETUP:-ok}" in
  ok) echo "    ok   everything"; exit 0 ;;
  fixable)
    if [ "${1:-}" = "--check" ] && [ -f setup-installed ]; then exit 0; fi
    if [ "${1:-}" = "--check" ]; then echo "    miss vendored"; exit 1; fi
    touch setup-installed; exit 0 ;;
  broken)
    [ "${1:-}" = "--check" ] && { echo "    miss opam is not installed"; exit 1; }
    exit 0 ;;
esac
STUB

# PATH is the whole point of these three: bootstrap.sh must not reach the real
# ones, and each records what it was asked to do.
cat > "$work/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
pwd >> "$STUB_LOG_DIR/pnpm-calls.log"
echo "$*" >> "$STUB_LOG_DIR/pnpm-args.log"
STUB

cat > "$work/bin/make" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG_DIR/make-calls.log"
# The real Makefile owns where maps live and where the stamp is; both
# bootstrap.sh and dev.sh ask it rather than carrying a second copy of the
# path, so the stub has to answer.
case "$*" in
  *print-basemap-stamp*) echo "$STUB_LOG_DIR/store/.fetched" ;;
  *print-basemap-dir*)   echo "$STUB_LOG_DIR/store" ;;
esac
STUB

cat > "$work/bin/dune" <<'STUB'
#!/usr/bin/env bash
echo "build" >> "$STUB_LOG_DIR/order.log"
echo "$*" >> "$STUB_LOG_DIR/dune-calls.log"
STUB

# Answers only once the server stub has actually started, so dev.sh's wait loop
# is exercised rather than short-circuited.
cat > "$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -f "$STUB_LOG_DIR/server.argv" ]
STUB

cat > "$work/_build/default/ocaml/server/bin/main.exe" <<'STUB'
#!/usr/bin/env bash
echo "$*" > "$STUB_LOG_DIR/server.argv"
sleep 30
STUB

# env.sh is where the real PATH is decided, which is exactly what this must not
# have: a stub that reached the real toolchain would test the machine.
: > "$work/tools/env.sh"

chmod +x "$work/tools/setup.sh" "$work/bin/"* \
  "$work/_build/default/ocaml/server/bin/main.exe"

export STUB_LOG_DIR="$work"
export PATH="$work/bin:$PATH"
# The basemap has its own suite (tools/check-basemap-target.sh) and its own
# network; here `make basemap` only has to be asked for.
export TESSARIUM_NO_BASEMAP=1

cd "$work"
reset() { rm -f ./*-calls.log ./*-args.log order.log setup-installed server.argv; }

# ---------------------------------------------------------------- --check

reset
out="$(STUB_SETUP=ok tools/bootstrap.sh --check 2>&1)"; status=$?
check "--check fails when node_modules are missing" \
  "$([ "$status" != "0" ] && echo 0 || echo 1)"
check "--check names the package that is missing" \
  "$(echo "$out" | grep -q "ui/node_modules" && echo 0 || echo 1)"
check "--check changes nothing" \
  "$([ ! -f pnpm-calls.log ] && [ ! -f dune-calls.log ] && echo 0 || echo 1)"

mkdir -p node_modules ui/node_modules store && : > store/.fetched
reset
STUB_SETUP=ok tools/bootstrap.sh --check >/dev/null 2>&1
check "--check passes once everything is present" "$?"
check "the basemap stamp is asked of the Makefile, not spelled again here" \
  "$(grep -q "print-basemap-stamp" make-calls.log && echo 0 || echo 1)"
rm -rf node_modules ui/node_modules

# ------------------------------------------------------------------ install

reset
STUB_SETUP=ok tools/bootstrap.sh >/dev/null 2>&1
check "a bootstrap with a healthy toolchain succeeds" "$?"
# The bug this suite exists for: `make ui` installed ui/node_modules and dev
# never did, so Vite was started against a directory that had no Vite in it.
check "both packages are installed, root and ui" \
  "$(grep -qx "$work" pnpm-calls.log && grep -qx "$work/ui" pnpm-calls.log \
     && echo 0 || echo 1)"
check "the install is frozen to the lockfile" \
  "$(grep -q -- "--frozen-lockfile" pnpm-args.log && echo 0 || echo 1)"
check "the basemap is asked of make, not fetched here" \
  "$(grep -qx "basemap" make-calls.log && echo 0 || echo 1)"
check "the core is compiled" \
  "$([ -f dune-calls.log ] && echo 0 || echo 1)"
check "a healthy toolchain is not reinstalled" \
  "$([ "$(grep -cx -- "--check" setup-calls.log)" = "1" ] \
     && [ "$(wc -l < setup-calls.log)" = "1" ] && echo 0 || echo 1)"

reset
STUB_SETUP=fixable tools/bootstrap.sh >/dev/null 2>&1
check "a missing toolchain is installed, then rechecked" \
  "$([ "$?" = "0" ] && [ "$(wc -l < setup-calls.log)" = "3" ] && echo 0 || echo 1)"

# A toolchain that cannot be fixed -- opam absent, say -- must stop here. It
# used to carry on into `dune build` and fail with "Unbound module Prims",
# which is the truth about a missing support library and tells nobody anything.
reset
out="$(STUB_SETUP=broken tools/bootstrap.sh 2>&1)"; status=$?
check "an unfixable toolchain stops the bootstrap" \
  "$([ "$status" != "0" ] && echo 0 || echo 1)"
check "and says so, rather than failing later in the compiler" \
  "$(echo "$out" | grep -q "still incomplete" && echo 0 || echo 1)"
check "and does not compile" "$([ ! -f dune-calls.log ] && echo 0 || echo 1)"

# ------------------------------------------------------------------ -- CMD

reset
STUB_SETUP=ok tools/bootstrap.sh -- sh -c 'echo cmd >> order.log' >/dev/null 2>&1
check "-- runs the command it is given" \
  "$(grep -qx "cmd" order.log && echo 0 || echo 1)"
check "-- runs it after the build, not before" \
  "$([ "$(tr '\n' ' ' < order.log)" = "build cmd " ] && echo 0 || echo 1)"

reset
STUB_SETUP=ok tools/bootstrap.sh -- sh -c 'exit 3' >/dev/null 2>&1
check "-- passes the command's exit status back" \
  "$([ "$?" = "3" ] && echo 0 || echo 1)"

# ------------------------------------------------------------------- dev.sh

# bootstrap.sh has its own checks above; here it only has to be called.
cat > tools/bootstrap.sh <<'STUB'
#!/usr/bin/env bash
echo "bootstrap" >> "$STUB_LOG_DIR/order.log"
STUB
chmod +x tools/bootstrap.sh

reset
PORT=7391 TESSARIUM_UI_PORT=7392 timeout 30 tools/dev.sh >/dev/null 2>&1
check "dev brings the stack up and comes back down" "$?"
check "dev bootstraps before it starts anything" \
  "$(head -1 order.log | grep -qx "bootstrap" && echo 0 || echo 1)"
# The 404 that made a fresh clone reject a good phrase: the wasm the browser's
# worker needs is served from wasm/, which is committed, not from the directory
# `make ui` writes.
check "the server serves the committed wasm" \
  "$(grep -q -- "--ui wasm" server.argv && echo 0 || echo 1)"
check "the server opens no browser -- the app is Vite's port" \
  "$(grep -q -- "--no-open" server.argv && echo 0 || echo 1)"
# Downloaded maps outlive the checkout, so dev has to serve the same store an
# installed copy uses -- and ask the Makefile where that is rather than
# spelling a path of its own.
check "the server is pointed at the map store, named by the Makefile" \
  "$(grep -q -- "--basemap $work/store" server.argv && echo 0 || echo 1)"
check "Vite is started, and not by recursing into this script" \
  "$(grep -qx "run dev:ui" pnpm-args.log && echo 0 || echo 1)"
check "Vite is started in ui/" "$(grep -qx "$work/ui" pnpm-calls.log && echo 0 || echo 1)"
check "the server is stopped on the way out" \
  "$([ -z "$(pgrep -f "main.exe --port 7391" || true)" ] && echo 0 || echo 1)"

echo
echo "dev setup: $checks checks, $failures failures"
[ "$failures" -eq 0 ]
