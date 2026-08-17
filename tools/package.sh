#!/usr/bin/env bash
# Build a release tarball.
#
# The UI is compiled into the server binary, so what ships is two executables
# and nothing else — no asset directory to keep alongside them, no runtime to
# install. The basemap is deliberately not bundled: it is tens of megabytes and
# region-specific, and `tessarium-basemap` fetches whichever part of the
# world the user actually wants.

set -euo pipefail

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

  1. Fetch a basemap for wherever you care about:

       ./tessarium-basemap https://demo-bucket.protomaps.com/v4.pmtiles \
         --bbox=-0.25,51.45,0.0,51.55 --max-zoom 15 --out basemap/map.pmtiles

     You also need glyphs and sprites, once:

       curl -fsSL https://codeload.github.com/protomaps/basemaps-assets/tar.gz/refs/heads/main \
         | tar -xz --strip-components=1 -C basemap \
           --wildcards '*/fonts' '*/sprites'

  2. Run it:

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

Requirements
------------

A 64-bit Linux system with libgmp (package `libgmp10` on Debian/Ubuntu,
`gmp` on Fedora/Arch). It is almost always already present — Python, GnuPG
and coreutils pull it in — but it is a real dependency, not none.

Nothing else: no runtime, no Node, no browser engine bundled. The map opens
in whichever browser you already use.

Source and licence
------------------

Apache-2.0. See LICENSE. https://github.com/tessarium/tessarium
TXT

mkdir -p dist
tar -czf "dist/${name}.tar.gz" -C dist "$name"
rm -rf "$out"

echo
echo "dist/${name}.tar.gz  ($(du -h "dist/${name}.tar.gz" | cut -f1))"
tar -tzf "dist/${name}.tar.gz" | sed 's/^/  /'
