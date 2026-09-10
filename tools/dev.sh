#!/usr/bin/env bash
# Bring the whole stack up for development, and take it back down together.
#
# `pnpm run dev` inside ui/ starts Vite alone, which is not enough to use the
# app: Vite proxies /api, /basemap, /healthz and both wasm modules to the OCaml
# server, because the wasm is served by that binary rather than sitting in
# public/. Without the server the gate renders and the phrase validates, but
# opening the map fails -- the KDF module 502s, so no key is derived. This
# starts both halves and stops both.
#
# Everything it needs is installed and compiled first, by tools/bootstrap.sh:
# from a bare clone this one command is the whole story. Warm, that costs about
# a second.
#
# Vite serves the UI here, not ocaml/server/ui_dist, so edits reload.
# `make run` is the other shape: one binary serving the built UI, which is what
# ships.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

port="${PORT:-7373}"
ui_port="${TESSARIUM_UI_PORT:-7380}"

# Neither toolchain is on PATH by default -- see `make env`. Applying them here
# lets this run from a shell that has not sourced it, which is the shell most
# people already have open.
# shellcheck disable=SC1091
. tools/env.sh

# The toolchain, node modules, the basemap the packages ship, and the compile.
# Each step is skipped when it is already done. A fresh checkout has none of
# them, and used to meet `pnpm run dev` with "dune: not found" -- or, worse,
# with a running app whose map could not open.
tools/bootstrap.sh

up() { curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$1/healthz" 2>/dev/null; }

server_pid=""
# Kill only what this script started, by pid. Never by pattern: `pkill -f`
# matches its own command line as readily as the server's, which is a good way
# to kill the wrong process.
cleanup() {
  if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
    echo "dev: stopping the server on $port"
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

if up "$port"; then
  # Someone else's server, so leave it alone on the way out too.
  echo "dev: a server is already answering on $port; using it"
else
  echo "dev: starting the server on $port"
  # --ui wasm, not the default ui/dist. Vite serves the UI in development, so
  # the only files wanted from this half are core.wasm and argon2.wasm, and
  # wasm/ is where they are committed. The default is a directory `make ui`
  # writes, which a fresh clone has never run: the KDF module 404s, no key is
  # derived, and the gate rejects a phrase that is perfectly good. A binary
  # that HAS had the UI built into it answers from its embedded copy before
  # either directory, so this covers the empty case and changes nothing else.
  #
  # --no-open because the app in development is Vite's port, not this one.
  # Without it the server opens a browser on ITS url, which serves the two
  # wasm modules and nothing else -- a blank page beside the working one.
  ./_build/default/ocaml/server/bin/main.exe \
    --port "$port" --basemap "$(make -s print-basemap-dir)" \
    --ui wasm --no-open &
  server_pid=$!

  for _ in $(seq 1 40); do
    up "$port" && break
    kill -0 "$server_pid" 2>/dev/null || { echo "dev: the server exited" >&2; exit 1; }
    sleep 0.25
  done
  up "$port" || { echo "dev: the server never became ready on $port" >&2; exit 1; }
fi

echo "dev: starting Vite on $ui_port -- http://localhost:$ui_port"
cd ui
# dev:ui, not dev: ui/'s `dev` is this script, so `pnpm run dev` brings the
# stack up from whichever directory someone is standing in. Calling `dev` here
# would recurse.
TESSARIUM_UI_PORT="$ui_port" TESSARIUM_SERVER="http://127.0.0.1:$port" pnpm run dev:ui
