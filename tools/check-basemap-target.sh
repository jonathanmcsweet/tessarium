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

# The fetcher, minus the network. It records every call and writes what the
# real one writes at the point STUB_MODE says it stops. The overview lands
# before the assets, so "the overview is here" and "the map is usable" are two
# different questions.
cat > "$work/tools/fetch-basemap.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "called" >> calls.log
mkdir -p basemap
case "${STUB_MODE:-ok}" in
  ok)
    : > basemap/world.pmtiles
    mkdir -p basemap/fonts basemap/sprites
    ;;
  assets-fail)
    : > basemap/world.pmtiles
    echo "stub: the assets tarball failed" >&2
    exit 1
    ;;
  offline)
    echo "stub: could not resolve host" >&2
    exit 6
    ;;
esac
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
chmod +x "$work/tools/fetch-basemap.sh" "$work/bin/dune" \
  "$work/_build/default/ocaml/server/bin/main.exe"

fresh() { rm -rf "$work/basemap" "$work/calls.log" "$work/started.log"; }
calls() { [ -f "$work/calls.log" ] && wc -l < "$work/calls.log" || echo 0; }
started() { [ -f "$work/started.log" ]; }
stamped() { [ -f "$work/basemap/.fetched" ]; }
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
[ -f "$work/basemap/world.pmtiles" ]
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
mkdir -p "$work/basemap/fonts" "$work/basemap/sprites"
: > "$work/basemap/world.pmtiles"
STUB_MODE=offline run
stamped
check "a map fetched by hand is adopted" "$?"
check "with no call to the fetcher" "$([ "$(calls)" = "0" ] && echo 0 || echo 1)"

echo
echo "basemap target: $checks checks, $failures failures"
[ "$failures" -eq 0 ]
