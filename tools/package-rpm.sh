#!/usr/bin/env bash
# Build an .rpm: the same payload the .deb installs, for Fedora, RHEL and
# its rebuilds, and openSUSE.
#
# This is not the primary Fedora target. On Silverblue and Kinoite an rpm has
# to be layered with rpm-ostree and a reboot, and it complicates every later
# system update; the Flatpak is the supported path there. This serves
# conventional Workstation and enterprise installs, where it is the format
# people actually expect.
#
# Everything about the layout matches tools/package-deb.sh -- same binaries,
# same launcher, same desktop entry and icon, same map under /usr/share --
# because the app has to behave identically once installed and the shared
# install check verifies both against the same expectations.
#
# Deterministic, like the .deb: rebuilding the same commit produces the same
# bytes. rpm needs more persuading than dpkg-deb does, and the reasons are
# on each setting below.

set -euo pipefail

umask 022

# Same epoch as the .deb, for the same reason: without it every build differs
# by build time alone. This is what the number MEANS, not a note about when
# anything changed.
export SOURCE_DATE_EPOCH=1787011200

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if ! command -v rpmbuild > /dev/null 2>&1; then
  echo "error: rpmbuild is not installed. On Debian and Ubuntu it is in the" >&2
  echo "       'rpm' package; on Fedora it is 'rpm-build'." >&2
  exit 1
fi

version="$(sed -n 's/.*~version:"\([^"]*\)".*/\1/p' ocaml/server/bin/main.ml | head -1)"
version="${version:-0.0.0}"

echo "==> building"
dune build ocaml/server/bin/main.exe ocaml/pmtiles/bin/main.exe

embedded="$(grep -c '^  ("' _build/default/ocaml/server/embedded_assets.ml || true)"
if [ "${embedded:-0}" -lt 1 ]; then
  echo "error: no assets were embedded — run 'make ui' then 'make build'." >&2
  exit 1
fi

arch="$(tools/target-arch.sh --gnu _build/default/ocaml/server/bin/main.exe)"

# %_topdir inside the tree so this needs no root and writes nothing into
# ~/rpmbuild.
top="$root/dist/rpmbuild"
buildroot="$top/BUILDROOT/tessarium"
rm -rf "$top"
mkdir -p "$top/SPECS" "$top/RPMS" \
  "$buildroot/usr/bin" \
  "$buildroot/usr/share/applications" \
  "$buildroot/usr/share/icons/hicolor/scalable/apps" \
  "$buildroot/usr/share/licenses/tessarium"

install -m 755 _build/default/ocaml/server/bin/main.exe "$buildroot/usr/bin/tessarium-server"
install -m 755 _build/default/ocaml/pmtiles/bin/main.exe "$buildroot/usr/bin/tessarium-basemap"
install -m 755 packaging/tessarium-launcher "$buildroot/usr/bin/tessarium"
install -m 644 packaging/tessarium.svg "$buildroot/usr/share/icons/hicolor/scalable/apps/"
# Same one-line difference as the .deb: the shared desktop entry runs
# tessarium-server, which is right for the tarball; an installed copy has to
# go through the launcher.
sed 's/^Exec=tessarium-server$/Exec=tessarium/' packaging/tessarium.desktop \
  > "$buildroot/usr/share/applications/tessarium.desktop"
chmod 644 "$buildroot/usr/share/applications/tessarium.desktop"
grep -q '^Exec=tessarium$' "$buildroot/usr/share/applications/tessarium.desktop" \
  || { echo "error: the desktop entry's Exec= was not rewritten." >&2; exit 1; }

echo "==> map"
tools/stage-bundle.sh "$buildroot/usr/share/tessarium/basemap"

echo "==> system floor"
tools/check-glibc-floor.sh \
  "$buildroot/usr/bin/tessarium-server" "$buildroot/usr/bin/tessarium-basemap"

# rpm derives the glibc requirement from the binaries itself, per symbol
# version, which is finer than the .deb's single floor -- so unlike the
# control file there is no number to write here. check-glibc-floor.sh above
# still runs, because its job is to fail the build when the floor DRIFTS,
# and a dependency rpm generates from whatever it was handed cannot notice
# that.
cat > "$top/SPECS/tessarium.spec" <<SPEC
Name:           tessarium
Version:        ${version}
Release:        1
Summary:        Private three-word addresses for every ~3 m square on Earth
License:        Apache-2.0
BuildArch:      ${arch}

%description
Three BIP-39 words plus a number address every ~3 m square on Earth, under a
mapping that is private to each user's seed phrase. Runs a loopback-only
server and opens the system browser. A world overview is included, so it
works offline from the first run; detail for a region is downloaded in-app.

%files
%license /usr/share/licenses/tessarium/LICENSE
/usr/bin/tessarium
/usr/bin/tessarium-server
/usr/bin/tessarium-basemap
/usr/share/applications/tessarium.desktop
/usr/share/icons/hicolor/scalable/apps/tessarium.svg
/usr/share/tessarium

%changelog
SPEC

# The licence text, and the third-party terms the binaries and the map carry.
# Same content as the .deb's copyright file; rpm's convention puts it under
# /usr/share/licenses rather than /usr/share/doc.
{
  cat LICENSE
  cat <<'NOTICES'

----------------------------------------------------------------------
These binaries statically link the GNU Multiple Precision Arithmetic
Library (GMP), which is dual-licensed LGPLv3+ / GPLv2+. GMP source:
https://gmplib.org/.

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
NOTICES
} > "$buildroot/usr/share/licenses/tessarium/LICENSE"
chmod 644 "$buildroot/usr/share/licenses/tessarium/LICENSE"

find "$buildroot" -exec touch -d "@${SOURCE_DATE_EPOCH}" {} +

echo "==> rpm"
# --define rather than a ~/.rpmmacros, so this build cannot be changed by
# whatever the machine already had.
#
#   _buildhost      rpm records the machine's hostname otherwise, which makes
#                   the result differ between two identical builds.
#   _binary_payload rpm's default compressor varies by distribution -- newer
#                   Fedora uses zstd, which RHEL 8 and older cannot read.
#                   xz is readable everywhere rpm still runs and is also the
#                   smallest of the three here (18M against 24M for zstd and
#                   28M for gzip); pinning it is also what makes the payload
#                   byte-identical across the machines that build it.
#   clamp_mtime...  no file inside may carry an mtime past the epoch above.
#   _build_id_links rpm otherwise invents /usr/lib/.build-id symlinks that are
#                   not in %files and fail the build as unpackaged files.
#   use_source_...  rpm stamps the package with wall-clock build time unless
#                   told otherwise, and defaults this to 0. Without it every
#                   rebuild differs in the one field nothing else can pin.
rpmbuild -bb "$top/SPECS/tessarium.spec" \
  --define "_topdir $top" \
  --define "_buildhost reproducible" \
  --define "_binary_payload w19.xzdio" \
  --define "clamp_mtime_to_source_date_epoch 1" \
  --define "use_source_date_epoch_as_buildtime 1" \
  --define "_build_id_links none" \
  --buildroot "$buildroot" \
  > "$top/build.log" 2>&1 \
  || { echo "error: rpmbuild failed:" >&2; tail -20 "$top/build.log" >&2; exit 1; }

built="$(find "$top/RPMS" -name '*.rpm' | head -1)"
[ -n "$built" ] || { echo "error: rpmbuild produced no .rpm." >&2; exit 1; }

# rpm works out the C library requirement from the binaries it is handed, by
# reading their symbol versions -- but only if it recognised them as ELF at
# all, and when it does not it says nothing and produces a package that
# declares no dependencies. That package installs on a system far too old to
# run it and fails at launch with nothing to explain why. So the result is
# read back: no glibc requirement means the classifier did not run, which is
# a broken build and not a package with no dependencies.
requires="$(rpm -qpR "$built" 2> /dev/null | grep -c 'GLIBC_' || true)"
if [ "${requires:-0}" -lt 1 ]; then
  echo "error: the built rpm declares no glibc requirement, which means rpm" >&2
  echo "       did not recognise the binaries as ELF -- usually a missing" >&2
  echo "       file(1) or magic database. It would install on systems that" >&2
  echo "       cannot run it." >&2
  exit 1
fi
printf '    requires %s glibc symbol versions, newest %s\n' "$requires" \
  "$(rpm -qpR "$built" 2> /dev/null | sed -n 's/.*(GLIBC_\([0-9.]*\)).*/\1/p' \
    | sort -uV | tail -1)"

mkdir -p dist
out="dist/tessarium-${version}-1.${arch}.rpm"
mv "$built" "$out"
rm -rf "$top"

echo "$out  ($(du -h "$out" | cut -f1))"
