#!/usr/bin/env bash
# Build an AppImage, or at least its AppDir.
#
# The AppDir is always produced and is a complete, runnable layout — that
# part is testable anywhere. Squashing it into a .AppImage needs
# `appimagetool`, which is a separate download; when it is absent this
# script says so and leaves the AppDir, rather than failing the build for a
# tool most CI images do not carry.

set -euo pipefail

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

cat > "$appdir/AppRun" <<'RUN'
#!/bin/sh
# The basemap lives beside the user's data, not inside the read-only image.
dir="${XDG_DATA_HOME:-$HOME/.local/share}/tessarium"
mkdir -p "$dir/basemap"
exec "$(dirname "$0")/usr/bin/tessarium-server" --basemap "$dir/basemap" "$@"
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
