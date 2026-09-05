/* The shell: the drawer, its splitter, and the marks drawn over the map.

   These are rules about how pieces of the application fit together, and each
   one here is a bug that shipped: a mark painted in a colour no palette owns,
   a control that opened something behind a closed door, a splitter that
   announced the opposite of what it did, a drag that rebuilt the application
   sixty times a second, and a cached answer that outlived the tiles it was
   about. None of them fails a type check or throws, which is why they are
   read out of the source here.

   Source is read as text, the same way night-flavor.mjs and icons.mjs read
   it: the thing being checked is a decision written in a file, not a value
   any runtime hands over. */

import { readFileSync } from "node:fs";

let checks = 0;
let failures = 0;
const check = (name, ok) => {
  checks++;
  if (!ok) {
    failures++;
    console.log(`  FAIL  ${name}`);
  }
};

const read = (path) =>
  readFileSync(new URL(`../src/${path}`, import.meta.url), "utf8");

const css = read("styles.css");
const mapView = read("components/MapView.tsx");
const store = read("store.ts");
const resizer = read("components/PanelResizer.tsx");

/* ------------------------------------------------- the keyboard reticle */

/* The square at the centre of the view marking which cell Enter will take.
   It is the only thing on screen that says so, and it was painted with a
   literal rgba(18, 33, 47, 0.55) -- the old light theme's ink -- while every
   other overlay colour moved into per-palette --color-map-* tokens. On three
   of the five palettes, the default among them, that is a near-black square
   on near-black cartography: the keyboard's one piece of feedback, invisible
   out of the box. An arbitrary Tailwind value is also structurally invisible
   to contrast.mjs, which audits tokens. */
const reticle = /className="(reticle[^"]*)"/.exec(mapView)?.[1] ?? "";
check("the reticle is drawn", reticle !== "");
check(
  `the reticle spends a palette token (${reticle.split(/\s+/).at(-1)})`,
  /\bborder-map-[a-z-]+\b/.test(reticle),
);
check(
  "and names no colour of its own",
  !/\[(?:#|rgba?\()/.test(reticle),
);

/* ------------------------------------------- opening the offline-maps card */

/* The card is drawn inside the drawer, and a shut drawer is translated off
   screen and made `invisible`. So opening the card without opening the drawer
   mounts it where nobody can see it -- which is what the missing-basemap
   banner's action did, and what the map's coverage-gap note did. The note's
   case was worse than nothing happening: the note hides itself once the card
   counts as open, so one press removed the note and showed nothing. */
/* The ACTION, not its type declaration: the state object a few lines below
   also carries `panelCollapsed: false`, as the drawer's starting value, and a
   pattern loose enough to reach it would pass whatever the action does. */
const openDownload =
  /openDownload:\s*\(\)\s*=>\s*set\(\{([^}]*)\}\)/.exec(store)?.[1] ?? "";
check("the store has an openDownload action", openDownload !== "");
check(
  `opening the download card also reveals the panel ({${openDownload}})`,
  /panelCollapsed:\s*false/.test(openDownload),
);

/* ----------------------------------------------------- the panel splitter */

/* WAI-ARIA's slider and window-splitter pattern: Home goes to the minimum
   announced value and End to the maximum. These were the other way round --
   spatially consistent with ArrowLeft widening a right-hand panel, but
   unstated, and the widget announces aria-valuenow, so a screen-reader user
   pressing Home heard the value jump to the maximum. */
const homeEnd = /event\.key === "Home"\s*\?\s*(\w+)\s*:\s*(\w+)/.exec(resizer);
check("Home and End jump to the ends of the range", homeEnd !== null);
check(
  `Home goes to the minimum (${homeEnd?.[1] ?? "?"})`,
  homeEnd?.[1] === "PANEL_MIN",
);
check(
  `End goes to the maximum (${homeEnd?.[2] ?? "?"})`,
  homeEnd?.[2] === "PANEL_MAX",
);

/* A pointer drag delivers a move about every frame. Each one used to be
   written to the store, and the root subscribes to the width to set two
   custom properties with children that are deliberately not memoised -- so
   every mouse move rebuilt the map's whole body and the entire panel to move
   two numbers. The drag paints the properties directly and the store hears
   the answer once, when the drag ends. */
check(
  "a drag paints the widths rather than routing every frame through the store",
  /setProperty\("--panel-w"/.test(resizer)
    && /setProperty\("--panel-offset"/.test(resizer),
);
check(
  "and commits the final width so the announced value follows",
  /onMoveEnd\(\)/.test(resizer) && /setPanelWidth\(/.test(resizer),
);

/* ------------------------------------------------- the place-search cache */

/* Search answers are cached for five minutes and nothing refetches on focus,
   so nothing but a deliberate invalidation would ever ask again. Download
   France after searching "Lyon" and the empty answer is served back from
   cache, from an install that has the tiles and cannot find them; remove a
   region and the index keeps answering for it. The jobs that move the tiles
   are the ones that must drop the cache. */
check(
  "a finished job drops the cached place-search answers",
  /invalidateQueries\(\{\s*queryKey:\s*\["place-search"\]/.test(mapView),
);

/* --------------------------------------- which palettes are light grounds */

/* One classification with two readers: the stylesheet, which inverts
   MapLibre's baked-in #333 control icons, and MapView, which picks the
   Protomaps flavour and the sprite sheet. It used to be written twice -- a
   hand-enumerated [data-theme] selector list here and a list of scheme names
   in TypeScript -- so a palette added to the palette blocks and not to the
   selector list ships light control icons on a dark map with nothing
   failing. That is the exact regression the dark theme's first release
   shipped. */
check(
  "the control icons take their inversion from the palette",
  /maplibregl-ctrl-icon\s*\{[^}]*var\(--map-light-ground\)/.test(css),
);
check(
  "and no rule names individual themes to opt them out",
  !/data-theme[^\n]*maplibregl-ctrl-icon/.test(css),
);
check(
  "MapView reads the same token rather than keeping its own list",
  /--map-light-ground/.test(mapView)
    && !/scheme === "cyber-light"/.test(mapView),
);
/* Six definitions: the default in @theme, the four chosen palettes, and
   plain dark's second copy for a dark device on "match my device".
   contrast.mjs's completeness check polices the same thing from the other
   side -- that no palette is missing a token the default has. */
check(
  "every palette block answers it",
  (css.match(/--map-light-ground:/g) ?? []).length === 6,
);

console.log(`\nshell: ${checks} checks, ${failures} failures`);
if (failures > 0) process.exit(1);
