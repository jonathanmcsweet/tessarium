#!/usr/bin/env bash
# Bring the whole stack up for development, and take it back down together.
#
# `pnpm run dev` inside ui/ starts Vite alone, which is not enough to use the
# app: Vite proxies /api, /basemap, /healthz and both wasm modules to the
# OCaml server, because the wasm is embedded in that binary rather than
# sitting in public/. Without the server the gate renders, the phrase
# validates, and opening the map fails -- the key cannot be derived because
# the KDF module 502s. This starts both halves and stops both.
#
# The UI is served by Vite here, not from ocaml/server/ui_dist, so edits
# reload. `make run` is the other shape: one binary serving the built UI,
# which is what ships.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

port="${PORT:-7373}"
ui_port="${TESSARIUM_UI_PORT:-7380}"

# Neither toolchain is on PATH by default -- see `make env`. Applying them
# here is what lets this run from a shell that has not sourced it, which is
# the shell most people already have open.
if ! command -v dune >/dev/null 2>&1 && command -v opam >/dev/null 2>&1; then
  eval "$(opam env --switch=tessarium)" || true
fi
if ! command -v pnpm >/dev/null 2>&1 && [ -s "$HOME/.nvm/nvm.sh" ]; then
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
fi

for tool in dune pnpm; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "dev: $tool not found. Run tools/setup.sh, or eval \"\$(make env)\"." >&2
    exit 1
  }
done

# The .deb, .rpm and AppImage all ship a world overview, so a fresh install
# opens on a map. A repo checkout ships none -- basemap/ is not in git -- so
# `make dev` greeted you with blank grid and "No basemap found", which is the
# first thing a new contributor sees and the one state the packages never
# have. Fetch the same overview packaging fetches, once: zoom 4, ~6 MB,
# countries and coastlines. Regions on top of it stay a deliberate choice.
#
# TESSARIUM_NO_BASEMAP=1 skips it -- for working offline, or for testing the
# empty state on purpose.
if [ ! -f basemap/world.pmtiles ] && [ "${TESSARIUM_NO_BASEMAP:-}" != "1" ]; then
  echo "dev: no world overview yet; fetching the one the packages ship (~6 MB)"
  tools/fetch-basemap.sh -z "" \
    || echo "dev: basemap fetch failed -- carrying on without one" >&2
fi

up() { curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$1/healthz" 2>/dev/null; }

server_pid=""
# Kill only what this script started, by pid. Never by pattern: `pkill -f`
# matches the pattern against its own command line as readily as the
# server's, which is a good way to kill the wrong thing.
cleanup() {
  if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
    echo "dev: stopping the server on $port"
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

echo "dev: building the core and the server"
dune build

if up "$port"; then
  # Someone else's server, so leave it alone on the way out too.
  echo "dev: a server is already answering on $port; using it"
else
  mkdir -p basemap
  echo "dev: starting the server on $port"
  ./_build/default/ocaml/server/bin/main.exe --port "$port" --basemap basemap &
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
# dev:ui, not dev: ui/'s `dev` is this script, so that `pnpm run dev` brings
# the stack up from whichever directory someone is standing in. Calling it
# here would recurse.
TESSARIUM_UI_PORT="$ui_port" TESSARIUM_SERVER="http://127.0.0.1:$port" pnpm run dev:ui
