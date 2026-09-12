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
#                                                 # into the map store, not
#                                                 # into the checkout
#   tools/fetch-basemap.sh -b -74.05,40.68,-73.90,40.80 -z 15
#   tools/fetch-basemap.sh -W 5                   # a shallower world overview
#   tools/fetch-basemap.sh -W ""                  # region only, no overview
#   tools/fetch-basemap.sh --print-world-zoom     # the depth packages ship
#   tools/fetch-basemap.sh -z ""                  # overview and assets only,
#                                                 # which is what packaging needs
#
# Two archives land: the region you asked for, and a world overview at -W
# zoom levels. The overview is what the map falls back to everywhere you did
# not download -- without one, panning off your region shows nothing at all.
# It is a separate file so that removing a region can never take it away.
#
# Tiles come from the Protomaps daily planet build over HTTP range requests --
# only the requested region is transferred, not the ~137 GB archive. The
# newest build is resolved at fetch time; -s pins a URL or local path instead.

set -euo pipefail

BBOX="-0.25,51.45,0.0,51.55"
MAX_ZOOM=15
# Not into the checkout: tools/basemap-dir.sh says where maps live, and a
# second spelling of that is how a hand fetch lands somewhere the app does
# not read. -o still wins, which is what packaging and CI pass.
OUT_DIR=""
SOURCE="latest"
# Zoom 6 is about 43 MB and is as deep as the map ever stands: the server
# never draws the overview past that. It is what every package ships, and
# what this fetches, so a checkout opens on the same planet an installed copy
# does -- towns and roads everywhere, not just countries and coastlines.
# Shallower is a real choice for a slow connection (4 is about 6 MB, 5 about
# 14 MB) and is not wasted, because the map floors on whatever level the file
# covers the WHOLE planet at. An interrupted fetch leaves a .part rather than
# a short file, so re-running this picks it up again.
#
# This number has one home. The Makefile asks for it with --print-world-zoom
# rather than repeating it, so the fetch and the stamp that records it cannot
# come to disagree about which depth is on disk.
WORLD_ZOOM=6
ASSETS="https://codeload.github.com/protomaps/basemaps-assets/tar.gz/refs/heads/main"

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# Asked by the Makefile, which names the stamp after the depth on disk. Answered
# before anything is built or fetched.
if [ "${1:-}" = "--print-world-zoom" ]; then
  printf '%s\n' "$WORLD_ZOOM"
  exit 0
fi

while getopts "b:z:o:s:W:h" opt; do
  case "$opt" in
    b) BBOX="$OPTARG" ;;
    z) MAX_ZOOM="$OPTARG" ;;
    o) OUT_DIR="$OPTARG" ;;
    s) SOURCE="$OPTARG" ;;
    W) WORLD_ZOOM="$OPTARG" ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

OUT_DIR="${OUT_DIR:-$(tools/basemap-dir.sh)}"

fetcher="_build/default/ocaml/pmtiles/bin/main.exe"
if [ ! -x "$fetcher" ]; then
  echo "building the basemap fetcher..."
  dune build ocaml/pmtiles/bin/main.exe
fi

mkdir -p "$OUT_DIR"

# Skippable, symmetrically with the overview below: building a package needs
# the world and the assets and no region at all, and fetching London to throw
# it away is tens of megabytes of someone else's bandwidth.
if [ -z "$MAX_ZOOM" ]; then
  echo "==> region skipped"
else
  echo "==> tiles"
  "$fetcher" "$SOURCE" --bbox="$BBOX" --max-zoom "$MAX_ZOOM" \
    --out "$OUT_DIR/map.pmtiles"
fi

# The world overview, fetched second so a failure here leaves a usable region
# behind. Kept when one is already present and deep enough: it does not change
# with the region, and it is the slowest part of a small fetch.
#
# Deep ENOUGH, not merely present. A store filled before the shipped depth
# changed holds a shallower planet, and presence alone would keep it there
# forever -- the app would draw countries where an installed copy draws towns,
# and nothing would say why. Refetched rather than deepened in place: an
# extract cannot add levels to an archive, and the download is the same
# bytes either way.
have_zoom=""
if [ -f "$OUT_DIR/world.pmtiles" ]; then
  have_zoom="$(tools/archive-max-zoom.sh "$OUT_DIR/world.pmtiles" || true)"
fi
if [ -z "$WORLD_ZOOM" ]; then
  echo "==> world overview skipped"
elif [ -n "$have_zoom" ] && [ "$have_zoom" -ge "$WORLD_ZOOM" ]; then
  echo "==> world overview already present (zooms 0-$have_zoom)"
elif [ -n "$have_zoom" ]; then
  echo "==> world overview goes to zoom $have_zoom, refetching to" \
    "$WORLD_ZOOM"
  # Beside the old one, never into it: an --out that already exists is MERGED
  # into, which would fold the shallow archive into its own replacement. The
  # old file stays readable until the new one is whole.
  rm -f "$OUT_DIR/world.pmtiles.new" "$OUT_DIR/world.pmtiles.new.part"
  "$fetcher" "$SOURCE" --bbox="-180,-85,180,85" --max-zoom "$WORLD_ZOOM" \
    --out "$OUT_DIR/world.pmtiles.new"
  mv "$OUT_DIR/world.pmtiles.new" "$OUT_DIR/world.pmtiles"
else
  echo "==> world overview (zooms 0-$WORLD_ZOOM)"
  "$fetcher" "$SOURCE" --bbox="-180,-85,180,85" --max-zoom "$WORLD_ZOOM" \
    --out "$OUT_DIR/world.pmtiles"
fi

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
