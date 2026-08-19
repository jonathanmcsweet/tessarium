/* Turning "which tiles does this server have" into something drawable.

   The server answers a viewport with one character per tile, north-west
   first, running west to east and then south. What the map needs is the
   opposite shape: as few polygons as possible covering the tiles that are
   MISSING, because those are what gets greyed out and outlined.

   Kept apart from React and MapLibre so it can be tested as arithmetic --
   the merge is the kind of loop that looks right and is off by one, and
   the projection has to agree exactly with the server's tile grid or the
   grey lands next to the blank rather than on it. */

export type Coverage = {
  zoom: number;
  x: number;
  y: number;
  w: number;
  h: number;
  /* One character per tile: "1" held, "0" missing. */
  present: string;
  /* Deepest zoom the archive has anything at, under the middle of the
     view; -1 when it has nothing there at any zoom. */
  depth: number;
};

export type Rect = { x: number; y: number; w: number; h: number; };

/* The missing tiles, merged into rectangles.

   Greedy and in two passes: runs of missing tiles along each row, then a
   run extended downward for as long as the row below repeats it exactly.
   That is not the minimal rectangle cover -- finding that is a much harder
   problem -- but coverage edges are long and straight, so in practice a
   viewport outside a downloaded region collapses to one rectangle, and a
   viewport straddling its border to a handful. */
export function absentRects(c: Coverage): Rect[] {
  const missing = (x: number, y: number) => c.present[y * c.w + x] === "0";
  /* Rows already folded into a rectangle above them. */
  const taken = new Uint8Array(c.w * c.h);
  const rects: Rect[] = [];

  for (let y = 0; y < c.h; y++) {
    let x = 0;
    while (x < c.w) {
      if (!missing(x, y) || taken[y * c.w + x] === 1) {
        x++;
        continue;
      }
      let width = 0;
      while (
        x + width < c.w && missing(x + width, y)
        && taken[y * c.w + x + width] === 0
      ) {
        width++;
      }
      /* Grow downward while the whole run repeats. A partial match stops
         the rectangle; the leftovers are picked up as their own runs when
         those rows come around. */
      let height = 1;
      while (y + height < c.h) {
        let same = true;
        for (let i = 0; i < width && same; i++) {
          same = missing(x + i, y + height)
            && taken[(y + height) * c.w + x + i] === 0;
        }
        if (!same) break;
        for (let i = 0; i < width; i++) {
          taken[(y + height) * c.w + x + i] = 1;
        }
        height++;
      }
      rects.push({ x: c.x + x, y: c.y + y, w: width, h: height });
      x += width;
    }
  }
  return rects;
}

/* Tile grid to degrees: the inverse of the Web Mercator projection the
   tiles were cut with, and the same arithmetic as Pmtiles.Tile_id on the
   server. x is a plain division; y goes through the Mercator inverse,
   which is why a rectangle's northern and southern edges cannot be
   interpolated and have to be projected one at a time. */
export const tileLon = (x: number, z: number) => (x / 2 ** z) * 360 - 180;

export const tileLat = (y: number, z: number) => {
  const n = Math.PI * (1 - (2 * y) / 2 ** z);
  return (Math.atan(Math.sinh(n)) * 180) / Math.PI;
};

/* Rectangles of tiles as map polygons. Each is a plain box in tile space,
   so four corners are enough -- no densification, because a tile edge IS a
   straight line in the projection the map is drawn in. */
export function rectsToFeatures(
  rects: Rect[],
  zoom: number,
): GeoJSON.Feature[] {
  return rects.map((r) => {
    const west = tileLon(r.x, zoom);
    const east = tileLon(r.x + r.w, zoom);
    /* y counts southward, so the rectangle's y is its NORTHERN edge. */
    const north = tileLat(r.y, zoom);
    const south = tileLat(r.y + r.h, zoom);
    return {
      type: "Feature" as const,
      properties: {},
      geometry: {
        type: "Polygon" as const,
        coordinates: [[
          [west, south],
          [east, south],
          [east, north],
          [west, north],
          [west, south],
        ]],
      },
    };
  });
}

/* The line where coverage ends.

   Not the outline of the rectangles above: two rectangles that split one
   blank area share a seam, and drawing that seam would put a line through
   the middle of nothing. What is real is the tile edge between a missing
   tile and a held one, so that is what this emits -- and only where BOTH
   sides were asked about. The edge of the query is not the edge of
   coverage; the map simply stops knowing there, and drawing a box around
   the viewport would be a claim nobody made.

   Runs of collinear edges are merged so the result is a handful of long
   lines rather than one stub per tile. */
export function blankEdges(c: Coverage, zoom: number): GeoJSON.Feature[] {
  const missing = (x: number, y: number) => c.present[y * c.w + x] === "0";
  const features: GeoJSON.Feature[] = [];

  const line = (
    a: [number, number],
    b: [number, number],
  ): GeoJSON.Feature => ({
    type: "Feature",
    properties: {},
    geometry: { type: "LineString", coordinates: [a, b] },
  });

  /* Horizontal edges: the boundary between row y-1 and row y. */
  for (let y = 1; y < c.h; y++) {
    let run = -1;
    for (let x = 0; x <= c.w; x++) {
      const edge = x < c.w && missing(x, y) !== missing(x, y - 1);
      if (edge && run < 0) run = x;
      if (!edge && run >= 0) {
        const lat = tileLat(c.y + y, zoom);
        features.push(
          line([tileLon(c.x + run, zoom), lat], [tileLon(c.x + x, zoom), lat]),
        );
        run = -1;
      }
    }
  }

  /* Vertical edges: the boundary between column x-1 and column x. */
  for (let x = 1; x < c.w; x++) {
    let run = -1;
    for (let y = 0; y <= c.h; y++) {
      const edge = y < c.h && missing(x, y) !== missing(x - 1, y);
      if (edge && run < 0) run = y;
      if (!edge && run >= 0) {
        const lon = tileLon(c.x + x, zoom);
        features.push(
          line([lon, tileLat(c.y + run, zoom)], [lon, tileLat(c.y + y, zoom)]),
        );
        run = -1;
      }
    }
  }
  return features;
}

/* Whether the middle of the view -- where the reticle sits, and what any
   note is about -- has no tile. Rounds toward the centre cell rather than
   averaging: an even-width viewport has no middle column, and either
   neighbour is the honest answer. */
export function centreIsBlank(c: Coverage): boolean {
  if (c.w <= 0 || c.h <= 0) return false;
  const x = Math.floor(c.w / 2);
  const y = Math.floor(c.h / 2);
  return c.present[y * c.w + x] === "0";
}

/* Nothing missing means nothing to draw, and the whole overlay stays off
   the map rather than adding an empty source to every style. */
export const fullyCovered = (c: Coverage): boolean => !c.present.includes("0");
