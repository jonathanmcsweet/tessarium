#!/usr/bin/env bash
# Build a release tarball.
#
# The UI is compiled into the server binary, so what ships is two executables
# and the map they open on: a world overview at country level, the glyphs its
# labels are drawn from and the sprites its icons come from. No runtime to
# install, and nothing to fetch before the first run.
#
# A REGION in detail is still a download — it is region-specific and tens of
# megabytes, and the app offers it where the user is looking. What is bundled
# is the floor underneath that, which is what the difference between a map
# application and a blank window turns on.

set -euo pipefail

# The artifact must not inherit the packager's umask.
umask 022

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

version="$(sed -n 's/.*~version:"\([^"]*\)".*/\1/p' ocaml/server/bin/main.ml | head -1)"
version="${version:-0.0.0}"
arch="$(uname -m)"
name="tessarium-${version}-linux-${arch}"
out="dist/${name}"

if [ ! -d ocaml/server/ui_dist ]; then
  echo "error: ocaml/server/ui_dist is missing — run 'make ui' first, or the" >&2
  echo "       binary will ship with no UI compiled into it." >&2
  exit 1
fi

echo "==> building"
dune build ocaml/server/bin/main.exe ocaml/pmtiles/bin/main.exe

# A binary that shipped without its UI would start, serve 404s, and look like a
# broken install. Cheap to check, and invisible if it goes wrong.
embedded="$(grep -c '^  ("' _build/default/ocaml/server/embedded_assets.ml || true)"
if [ "${embedded:-0}" -lt 1 ]; then
  echo "error: no assets were embedded — run 'make ui' then 'make build'." >&2
  exit 1
fi
echo "    $embedded assets embedded"

rm -rf "$out"
mkdir -p "$out"
cp _build/default/ocaml/server/bin/main.exe "$out/tessarium-server"
cp _build/default/ocaml/pmtiles/bin/main.exe "$out/tessarium-basemap"
cp LICENSE "$out/"
chmod +x "$out"/tessarium-*

# A tarball has nowhere to declare a dependency, so a host below the floor
# gets a binary that will not start. The number goes in README.txt below and
# is read back out of the binaries here.
echo "==> system floor"
floor_report="$(tools/check-glibc-floor.sh \
  "$out/tessarium-server" "$out/tessarium-basemap")"
printf '%s\n' "$floor_report"
glibc_floor="$(printf '%s' "$floor_report" \
  | sed -n 's/.*glibc floor \([0-9.]*\).*/\1/p')"

# The tarball keeps its map where the server looks by default, so an
# extracted directory runs with no arguments and no seeding.
echo "==> map"
tools/stage-bundle.sh "$out/basemap"

cat > "$out/README.txt" <<'TXT'
Tessarium
===========

Three BIP-39 words plus a number address every ~3 m square on Earth, under a
mapping private to your seed phrase.

Quick start
-----------

  1. Run it:

       ./tessarium-server

     It serves http://127.0.0.1:7373 and opens your browser. Loopback only —
     it never binds a public interface.

That is the whole of it. The basemap/ directory beside these binaries holds
a world overview at country level, so the map is drawn the moment it opens,
and anywhere you want in street detail is a download offered inside the app
for the area you are looking at.

Adding map without the app
--------------------------

Detail for a region, if you would rather not use the download card:

  ./tessarium-basemap latest \
    --bbox=-0.25,51.45,0.0,51.55 --max-zoom 15 --out basemap/map.pmtiles

("latest" is the newest Protomaps daily planet build; an https:// URL or a
local .pmtiles path works there too.) Downloads merge rather than replace,
so nothing already held is fetched twice.

A deeper world overview, if you want a better floor everywhere:

  ./tessarium-basemap latest \
    --bbox=-180,-85,180,85 --max-zoom 6 --out basemap/world.pmtiles

The shipped one stops at zoom 4, which is about 6 MB. Zoom 5 is about 14 MB
and zoom 6 about 43 MB, which is as deep as the map ever stands.

Your seed phrase
----------------

Use a FRESH 24-word phrase. Do not reuse a wallet seed: anyone who learns a
few of your addresses and where they actually are is doing cryptanalysis
against that key, and if it also holds funds you have combined two unrelated
risks for nothing.

The phrase is typed into the page and the key is derived from it in a Web
Worker on your device. It is never written to disk, never put in a URL, and
never sent anywhere.

The server has an encode/decode API which is OFF by default. Turning it on
with --api means seed phrases cross the network to the server process. The
web UI never uses it.

Working offline
---------------

Everything is served locally — map tiles, fonts and icons included. Nothing
is fetched at all unless you ask for more map than the overview holds.

Zooming past what you downloaded does not go blank: the world overview keeps
drawing underneath, stretched, and a note offers to download the area you are
looking at.

Requirements
------------

A 64-bit Linux system with GNU C library __GLIBC_FLOOR__ or newer. That rules
out RHEL 9 and its rebuilds, Debian 11 and Ubuntu 20.04; a tarball cannot
check, so on those the binaries will not start at all.

Nothing else is needed: libgmp is linked in statically (GMP is LGPLv3+/GPLv2+;
source at https://gmplib.org/, relink by rebuilding from this project's
source), and there is no runtime, no Node and no browser engine bundled. The
map opens in whichever browser you already use.

To add Tessarium to your application menu, copy tessarium.desktop to
~/.local/share/applications/ and tessarium.svg to
~/.local/share/icons/hicolor/scalable/apps/ (edit Exec= to the full path
of tessarium-server first).

Source and licence
------------------

The application is Apache-2.0. See LICENSE.
https://github.com/tessarium/tessarium

The map under basemap/ is not ours and travels under its own terms:

  Tiles    OpenStreetMap data, © OpenStreetMap contributors, under the Open
           Database Licence (ODbL). Cut into vector tiles by Protomaps.
           https://www.openstreetmap.org/copyright
  Glyphs   The Noto fonts, SIL Open Font License 1.1. The licence travels
           with them, at basemap/fonts/OFL.txt.
  Sprites  Map icons from the Protomaps basemaps-assets project, derived
           from the MIT-licensed tangrams/icons project, (c) 2017 Mapzen.
           The MIT notice travels with them, at
           basemap/sprites/LICENSE.txt.
TXT

sed -i "s/__GLIBC_FLOOR__/${glibc_floor}/" "$out/README.txt"
if grep -q '__GLIBC_FLOOR__' "$out/README.txt"; then
  echo "error: README.txt still names no glibc floor." >&2
  exit 1
fi

cp packaging/tessarium.desktop packaging/tessarium.svg "$out/"

mkdir -p dist
# Deterministic: fixed order, owner, modes and timestamps, and gzip without
# its name/mtime header -- the same toolchain must yield the same bytes,
# which is what lets a release be verified by rebuilding it. (Cross-MACHINE
# identity additionally needs the same opam root: the binaries embed
# absolute build paths. Recorded on the verifiable-builds roadmap item.)
find "$out" -exec touch -d "@1787011200" {} +
tar --sort=name --owner=0 --group=0 --numeric-owner --mode='u+rw,go=rX' \
  --mtime="@1787011200" -c -C dist "$name" | gzip -n > "dist/${name}.tar.gz"
rm -rf "$out"

echo
echo "dist/${name}.tar.gz  ($(du -h "dist/${name}.tar.gz" | cut -f1))"
tar -tzf "dist/${name}.tar.gz" | sed 's/^/  /'
