/* The shell: the drawer, its splitter, and the marks drawn over the map.

   Each check here is a bug that shipped, and none of them fails a type check
   or throws. Source is read as text, like night-flavor.mjs and icons.mjs. */

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

/* The mark saying which cell Enter takes. It was a literal rgba(18, 33, 47,
   0.55): near-black on the near-black default palette, and invisible to
   contrast.mjs, which audits tokens. */
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

/* A shut drawer is translated off screen and `invisible`, so opening the card
   without opening the drawer mounts it where nobody can see it. */
/* The ACTION, not the state object below, which carries the same field. */
const openDownload =
  /openDownload:\s*\(\)\s*=>\s*set\(\{([^}]*)\}\)/.exec(store)?.[1] ?? "";
check("the store has an openDownload action", openDownload !== "");
check(
  `opening the download card also reveals the panel ({${openDownload}})`,
  /panelCollapsed:\s*false/.test(openDownload),
);

/* ----------------------------------------------------- the panel splitter */

/* WAI-ARIA: Home goes to the minimum announced value, End to the maximum.
   These were reversed, so Home announced a jump to the widest. */
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

/* A drag delivers a move a frame, and the root's children are deliberately
   not memoised. Paint the property; tell the store once, at the end.

   One property, not two. What each edge of the map has under it is derived
   from the panel's width in styles.css, where the breakpoint is -- a second
   hand painting the derived answer here is how the answer came to disagree
   with the layout on a phone. */
check(
  "a drag paints the width rather than routing every frame through the store",
  /setProperty\("--panel-w"/.test(resizer),
);
check(
  "and paints only the width, leaving the covered edges to be derived",
  !/setProperty\("--panel-offset"/.test(resizer),
);
check(
  "and commits the final width so the announced value follows",
  /onMoveEnd\(\)/.test(resizer) && /setPanelWidth\(/.test(resizer),
);

/* ------------------------------------------------- the place-search cache */

/* Answers cache for five minutes with no refetch on focus, so nothing but a
   deliberate invalidation asks again. The jobs that move tiles must drop it. */
check(
  "a finished job drops the cached place-search answers",
  /invalidateQueries\(\{\s*queryKey:\s*\["place-search"\]/.test(mapView),
);

/* --------------------------------------- which palettes are light grounds */

/* One classification, two readers: the stylesheet inverts MapLibre's baked-in
   control icons, MapView picks the flavour and sprite sheet. Written twice, a
   new palette silently falls off one of the lists. */
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
    && !/scheme === "edge-light"/.test(mapView),
);
/* Six: the @theme default, the four palettes, and plain dark's second copy
   for a dark device on "match my device". */
check(
  "every palette block answers it",
  (css.match(/--map-light-ground:/g) ?? []).length === 6,
);

/* ------------------------------------------- the splitter's width clamp */

/* The drag paints the width and the store commits it; they agree only because
   both call this function. Evaluated out of the source because node cannot
   import store.ts, and grepping for the name would miss the arithmetic
   changing under it. */
const bounds = {
  min: Number(/export const PANEL_MIN = (\d+)/.exec(store)?.[1]),
  max: Number(/export const PANEL_MAX = (\d+)/.exec(store)?.[1]),
};
const clampSource = /export const clampPanelWidth = \([^)]*\)[^=]*=>\s*([^;]+);/
  .exec(store)?.[1];

check(
  "the panel bounds and the clamp are all readable from the store",
  Number.isFinite(bounds.min) && Number.isFinite(bounds.max)
    && bounds.min < bounds.max && typeof clampSource === "string",
);

if (clampSource) {
  const clamp = new Function(
    "PANEL_MIN",
    "PANEL_MAX",
    `return (width) => ${clampSource};`,
  )(bounds.min, bounds.max);

  check(
    `a drag past the narrow end stops at ${bounds.min}`,
    clamp(bounds.min - 1) === bounds.min && clamp(-9999) === bounds.min,
  );
  check(
    `a drag past the wide end stops at ${bounds.max}`,
    clamp(bounds.max + 1) === bounds.max && clamp(9999) === bounds.max,
  );
  check(
    "a width inside the range is kept",
    clamp(bounds.min) === bounds.min && clamp(bounds.max) === bounds.max
      && clamp(400) === 400,
  );
  check(
    "a fractional drag lands on a whole pixel",
    clamp(400.4) === 400 && clamp(400.6) === 401
      && Number.isInteger(clamp(bounds.min + 0.5)),
  );
}

/* Through the store's clamp, not a second copy of it. */
check(
  "the resizer clamps through the store, not a second copy",
  /clampPanelWidth/.test(resizer) && !/Math\.min\(\s*PANEL_MAX/.test(resizer),
);

console.log(`\nshell: ${checks} checks, ${failures} failures`);
if (failures > 0) process.exit(1);
