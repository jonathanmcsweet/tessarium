#!/usr/bin/env bash
# `make run` has to open the app on a machine with no network, and must never
# mistake a half-finished download for a finished one.
#
# Both were real bugs, invisible to every other suite. `run` depended on the
# file target basemap/world.pmtiles, whose recipe was an unguarded
# `tools/fetch-basemap.sh` under `set -euo pipefail`: an offline `make run`
# aborted instead of opening on the documented empty map with its download
# banner. And because the fetcher writes the overview BEFORE the glyphs and
# sprites, a fetch that died on the assets tarball left a file that satisfied
# that target forever -- every later `make run` skipped the recipe and served a
# map whose labels 404, drawing as unlabelled grey shapes with nothing saying
# why.
#
# So the target is exercised rather than described. A copy of the real Makefile
# runs in a temporary directory against three stubs -- the fetcher, `dune`, and
# the server binary. That is what makes the failing cases reachable: a check
# that needed a dead network could only be run by someone who had one, and one
# that needed a real server would be the browser suite over again.

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
mkdir -p "$work/tools" "$work/bin" "$work/_build/default/ocaml/server/bin"
cp Makefile "$work/Makefile"
# The real one, not a stub: where maps live is the thing under test here, and
# a stubbed answer would let the Makefile and the scripts disagree about it
# unnoticed. TESSARIUM_BASEMAP sends it somewhere disposable, which is also
# the override a person uses for a second store.
cp tools/basemap-dir.sh "$work/tools/basemap-dir.sh"
export TESSARIUM_BASEMAP="$work/store"

# The fetcher, minus the network. It records every call and writes what the
# real one writes at the point STUB_MODE says it stops. The overview lands
# before the assets, so "the overview is here" and "the map is usable" are two
# different questions.
cat > "$work/tools/fetch-basemap.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# The depth the packages ship, which the Makefile asks for before it does
# anything else. Answered without recording a call: this is a question, not a
# fetch.
if [ "${1:-}" = "--print-world-zoom" ]; then
  printf '%s\n' "${STUB_SHIP_ZOOM:-6}"
  exit 0
fi
echo "called" >> calls.log
# Writes where it is TOLD to. A stub that wrote to ./basemap regardless would
# pass whether or not the recipe named the store, which is the one thing this
# file now has to be sure of.
out=""
while getopts "b:z:o:s:W:h" opt; do
  case "$opt" in o) out="$OPTARG" ;; *) ;; esac
done
[ -n "$out" ] || { echo "stub: no -o given" >&2; exit 2; }
echo "$out" >> out.log
mkdir -p "$out"
# A stub archive is its own depth, in plain text, so the depth check has
# something honest to read and a shallow store is a fixture rather than a
# real 43 MB download.
case "${STUB_MODE:-ok}" in
  ok)
    echo "${STUB_SHIP_ZOOM:-6}" > "$out/world.pmtiles"
    mkdir -p "$out/fonts" "$out/sprites"
    ;;
  assets-fail)
    echo "${STUB_SHIP_ZOOM:-6}" > "$out/world.pmtiles"
    echo "stub: the assets tarball failed" >&2
    exit 1
    ;;
  offline)
    echo "stub: could not resolve host" >&2
    exit 6
    ;;
esac
STUB

# How deep an archive goes. The real one reads a PMTiles header through the
# fetcher; the stub reads the number the fetcher stub wrote, and fails the
# same way on a file that is not one -- which is what "cannot tell" has to
# look like for the Makefile's own default to be exercised.
cat > "$work/tools/archive-max-zoom.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ -f "${1:-}" ] || exit 1
depth="$(head -1 "$1")"
case "$depth" in
  '' | *[!0-9]*) exit 1 ;;
esac
printf '%s\n' "$depth"
STUB

# The compiler and the server. `run` depends on `build`, and what this file
# asks is whether the app STARTS -- so the server stub records that it was
# reached and returns, where the real one would serve until interrupted.
cat > "$work/bin/dune" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$work/_build/default/ocaml/server/bin/main.exe" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> started.log
STUB
chmod +x "$work/tools/fetch-basemap.sh" "$work/tools/archive-max-zoom.sh" \
  "$work/bin/dune" "$work/_build/default/ocaml/server/bin/main.exe"

fresh() {
  rm -rf "$work/store" "$work/basemap" "$work/calls.log" "$work/started.log" \
    "$work/out.log"
}
calls() { [ -f "$work/calls.log" ] && wc -l < "$work/calls.log" || echo 0; }
started() { [ -f "$work/started.log" ]; }
# Asked of the Makefile rather than spelled out here: the stamp is named after
# the depth the packages ship, and a copy of that name in this file would go on
# passing after the depth moved -- against a stamp nothing writes any more.
stamped() {
  [ -f "$(env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL \
    make -C "$work" -s print-basemap-stamp)" ]
}
# The app, as a developer starts it. PATH carries the stub compiler; nothing
# reaches the network or a port. The make variables are dropped because this
# runs inside `make test-core`: a nested make that inherits the parent's
# jobserver warns, or inherits its --dry-run and does nothing -- which would
# leave every check below passing on no evidence.
run() {
  PATH="$work/bin:$PATH" env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL \
    make -C "$work" run >"$work/out.txt" 2>&1
}

# 1. No network at all. The map cannot be had, and that is not a build error:
#    the app opens on the empty state it documents, and says so.
fresh
STUB_MODE=offline run
check "an offline \`make run\` is not a build failure" "$?"
started
check "and the app starts anyway" "$?"
stamped
[ "$?" -ne 0 ]
check "with nothing recorded as fetched" "$?"

# 2. Tried again next time rather than given up on.
before="$(calls)"
STUB_MODE=offline run
check "a failed fetch is retried on the next run" \
  "$([ "$(calls)" -gt "$before" ] && echo 0 || echo 1)"

# 3. The overview arrives and the assets do not -- the case the old file
#    target could not tell from success, because it only looked at the
#    overview.
fresh
STUB_MODE=assets-fail run
check "a half-finished fetch is not a build failure" "$?"
started
check "and the app still starts" "$?"
[ -f "$work/store/world.pmtiles" ]
check "the overview it did get is kept" "$?"
stamped
[ "$?" -ne 0 ]
check "but half a map is not recorded as a map" "$?"

# 4. And the missing half is fetched next time. The old target never did: the
#    overview alone satisfied it forever, so the glyphs stayed missing for the
#    life of the checkout.
before="$(calls)"
STUB_MODE=ok run
check "the missing half is fetched on a later run" \
  "$([ "$(calls)" -gt "$before" ] && echo 0 || echo 1)"
stamped
check "and a whole map is recorded" "$?"

# 5. Once it is whole, it is left alone.
before="$(calls)"
STUB_MODE=offline run
check "a complete map is not re-fetched" \
  "$([ "$(calls)" = "$before" ] && echo 0 || echo 1)"
started
check "and the app starts" "$?"

# 6. The escape hatch tools/dev.sh documents, which now lives in one place.
fresh
TESSARIUM_NO_BASEMAP=1 STUB_MODE=ok run
check "TESSARIUM_NO_BASEMAP=1 starts the app" "$?"
started
check "on an empty map, deliberately" "$?"
check "and fetches nothing" "$([ "$(calls)" = "0" ] && echo 0 || echo 1)"

# 7. A map already on disk is adopted rather than re-fetched -- the flow
#    README documents, where tools/fetch-basemap.sh is run by hand first.
fresh
mkdir -p "$work/store/fonts" "$work/store/sprites"
echo 6 > "$work/store/world.pmtiles"
STUB_MODE=offline run
stamped
check "a map fetched by hand is adopted" "$?"
check "with no call to the fetcher" "$([ "$(calls)" = "0" ] && echo 0 || echo 1)"

# 8. Maps live OUTSIDE the checkout, and the app is pointed at them. A
#    gitignored directory in the tree is deleted by anything that cleans build
#    output, which is how a 666 MB region left this project without a word.
fresh
STUB_MODE=ok run
check "the fetcher is told to write to the store" \
  "$(grep -qx "$work/store" "$work/out.log" 2>/dev/null && echo 0 || echo 1)"
check "and nothing lands in the checkout" \
  "$([ ! -e "$work/basemap" ] && echo 0 || echo 1)"
check "the app is started against the store" \
  "$(grep -q -- "--basemap $work/store" "$work/started.log" && echo 0 || echo 1)"

# 9. A checkout from before the move still has its maps in the tree, and they
#    are hundreds of megabytes someone chose to download. They are MOVED, not
#    re-fetched and not left where the next clean will take them.
fresh
mkdir -p "$work/basemap/fonts" "$work/basemap/sprites"
echo 6 > "$work/basemap/world.pmtiles"
echo "a region" > "$work/basemap/Georgia-2026-08-29-9cd94ba2.pmtiles"
STUB_MODE=offline run
check "an in-tree map is moved rather than re-fetched" \
  "$([ "$(calls)" = "0" ] && echo 0 || echo 1)"
check "the region file arrives in the store" \
  "$([ -f "$work/store/Georgia-2026-08-29-9cd94ba2.pmtiles" ] && echo 0 || echo 1)"
check "and the checkout is left holding no map data" \
  "$([ ! -e "$work/basemap" ] && echo 0 || echo 1)"
stamped
check "the moved map is recorded as complete" "$?"

# 10. The move never overwrites a store that already has a map: two real
#     stores would otherwise merge, silently, in whichever direction ran.
fresh
mkdir -p "$work/store/fonts" "$work/store/sprites"
# Depth first, marker second: the store has to read as a COMPLETE map for this
# case to be about the move at all, and the marker is what says which file
# survived it.
printf '6\nthe store'"'"'s own\n' > "$work/store/world.pmtiles"
mkdir -p "$work/basemap"
printf '6\nthe checkout'"'"'s\n' > "$work/basemap/world.pmtiles"
STUB_MODE=offline run
check "a populated store is not overwritten by an in-tree one" \
  "$(grep -qx "the store's own" "$work/store/world.pmtiles" && echo 0 || echo 1)"
check "and the in-tree copy is left alone rather than deleted" \
  "$([ -f "$work/basemap/world.pmtiles" ] && echo 0 || echo 1)"

# 11. A store filled before the shipped depth rose. Presence is not enough:
#     the planet on disk is flatter than the one an installed copy draws, and
#     the app offers no way to deepen it -- the download card stopped offering
#     the world when the packages started carrying all of it. So the fetch has
#     to notice, and the stamp has to be one the old depth never wrote.
fresh
mkdir -p "$work/store/fonts" "$work/store/sprites"
echo 4 > "$work/store/world.pmtiles"
STUB_MODE=ok run
check "a store at the old depth is fetched again" \
  "$([ "$(calls)" = "1" ] && echo 0 || echo 1)"
check "and comes up to the depth the packages ship" \
  "$(grep -qx 6 "$work/store/world.pmtiles" && echo 0 || echo 1)"
stamped
check "which is then recorded" "$?"

# 12. And the same store, once deep enough, is left alone -- the check above
#     must be about the DEPTH and not about fetching on every run.
before="$(calls)"
STUB_MODE=offline run
check "a store already that deep is not fetched again" \
  "$([ "$(calls)" = "$before" ] && echo 0 || echo 1)"

# 13. The stamp follows the depth rather than merely existing. Raise what the
#     packages ship and every store recorded at the old depth is stale, with
#     nobody having to know to delete a file.
before="$(calls)"
STUB_SHIP_ZOOM=7 STUB_MODE=ok run
check "raising the shipped depth retires the old stamp" \
  "$([ "$(calls)" -gt "$before" ] && echo 0 || echo 1)"
check "and the deeper planet lands" \
  "$(grep -qx 7 "$work/store/world.pmtiles" && echo 0 || echo 1)"

echo
echo "basemap target: $checks checks, $failures failures"
[ "$failures" -eq 0 ]
