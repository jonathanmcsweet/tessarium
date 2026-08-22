#!/usr/bin/env bash
# Build a release tarball.
#
# The UI is compiled into the server binary, so what ships is two executables
# and nothing else — no asset directory to keep alongside them, no runtime to
# install. The basemap is deliberately not bundled: it is tens of megabytes and
# region-specific, and `tessarium-basemap` fetches whichever part of the
# world the user actually wants. That includes the world overview, which is
# small and global but still a download — README.txt below makes it the first
# step rather than an option, because without one the map is blank everywhere
# outside the region you fetched.

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

cat > "$out/README.txt" <<'TXT'
Tessarium
===========

Three BIP-39 words plus a number address every ~3 m square on Earth, under a
mapping private to your seed phrase.

Quick start
-----------

  1. Fetch the world overview. This is the map you see everywhere you have
     not downloaded in detail, and without it the map is blank outside the
     region you fetch in step 2. About 6 MB:

       ./tessarium-basemap latest \
         --bbox=-180,-85,180,85 --max-zoom 4 --out basemap/world.pmtiles

     Deeper is better: zoom 5 is about 14 MB and zoom 6 about 43 MB, which
     is as deep as the map will ever stand. A shallower overview is not
     wasted — the map stands on whichever level the file covers the whole
     planet at, so zoom 3 simply gives a coarser floor than zoom 6.

  2. Fetch a basemap for wherever you care about in detail:

       ./tessarium-basemap latest \
         --bbox=-0.25,51.45,0.0,51.55 --max-zoom 15 --out basemap/map.pmtiles

     ("latest" is the newest Protomaps daily planet build; an https:// URL
     or a local .pmtiles path works there too.) More regions can be added
     later from inside the app, and they merge rather than replace.

     You also need glyphs and sprites, once:

       curl -fsSL https://codeload.github.com/protomaps/basemaps-assets/tar.gz/refs/heads/main \
         | tar -xz --strip-components=1 -C basemap \
           --wildcards '*/fonts' '*/sprites'

  3. Run it:

       ./tessarium-server

     It serves http://127.0.0.1:7373 and opens your browser. Loopback only —
     it never binds a public interface.

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

Everything is served locally — map tiles, fonts and icons included. Once the
basemap is fetched, no network is needed.

Zooming past what you downloaded does not go blank: the world overview keeps
drawing underneath, stretched, and a note offers to download the area you are
looking at.

Requirements
------------

A 64-bit Linux system. Nothing else: libgmp is linked in statically (GMP
is LGPLv3+/GPLv2+; source at https://gmplib.org/, relink by rebuilding
from this project's source), and there is no runtime, no Node, no browser
engine bundled. The map opens in
whichever browser you already use.

To add Tessarium to your application menu, copy tessarium.desktop to
~/.local/share/applications/ and tessarium.svg to
~/.local/share/icons/hicolor/scalable/apps/ (edit Exec= to the full path
of tessarium-server first).

Source and licence
------------------

Apache-2.0. See LICENSE. https://github.com/tessarium/tessarium
TXT

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
