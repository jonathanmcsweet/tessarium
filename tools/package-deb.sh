#!/usr/bin/env bash
# Build a .deb. The binaries are self-contained (libgmp is linked
# statically), so the package depends on nothing beyond libc, and the payload
# is the same two executables the tarball ships, the same world overview they
# open on, and the menu integration a tarball cannot give: a desktop entry
# and an icon.
#
# The map is installed read-only under /usr/share, which is not where the app
# can write. `tessarium` -- the launcher the menu entry runs -- points the
# server at a directory under the user's own data home, and the server seeds
# that from the installed bundle the first time it finds it empty. Running
# `tessarium-server` directly keeps its documented default of ./basemap, so a
# terminal user gets exactly what the tarball gives them.
#
# Deterministic: fixed mtimes and root ownership, so rebuilding the same
# commit yields the same .deb.

set -euo pipefail

# Deterministic modes as well as timestamps: the artifact must not inherit
# the packager's umask (077 breaks dpkg-deb outright; 002 ships
# group-writable /usr).
umask 022

# dpkg-deb stamps its ar members and tars with this; without it every build
# differs by build time alone. The value spells 2026-08-19 00:00 UTC -- it is
# what the number MEANS, not a note about when anything changed.
export SOURCE_DATE_EPOCH=1787011200

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

version="$(sed -n 's/.*~version:"\([^"]*\)".*/\1/p' ocaml/server/bin/main.ml | head -1)"
version="${version:-0.0.0}"
arch="$(tools/target-arch.sh --debian _build/default/ocaml/server/bin/main.exe)"
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
install -m 755 packaging/tessarium-launcher "$stage/usr/bin/tessarium"
install -m 644 packaging/tessarium.svg "$stage/usr/share/icons/hicolor/scalable/apps/"
# The shared desktop entry runs `tessarium-server`, which is right for the
# tarball, where the map sits beside the binary. An installed copy has to go
# through the launcher instead, and this is the one line of difference.
sed 's/^Exec=tessarium-server$/Exec=tessarium/' packaging/tessarium.desktop \
  > "$stage/usr/share/applications/tessarium.desktop"
chmod 644 "$stage/usr/share/applications/tessarium.desktop"
grep -q '^Exec=tessarium$' "$stage/usr/share/applications/tessarium.desktop" \
  || { echo "error: the desktop entry's Exec= was not rewritten." >&2; exit 1; }

echo "==> map"
tools/stage-bundle.sh "$stage/usr/share/tessarium/basemap"
# The application is Apache-2.0; the binaries also embed GNU GMP
# statically, and conveying it obliges naming its licence and where its
# source lives.
{
  cat LICENSE
  cat <<'GMP'

----------------------------------------------------------------------
These binaries statically link the GNU Multiple Precision Arithmetic
Library (GMP), which is dual-licensed LGPLv3+ / GPLv2+. GMP source:
https://gmplib.org/. Relinking against a modified GMP: rebuild from this
package's full corresponding source, https://github.com/tessarium/tessarium.

----------------------------------------------------------------------
This package also carries a map, which is not this project's work and is
conveyed under its own terms.

/usr/share/tessarium/basemap/world.pmtiles contains OpenStreetMap data,
(c) OpenStreetMap contributors, licensed under the Open Database Licence
(ODbL) v1.0: https://opendatacommons.org/licenses/odbl/1-0/ and
https://www.openstreetmap.org/copyright. It was cut into vector tiles by
the Protomaps project.

/usr/share/tessarium/basemap/fonts holds the Noto fonts, licensed under the
SIL Open Font License v1.1. The full licence is installed beside them at
/usr/share/tessarium/basemap/fonts/OFL.txt.

/usr/share/tessarium/basemap/sprites holds map icons from the Protomaps
basemaps-assets project, which states that they are derived from the
MIT-licensed tangrams/icons project, (c) 2017 Mapzen. Neither project ships
a licence file beside the icons, so the MIT notice is installed with them at
/usr/share/tessarium/basemap/sprites/LICENSE.txt.
GMP
} > "$stage/usr/share/doc/tessarium/copyright"
chmod 644 "$stage/usr/share/doc/tessarium/copyright"

# The true glibc floor, read off the binaries rather than guessed: a
# hardcoded value rots the day the build image's glibc grows a symbol. The
# .deb is the format that can say this out loud, so it does -- and the shared
# check fails the build if the number moved, which is the part the AppImage
# and the tarball have no way to tell anyone.
echo "==> system floor"
tools/check-glibc-floor.sh \
  "$stage/usr/bin/tessarium-server" "$stage/usr/bin/tessarium-basemap"
glibc_floor="$(objdump -T \
  "$stage/usr/bin/tessarium-server" "$stage/usr/bin/tessarium-basemap" \
  | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1)"

size_kb="$(du -sk --apparent-size "$stage" --exclude=DEBIAN | cut -f1)"
cat > "$stage/DEBIAN/control" <<CTRL
Package: tessarium
Version: ${version}
Architecture: ${arch}
Maintainer: Tessarium <noreply@tessarium.org>
Installed-Size: ${size_kb}
Depends: libc6 (>= ${glibc_floor})
Section: utils
Priority: optional
Homepage: https://github.com/tessarium/tessarium
Description: private three-word addresses for every ~3 m square on Earth
 Three BIP-39 words plus a number address every ~3 m square on Earth,
 under a mapping that is private to each user's seed phrase. Runs a
 loopback-only server and opens the system browser. A world overview is
 included, so it works offline from the first run; detail for a region is
 downloaded in-app.
CTRL

(cd "$stage" && find usr -type f -exec md5sum {} +) > "$stage/DEBIAN/md5sums"
chmod 644 "$stage/DEBIAN/md5sums"

find "$stage" -exec touch -d "@${SOURCE_DATE_EPOCH}" {} +
mkdir -p dist
dpkg-deb --build --root-owner-group "$stage" "dist/${name}.deb" > /dev/null
rm -rf "$stage"

echo "dist/${name}.deb  ($(du -h "dist/${name}.deb" | cut -f1))"
dpkg-deb --info "dist/${name}.deb" | sed 's/^/  /' | head -14
