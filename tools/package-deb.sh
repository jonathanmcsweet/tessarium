#!/usr/bin/env bash
# Build a .deb. The binaries are self-contained (libgmp is linked
# statically), so the package depends on nothing beyond libc, and the payload
# is the same two executables the tarball ships plus the menu integration a
# tarball cannot give: a desktop entry and an icon.
#
# Deterministic: fixed mtimes and root ownership, so rebuilding the same
# commit yields the same .deb.

set -euo pipefail

# dpkg-deb stamps its ar members and tars with this; without it every build
# differs by build time alone.
export SOURCE_DATE_EPOCH=1755475200

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

version="$(sed -n 's/.*~version:"\([^"]*\)".*/\1/p' ocaml/server/bin/main.ml | head -1)"
version="${version:-0.0.0}"
arch=amd64
name="tessarium_${version}_${arch}"
stage="dist/${name}"

echo "==> building"
dune build ocaml/server/bin/main.exe ocaml/pmtiles/bin/main.exe

embedded="$(grep -c '^  ("' _build/default/ocaml/server/embedded_assets.ml || true)"
if [ "${embedded:-0}" -lt 1 ]; then
  echo "error: no assets were embedded — run 'make ui' then 'make build'." >&2
  exit 1
fi

rm -rf "$stage"
mkdir -p \
  "$stage/DEBIAN" \
  "$stage/usr/bin" \
  "$stage/usr/share/applications" \
  "$stage/usr/share/icons/hicolor/scalable/apps" \
  "$stage/usr/share/doc/tessarium"

install -m 755 _build/default/ocaml/server/bin/main.exe "$stage/usr/bin/tessarium-server"
install -m 755 _build/default/ocaml/pmtiles/bin/main.exe "$stage/usr/bin/tessarium-basemap"
install -m 644 packaging/tessarium.desktop "$stage/usr/share/applications/"
install -m 644 packaging/tessarium.svg "$stage/usr/share/icons/hicolor/scalable/apps/"
install -m 644 LICENSE "$stage/usr/share/doc/tessarium/copyright"

size_kb="$(du -sk "$stage" --exclude=DEBIAN | cut -f1)"
cat > "$stage/DEBIAN/control" <<CTRL
Package: tessarium
Version: ${version}
Architecture: ${arch}
Maintainer: Tessarium <noreply@tessarium.org>
Installed-Size: ${size_kb}
Depends: libc6 (>= 2.34)
Section: utils
Priority: optional
Homepage: https://github.com/tessarium/tessarium
Description: private three-word addresses for every ~3 m square on Earth
 Three BIP-39 words plus a number address every ~3 m square on Earth,
 under a mapping that is private to each user's seed phrase. Runs a
 loopback-only server and opens the system browser; works fully offline
 once a basemap is downloaded in-app.
CTRL

find "$stage" -exec touch -d "@1755475200" {} +
mkdir -p dist
dpkg-deb --build --root-owner-group "$stage" "dist/${name}.deb" > /dev/null
rm -rf "$stage"

echo "dist/${name}.deb  ($(du -h "dist/${name}.deb" | cut -f1))"
dpkg-deb --info "dist/${name}.deb" | sed 's/^/  /' | head -14
