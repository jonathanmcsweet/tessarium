#!/usr/bin/env bash
# Fetch an offline basemap: vector tiles for a region, plus the glyphs and
# sprites the style needs.
#
# All three are served from this origin at runtime. A style that reaches a CDN
# for its labels looks perfect online and renders as unlabelled grey shapes the
# first time someone opens it on a train, which is the case this project cares
# about.
#
#   tools/fetch-basemap.sh                        # central London, zoom 15
#   tools/fetch-basemap.sh -b -74.05,40.68,-73.90,40.80 -z 15
#
# Tiles come from the Protomaps daily planet build over HTTP range requests --
# only the requested region is transferred, not the 128 GB archive.

set -euo pipefail

BBOX="-0.25,51.45,0.0,51.55"
MAX_ZOOM=15
OUT_DIR="basemap"
SOURCE="https://demo-bucket.protomaps.com/v4.pmtiles"
ASSETS="https://codeload.github.com/protomaps/basemaps-assets/tar.gz/refs/heads/main"

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while getopts "b:z:o:s:h" opt; do
  case "$opt" in
    b) BBOX="$OPTARG" ;;
    z) MAX_ZOOM="$OPTARG" ;;
    o) OUT_DIR="$OPTARG" ;;
    s) SOURCE="$OPTARG" ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

fetcher="_build/default/ocaml/pmtiles/bin/main.exe"
if [ ! -x "$fetcher" ]; then
  echo "building the basemap fetcher..."
  dune build ocaml/pmtiles/bin/main.exe
fi

mkdir -p "$OUT_DIR"

echo "==> tiles"
"$fetcher" "$SOURCE" --bbox="$BBOX" --max-zoom "$MAX_ZOOM" \
  --out "$OUT_DIR/map.pmtiles"

# Glyphs and sprites come as one tarball rather than 768 individual range
# files. Skipped if already present -- they do not change with the region.
if [ -d "$OUT_DIR/fonts" ] && [ -d "$OUT_DIR/sprites" ]; then
  echo "==> glyphs and sprites already present"
else
  echo "==> glyphs and sprites"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$ASSETS" | tar -xz -C "$tmp"
  extracted="$(find "$tmp" -maxdepth 1 -type d -name 'basemaps-assets-*' | head -1)"
  rm -rf "$OUT_DIR/fonts" "$OUT_DIR/sprites"
  cp -r "$extracted/fonts" "$OUT_DIR/fonts"
  cp -r "$extracted/sprites" "$OUT_DIR/sprites"
fi

echo
echo "basemap ready in $OUT_DIR/"
du -sh "$OUT_DIR"/* 2>/dev/null || true
