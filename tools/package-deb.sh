#!/usr/bin/env bash
# Build a .deb. The binaries are self-contained (libgmp is linked
# statically), so the package depends on nothing beyond libc, and the payload
# is the same two executables the tarball ships plus the menu integration a
# tarball cannot give: a desktop entry and an icon.
#
# Deterministic: fixed mtimes and root ownership, so rebuilding the same
# commit yields the same .deb.

set -euo pipefail

# Deterministic modes as well as timestamps: the artifact must not inherit
# the packager's umask (077 breaks dpkg-deb outright; 002 ships
# group-writable /usr).
umask 022

# dpkg-deb stamps its ar members and tars with this; without it every build
# differs by build time alone. 2026-08-19 00:00 UTC.
export SOURCE_DATE_EPOCH=1787011200

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
GMP
} > "$stage/usr/share/doc/tessarium/copyright"
chmod 644 "$stage/usr/share/doc/tessarium/copyright"

# The true glibc floor, read off the binaries rather than guessed: a
# hardcoded value rots the day the build image's glibc grows a symbol.
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
 loopback-only server and opens the system browser; works fully offline
 once a basemap is downloaded in-app.
CTRL

(cd "$stage" && find usr -type f -exec md5sum {} +) > "$stage/DEBIAN/md5sums"
chmod 644 "$stage/DEBIAN/md5sums"

find "$stage" -exec touch -d "@${SOURCE_DATE_EPOCH}" {} +
mkdir -p dist
dpkg-deb --build --root-owner-group "$stage" "dist/${name}.deb" > /dev/null
rm -rf "$stage"

echo "dist/${name}.deb  ($(du -h "dist/${name}.deb" | cut -f1))"
dpkg-deb --info "dist/${name}.deb" | sed 's/^/  /' | head -14
