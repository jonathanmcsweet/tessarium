#!/usr/bin/env bash
# Install a built package into a throwaway root and run it the way a desktop
# menu entry would.
#
# Everything else in this project tests the source tree. A package can pass
# all of it and still fail on a user's machine: the map installs read-only
# under /usr and the app cannot write there, the launcher is the only thing
# that redirects it, and a menu entry starts the app in whatever directory
# the desktop felt like. Those failures exist only after installation, so
# this is the only check that can see them.
#
#   tools/test-install.sh                   # every package in dist/
#   tools/test-install.sh dist/foo.deb      # just this one
#
# The app runs from an EMPTY working directory, because that is what a menu
# entry gives it and it is how a relative default path gets caught, and with
# a private data home, so the run seeds from the packaged map rather than
# from whatever an earlier test left behind.

set -euo pipefail

port="${TESSARIUM_INSTALL_TEST_PORT:-7379}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

checks=0
failures=0
server_pid=""
work=""

check() { # name, then a command whose exit status is the verdict
  local name="$1"
  shift
  checks=$((checks + 1))
  if "$@"; then
    printf '    ok    %s\n' "$name"
  else
    failures=$((failures + 1))
    printf '    FAIL  %s\n' "$name"
  fi
}

cleanup() {
  [ -n "$server_pid" ] && kill "$server_pid" 2> /dev/null || true
  [ -n "$work" ] && rm -rf "$work" || true
}
trap cleanup EXIT

# A served path is checked for its status AND for having a body: a 200 that
# returns nothing is what a present-but-empty map file produces, and it is
# indistinguishable from success if only the code is read.
served() {
  local path="$1" min="$2" out
  out="$(curl -s -o /dev/null -w '%{http_code} %{size_download}' \
    "http://127.0.0.1:${port}${path}")"
  [ "${out% *}" = "200" ] && [ "${out#* }" -ge "$min" ]
}

# A check that talks to a port someone else is serving passes without ever
# starting the package. Refuse rather than report a result about the wrong
# process.
port_is_free() {
  ! (exec 3<> "/dev/tcp/127.0.0.1/${port}") 2> /dev/null
}

test_deb() {
  local pkg="$1"
  command -v dpkg-deb > /dev/null \
    || { echo "error: $pkg was built but dpkg-deb is not installed, so it" \
      "cannot be verified." >&2; exit 1; }
  dpkg-deb -x "$pkg" "$work/root"
}

install_and_run() {
  local pkg="$1" fs="$work/root"

  # What the package must contain to be installable at all. Checked before
  # anything is launched, so a missing file is named rather than showing up
  # as a failed request later.
  check "the launcher the menu entry runs is installed" \
    test -x "$fs/usr/bin/tessarium"
  check "the server binary is installed" \
    test -x "$fs/usr/bin/tessarium-server"
  check "the basemap fetcher is installed" \
    test -x "$fs/usr/bin/tessarium-basemap"
  check "a world map is installed with the package" \
    test -s "$fs/usr/share/tessarium/basemap/world.pmtiles"
  check "the licence terms are installed" \
    test -s "$fs/usr/share/doc/tessarium/copyright"

  # A desktop entry that names a command or an icon the package does not
  # ship is a menu item that does nothing, which no other check would catch.
  local entry="$fs/usr/share/applications/tessarium.desktop"
  check "a desktop entry is installed" test -s "$entry"
  local exec_name icon_name
  exec_name="$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' "$entry" | head -1)"
  icon_name="$(sed -n 's/^Icon=\(.*\)/\1/p' "$entry" | head -1)"
  check "the desktop entry's Exec=${exec_name:-?} is a command it installs" \
    test -x "$fs/usr/bin/${exec_name:-missing}"
  check "the desktop entry's Icon=${icon_name:-?} is an icon it installs" \
    test -n "$(find "$fs/usr/share/icons" -name "${icon_name:-missing}.*" \
      2> /dev/null)"

  # Launched the way the desktop launches it: through the installed
  # launcher, on the installed PATH, from a directory holding nothing.
  mkdir -p "$work/cwd" "$work/home"
  # `exec` in the subshell so $! is the server itself and not a shell that
  # holds the port open after the kill below.
  (
    cd "$work/cwd" \
      && PATH="$fs/usr/bin:$PATH" XDG_DATA_HOME="$work/home" \
        exec "$fs/usr/bin/tessarium" --port "$port" --no-open
  ) > "$work/log" 2>&1 &
  server_pid=$!
  curl -s --retry-connrefused --retry 30 --retry-delay 1 \
    -o /dev/null "http://127.0.0.1:${port}/" || true

  check "it starts and stays up" kill -0 "$server_pid"

  # The map is installed read-only under /usr; the app can only use it after
  # the launcher points it somewhere writable and the server copies it in.
  # This is the step that makes an installed copy different from the tarball.
  check "the packaged map is seeded into the user's own data directory" \
    test -s "$work/home/tessarium/basemap/world.pmtiles"

  # The other half of that: a menu entry starts the app somewhere arbitrary,
  # and an app that writes a map into whatever directory it was launched from
  # is one that fills a user's home with copies of the planet.
  check "it writes nothing into the directory it was started in" \
    test -z "$(ls -A "$work/cwd")"

  # Everything a first run needs to draw a map, from the package alone, with
  # nothing downloaded. Sizes are floors, not fixtures: they only have to be
  # large enough that an empty or truncated file cannot pass.
  check "it serves the application" served "/" 200
  check "it serves a world tile" served "/tiles/0/0/0.mvt" 10000
  check "it serves map label glyphs" \
    served "/basemap/fonts/Noto%20Sans%20Regular/0-255.pbf" 1000
  check "it serves map icons" served "/basemap/sprites/v4/light.png" 1000
  check "it reports the map coverage it actually has" served "/world.json" 50

  kill "$server_pid" 2> /dev/null || true
  wait "$server_pid" 2> /dev/null || true
  server_pid=""
}

packages=("$@")
if [ ${#packages[@]} -eq 0 ]; then
  # No globstar assumptions and no `ls`: an empty dist/ must reach the error
  # below rather than expanding to a literal pattern.
  while IFS= read -r p; do packages+=("$p"); done < <(
    find dist -maxdepth 1 -name '*.deb' | sort
  )
fi

if [ ${#packages[@]} -eq 0 ]; then
  echo "error: no packages found in dist/ -- run 'make package-deb' first." >&2
  exit 1
fi

for pkg in "${packages[@]}"; do
  [ -f "$pkg" ] || { echo "error: no such package: $pkg" >&2; exit 1; }
  if ! port_is_free; then
    echo "error: something is already listening on port $port; set" \
      "TESSARIUM_INSTALL_TEST_PORT to a free one." >&2
    exit 1
  fi
  echo "==> $pkg"
  work="$(mktemp -d)"
  case "$pkg" in
    *.deb) test_deb "$pkg" ;;
    *) echo "error: no installer known for $pkg" >&2; exit 1 ;;
  esac
  install_and_run "$pkg"
  rm -rf "$work"
  work=""
done

echo
echo "$checks checks, $failures failures"
[ "$failures" -eq 0 ] || exit 1
echo "the built packages install and run"
