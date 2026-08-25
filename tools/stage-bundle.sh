#!/usr/bin/env bash
# Stage the map that every package ships.
#
# A map application that opens on a blank planet is not one, so the tarball,
# the .deb and the AppImage all carry a world overview, the glyphs its labels
# are drawn from and the sprites its icons come from. This assembles that
# payload into a directory the caller names.
#
#   tools/stage-bundle.sh dist/tessarium-0.1.0/basemap
#
# Inputs, all overridable:
#
#   WORLD_SOURCE  a .pmtiles archive covering the whole planet
#                 (default basemap/world.pmtiles)
#   WORLD_ZOOM    how deep the shipped overview goes (default 4)
#   ASSETS_DIR    where fonts/ and sprites/ are found (default basemap)
#
# Zoom 4 is about 6 MB and draws countries, coastlines and capitals: enough
# that the app opens on a planet and the download card is an offer rather
# than a rescue. Each further level roughly triples it -- 5 is 14 MB, 6 is
# 43 MB and is as deep as the map ever stands -- so the shipped floor is
# deliberately the shallow one, and going deeper is a download the user
# chooses.
#
# The overview is EXTRACTED rather than copied, so a package ships the same
# depth whatever the developer happens to have on disk, and it is extracted
# from a local archive, so packaging needs no network. The extract is
# byte-identical for a given source, which is what keeps the tarball and the
# .deb reproducible.
#
# Missing inputs are a hard error that names the command which produces them.
# A package that quietly shipped without a map is the whole bug this exists
# to prevent, and it is invisible until someone installs it.

set -euo pipefail

dest="${1:-}"
if [ -z "$dest" ]; then
  echo "usage: tools/stage-bundle.sh <destdir>" >&2
  exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

WORLD_SOURCE="${WORLD_SOURCE:-basemap/world.pmtiles}"
WORLD_ZOOM="${WORLD_ZOOM:-4}"
ASSETS_DIR="${ASSETS_DIR:-basemap}"

missing=0
if [ ! -f "$WORLD_SOURCE" ]; then
  echo "error: no world overview at $WORLD_SOURCE" >&2
  missing=1
fi
if [ ! -d "$ASSETS_DIR/fonts" ] || [ ! -d "$ASSETS_DIR/sprites" ]; then
  echo "error: no glyphs or sprites under $ASSETS_DIR" >&2
  missing=1
fi
if [ "$missing" -ne 0 ]; then
  echo "       every package ships a map; fetch one first:" >&2
  echo "         tools/fetch-basemap.sh -W $WORLD_ZOOM" >&2
  echo "       (WORLD_SOURCE and ASSETS_DIR name other locations.)" >&2
  exit 1
fi

fetcher="_build/default/ocaml/pmtiles/bin/main.exe"
if [ ! -x "$fetcher" ]; then
  dune build ocaml/pmtiles/bin/main.exe
fi

mkdir -p "$dest"
# Removed rather than overwritten: an --out that already exists is merged
# into, which would fold whatever was there into the shipped file.
rm -f "$dest/world.pmtiles" "$dest/world.pmtiles.part"
"$fetcher" "$WORLD_SOURCE" --bbox=-180,-85,180,85 \
  --max-zoom "$WORLD_ZOOM" --out "$dest/world.pmtiles" > /dev/null

rm -rf "$dest/fonts" "$dest/sprites"
cp -r "$ASSETS_DIR/fonts" "$dest/fonts"
cp -r "$ASSETS_DIR/sprites" "$dest/sprites"

# The glyph licence travels with the glyphs. It is upstream's own file, and
# it is the only licence text that arrives with the assets.
if [ ! -f "$dest/fonts/OFL.txt" ] && [ -f "$ASSETS_DIR/fonts/OFL.txt" ]; then
  cp "$ASSETS_DIR/fonts/OFL.txt" "$dest/fonts/OFL.txt"
fi

# The icons have no such file, and MIT is a licence that requires one:
# "the above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software". Upstream states
# the terms in its README and ships no LICENSE beside the sprites, so
# shipping them means writing that notice ourselves. Verified against
# protomaps/basemaps-assets and tangrams/icons on 2026-08-25.
cat > "$dest/sprites/LICENSE.txt" <<'ICONS'
The map icons in this directory come from the Protomaps basemaps-assets
project (https://github.com/protomaps/basemaps-assets), whose README states
that they are derived from the MIT-licensed tangrams/icons project
(https://github.com/tangrams/icons). Neither project ships a licence file
beside the icons themselves; this notice reproduces the licence that
tangrams/icons is published under.

The MIT License (MIT)

Copyright (c) 2017 Mapzen

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
ICONS

find "$dest" -type d -exec chmod 755 {} +
find "$dest" -type f -exec chmod 644 {} +

# What actually landed, checked rather than assumed. The failure this guards
# is a package that builds, installs, opens and draws nothing: an extractor
# that wrote a header and no tiles, or an assets directory that was really a
# stale empty one. Both leave a plausible-looking tree behind, and neither is
# visible again until somebody installs the result.
world_bytes="$(stat -c %s "$dest/world.pmtiles")"
glyph_count="$(find "$dest/fonts" -name '*.pbf' | wc -l)"
sprite_count="$(find "$dest/sprites" -name '*.png' | wc -l)"
if [ "$world_bytes" -lt 1000000 ] \
  || [ "$glyph_count" -lt 100 ] || [ "$sprite_count" -lt 1 ]; then
  echo "error: the staged map is not a map --" >&2
  echo "       world.pmtiles ${world_bytes}B, ${glyph_count} glyph ranges," \
       "${sprite_count} sprite sheets" >&2
  exit 1
fi

# Both licences that have to travel with the payload, checked for the same
# reason the tiles are: this is a package, redistributing is the whole of
# what it does, and neither notice being there is invisible until someone
# looks for it.
for notice in fonts/OFL.txt sprites/LICENSE.txt; do
  if [ ! -s "$dest/$notice" ]; then
    echo "error: $notice is missing from the staged map." >&2
    echo "       These assets may not be redistributed without it." >&2
    exit 1
  fi
done

printf '    world overview zooms 0-%s  %s\n' "$WORLD_ZOOM" \
  "$(du -h "$dest/world.pmtiles" | cut -f1)"
printf '    glyphs and sprites         %s\n' \
  "$(du -shc "$dest/fonts" "$dest/sprites" | tail -1 | cut -f1)"
