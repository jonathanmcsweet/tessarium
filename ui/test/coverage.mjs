/* The coverage overlay's arithmetic.

   Nothing here touches a browser: the merge and the projection are pure,
   and they are exactly the parts where a plausible-looking loop is wrong
   by one tile. The end-to-end test then checks that what is drawn matches
   what the server will actually serve; this checks that the shapes are
   right in the first place.

   Node runs the TypeScript directly -- type stripping, no build step --
   so the module under test is the module the app ships. */

import {
  absentRects,
  blankEdges,
  centreIsBlank,
  fullyCovered,
  rectsToFeatures,
  tileLat,
  tileLon,
} from "../src/core/coverage.ts";

let checks = 0;
let failures = 0;
const check = (name, ok) => {
  checks++;
  if (!ok) {
    failures++;
    console.log(`  FAIL  ${name}`);
  }
};

/* A coverage answer from a picture: rows of "." (present) and "#" (missing),
   which makes the expected shapes readable in the test itself. */
const from = (rows, x = 0, y = 0, zoom = 12, depth = 12) => ({
  zoom,
  x,
  y,
  w: rows[0].length,
  h: rows.length,
  present: rows.join("").replaceAll(".", "1").replaceAll("#", "0"),
  depth,
});

/* ------------------------------------------------------------- nothing */

check(
  "a fully covered view has nothing to draw",
  (() => {
    const c = from(["...", "..."]);
    return absentRects(c).length === 0 && fullyCovered(c);
  })(),
);

check("one missing tile is not fully covered", !fullyCovered(from([".#."])));

/* --------------------------------------------------------- whole blocks */

check(
  "a wholly blank view is one rectangle",
  (() => {
    const [r, ...rest] = absentRects(from(["###", "###"]));
    return rest.length === 0 && r.x === 0 && r.y === 0 && r.w === 3
      && r.h === 2;
  })(),
);

check(
  "the rectangle is in the server's tile coordinates, not the string's",
  (() => {
    const [r] = absentRects(from(["##", "##"], 1000, 700));
    return r.x === 1000 && r.y === 700 && r.w === 2 && r.h === 2;
  })(),
);

check(
  "a straight edge collapses to one rectangle",
  (() => {
    const rects = absentRects(from(["..##", "..##", "..##"]));
    return rects.length === 1 && rects[0].x === 2 && rects[0].w === 2
      && rects[0].h === 3;
  })(),
);

/* ------------------------------------------------------------- partitions */

/* The invariant that matters, whatever the merge does internally: the
   rectangles cover every missing tile, exactly once, and no present one.
   Checked over a set of awkward pictures -- an L, a hole, a diagonal, a
   checkerboard, which is the worst case a greedy merge can meet. */
const pictures = [
  ["#..", "#..", "###"],
  ["###", "#.#", "###"],
  ["#..", ".#.", "..#"],
  ["#.#.", ".#.#", "#.#.", ".#.#"],
  ["####", "#..#", "#..#", "####"],
  ["....", "....", "....", "...#"],
];
for (const rows of pictures) {
  const c = from(rows, 5, 9);
  const rects = absentRects(c);
  const seen = new Map();
  let overlap = false;
  for (const r of rects) {
    if (r.w <= 0 || r.h <= 0) overlap = true;
    for (let dy = 0; dy < r.h; dy++) {
      for (let dx = 0; dx < r.w; dx++) {
        const k = `${r.x + dx},${r.y + dy}`;
        if (seen.has(k)) overlap = true;
        seen.set(k, true);
      }
    }
  }
  let exact = !overlap;
  for (let y = 0; y < c.h && exact; y++) {
    for (let x = 0; x < c.w && exact; x++) {
      const missing = c.present[y * c.w + x] === "0";
      exact = seen.has(`${c.x + x},${c.y + y}`) === missing;
    }
  }
  check(`the rectangles partition the missing tiles: ${rows.join("/")}`, exact);
}

/* ------------------------------------------------------------ projection */

/* Fixed points of Web Mercator, which is what the tile grid is cut on. The
   server computes the same numbers in Pmtiles.Tile_id; the end-to-end test
   is where the two are compared against each other. */
const near = (a, b) => Math.abs(a - b) < 1e-9;

check(
  "the world tile spans the whole longitude range",
  tileLon(0, 0) === -180 && tileLon(1, 0) === 180,
);
check("zoom 1 splits at the prime meridian", tileLon(1, 1) === 0);
check("zoom 2 quarters the world", near(tileLon(1, 2), -90));
check(
  "the projection stops at the Mercator limit",
  Math.abs(tileLat(0, 0) - 85.0511287798066) < 1e-9,
);
check("the equator is the middle row", near(tileLat(1, 1), 0));
check(
  "a northern band lands where Mercator puts it",
  Math.abs(tileLat(1, 2) - 66.51326044311186) < 1e-9,
);

check(
  "a rectangle becomes a closed box, corner by corner",
  (() => {
    /* Vertex by vertex rather than by min and max: those are the same set
       whichever way round north and south are, so the earlier spelling of
       this check could not see a rectangle drawn upside down. */
    const [f] = rectsToFeatures([{ x: 0, y: 0, w: 1, h: 1 }], 1);
    const ring = f.geometry.coordinates[0];
    const top = 85.0511287798066;
    const want = [[-180, 0], [0, 0], [0, top], [-180, top], [-180, 0]];
    return ring.length === 5
      && want.every(([lon, lat], i) =>
        near(ring[i][0], lon) && Math.abs(ring[i][1] - lat) < 1e-9
      );
  })(),
);

/* ----------------------------------------------------------------- edges */

/* The edge features are line segments in degrees; counting them is not the
   point, so these check the two properties that matter: an edge appears
   exactly where held meets missing, and never along the border of the
   query itself, where nothing is known about the far side. */

check(
  "a fully covered view has no edge",
  blankEdges(from(["..", ".."]), 12).length === 0,
);
check(
  "a wholly blank view has no edge either -- the query border is not one",
  blankEdges(from(["##", "##"]), 12).length === 0,
);

check(
  "a straight coverage edge is one line, not one stub per tile",
  (() => {
    const edges = blankEdges(from(["..##", "..##", "..##"]), 12);
    return edges.length === 1
      && edges[0].geometry.coordinates.length === 2;
  })(),
);

check(
  "the edge runs the full height of the boundary",
  (() => {
    const [e] = blankEdges(from(["..##", "..##", "..##"], 0, 0, 2), 2);
    const [[x1, y1], [x2, y2]] = e.geometry.coordinates;
    return x1 === x2 && x1 === tileLon(2, 2)
      && near(y1, tileLat(0, 2)) && near(y2, tileLat(3, 2));
  })(),
);

check(
  "a horizontal edge sits on the tile row it separates",
  (() => {
    /* Nothing pinned this before: every edge check used a vertical
       boundary or counted features, so moving each horizontal edge one row
       south passed the whole suite while drawing the coverage line
       kilometres away from the coverage. */
    const [e] = blankEdges(from(["..", "##"], 0, 0, 3), 3);
    const [[, y1], [, y2]] = e.geometry.coordinates;
    return near(y1, tileLat(1, 3)) && near(y2, tileLat(1, 3));
  })(),
);

check(
  "a hole in coverage is outlined on all four sides",
  (() => {
    /* One missing tile surrounded by held ones: two horizontal edges and two
     vertical, each one tile long. */
    const edges = blankEdges(from(["...", ".#.", "..."]), 12);
    return edges.length === 4;
  })(),
);

check(
  "a boundary stays one line where the blank side swaps across it",
  (() => {
    /* 2x2 alternating. Both internal boundaries are continuous -- held meets
     missing along their whole length -- even though which side is blank
     flips halfway, so each is one merged line rather than two stubs. */
    const edges = blankEdges(from(["#.", ".#"]), 12);
    const spans = edges.map((e) => e.geometry.coordinates);
    return edges.length === 2
      && spans.every(([a, b]) => a[0] !== b[0] || a[1] !== b[1]);
  })(),
);

/* ---------------------------------------------------------------- centre */

/* The middle is decided by the depth the server measured at that very
   cell, not by re-reading the mask here: the two spellings disagree about
   which tile is "the middle" often enough to put a false sentence on
   screen, so there is one authority and this is it. */
check(
  "a middle shallower than the zoom on screen is blank",
  centreIsBlank({ ...from(["###"]), zoom: 12, depth: 6 }),
);
check(
  "a middle as deep as the zoom on screen is not",
  !centreIsBlank({ ...from(["###"]), zoom: 12, depth: 12 }),
);
check(
  "nor is one deeper still -- an archive can hold more than is drawn",
  !centreIsBlank({ ...from(["###"]), zoom: 10, depth: 15 }),
);
check(
  "an archive with nothing here at all is blank",
  centreIsBlank({ ...from(["..."]), zoom: 0, depth: -1 }),
);

console.log(`\n${checks} checks, ${failures} failures`);
console.log(failures === 0 ? "coverage shapes hold" : "coverage shapes FAILED");
process.exit(failures === 0 ? 0 : 1);
