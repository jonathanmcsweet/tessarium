#!/usr/bin/env bash
# Build an AppImage, or at least its AppDir.
#
# The AppDir is always produced and is a complete, runnable layout — binaries,
# icon, desktop entry and the map it opens on — that part is testable
# anywhere. Squashing it into a .AppImage needs
# `appimagetool`, which is a separate download; when it is absent this
# script says so and leaves the AppDir, rather than failing the build for a
# tool most CI images do not carry.

set -euo pipefail

umask 022

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

version="$(sed -n 's/.*~version:"\([^"]*\)".*/\1/p' ocaml/server/bin/main.ml | head -1)"
version="${version:-0.0.0}"
appdir="dist/Tessarium.AppDir"

echo "==> building"
dune build ocaml/server/bin/main.exe ocaml/pmtiles/bin/main.exe

rm -rf "$appdir"
mkdir -p "$appdir/usr/bin"
install -m 755 _build/default/ocaml/server/bin/main.exe "$appdir/usr/bin/tessarium-server"
install -m 755 _build/default/ocaml/pmtiles/bin/main.exe "$appdir/usr/bin/tessarium-basemap"
install -m 644 packaging/tessarium.desktop "$appdir/tessarium.desktop"
install -m 644 packaging/tessarium.svg "$appdir/tessarium.svg"

# The format with no dependency metadata: a host below the floor gets a
# launch that dies rather than an install that refuses, so the number is
# checked here even though nothing in the image can carry it.
echo "==> system floor"
tools/check-glibc-floor.sh \
  "$appdir/usr/bin/tessarium-server" "$appdir/usr/bin/tessarium-basemap"

# The map ships inside the image, which is read-only; AppRun points the
# server at the user's data home and the server seeds that from here on the
# first run that finds it empty.
echo "==> map"
tools/stage-bundle.sh "$appdir/usr/share/tessarium/basemap"

cat > "$appdir/AppRun" <<'RUN'
#!/bin/sh
# The basemap lives beside the user's data, not inside the read-only image
# -- unless the user names their own; the flag cannot be repeated. The
# world overview inside the image is copied into that directory by the
# server the first time it finds it missing, so a first run opens on a map
# without having fetched anything.
here="$(dirname "$0")"
case " $* " in
  *" --basemap "*|*" --basemap="*)
    exec "$here/usr/bin/tessarium-server" "$@" ;;
  *)
    dir="${XDG_DATA_HOME:-$HOME/.local/share}/tessarium"
    mkdir -p "$dir/basemap"
    exec "$here/usr/bin/tessarium-server" --basemap "$dir/basemap" "$@" ;;
esac
RUN
chmod 755 "$appdir/AppRun"

if command -v appimagetool > /dev/null 2>&1; then
  ARCH=x86_64 appimagetool "$appdir" "dist/Tessarium-${version}-x86_64.AppImage"
  echo "dist/Tessarium-${version}-x86_64.AppImage"
else
  echo "AppDir ready at $appdir"
  echo "appimagetool not found: get it from https://github.com/AppImage/appimagetool"
  echo "then run: ARCH=x86_64 appimagetool $appdir"
fi
