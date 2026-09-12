/* Where a glyph comes from, and whether it obeys the spec.

   This test used to say: icons come from one package, and no file may draw
   an <svg> unless it is listed here with a reason. That was the right rule
   while the set was lucide's. It caught nothing on its own -- the toast's
   dismiss control had already shipped as a hand-written cross beside the
   banner's lucide one, at a different stroke weight, and every test passed:
   the suite could see the control existed, was labelled, worked and held
   contrast. None of those asks "is it the same shape as the other one".

   The set is now the application's own, drawn in `components/icons.tsx` and
   specified in its header. So the promise is made the other way round: ONE
   file draws them all, and what is policed is the geometry rather than the
   location. A sixteenth glyph at the wrong stroke weight, on a stray angle,
   or with a round join fails here the way the cross should have. */

import { readFileSync } from "node:fs";
import { sourceFiles } from "./source.mjs";

let checks = 0;
let failures = 0;
const check = (name, ok) => {
  checks++;
  if (!ok) {
    failures++;
    console.log(`  FAIL  ${name}`);
  }
};

const files = sourceFiles(new URL("../src/", import.meta.url));
check("there is source to read", files.length > 0);

const set = readFileSync(
  new URL("../src/components/icons.tsx", import.meta.url),
  "utf8",
);

/* The one file allowed to draw a shape that is not an icon. A tooltip's
   arrow is geometry: React Aria positions the OverlayArrow and leaves the
   shape to the caller, and no icon set ships one. */
const allowed = new Map([
  [
    "components/icons.tsx",
    "the set itself",
  ],
  [
    "components/Tip.tsx",
    "the tooltip's arrow, which React Aria positions and leaves to the caller",
  ],
]);

const drawn = files.filter((f) => /<svg[\s>]/.test(f.text));
for (const f of drawn.map((f) => f.path).sort()) {
  check(
    `${f} draws a glyph by hand, which needs a reason here`,
    allowed.has(f),
  );
}
for (const path of [...allowed.keys()].sort()) {
  check(
    `${path} is still listed as drawing its own shape`,
    drawn.some((f) => f.path === path),
  );
}

/* The shared set is still here -- the plain palettes wear it -- but exactly
   one file may reach for it. Two files importing it is how a glyph starts
   being chosen at the call site instead of by the palette. */
const reaches = files
  .filter((f) => /from "lucide-react"/.test(f.text))
  .map((f) => f.path);
check(
  `only the set imports the shared one (${reaches.join(", ")})`,
  reaches.length === 1 && reaches[0] === "components/icons.tsx",
);

/* And the classification is written once. The stylesheet paints MapLibre's
   controls to match, and it reads the attribute rather than listing palette
   names of its own. */
const theme = files.find((f) => f.path === "theme.ts");
check(
  "which palettes are chamfered is said once, in theme.ts",
  /const CHAMFERED: readonly ResolvedTheme\[\]/.test(theme?.text ?? "")
    && /root.setAttribute\("data-icons", glyphSet\(/.test(theme?.text ?? ""),
);
check(
  "and the stylesheet reads that rather than naming palettes again",
  /\[data-icons="cut"\]/.test(
    readFileSync(new URL("../src/styles.css", import.meta.url), "utf8"),
  ),
);

/* ---- the box and the joinery, read off the one <svg> ---- */

const svg = set.slice(set.indexOf("<svg"), set.indexOf("</svg>"));
check("the box is 24 units", /viewBox="0 0 24 24"/.test(svg));
check("the stroke is 2 units", /strokeWidth=\{2\}/.test(svg));
check("caps are square, not round", /strokeLinecap="square"/.test(svg));
check("joins are mitred, not round", /strokeLinejoin="miter"/.test(svg));
check(
  "no glyph carries a colour of its own",
  /stroke="currentColor"/.test(svg) && /fill="none"/.test(svg),
);
check(
  "each glyph names itself, so a test can tell one from another",
  /data-glyph=\{name\}/.test(svg),
);
check(
  "a solid is filled with the text colour too",
  /fill: "currentColor", stroke: "none"/.test(set),
);

/* ---- the lattice, read off every path ---- */

/* Absolute commands only, so a relative `m` cannot smuggle in an angle the
   walk below reads as something else. */
const COMMANDS = /^[MHVLZ\s\-.\d]+$/;

const walk = (d) => {
  const tokens = d.match(/[A-Za-z]|-?\d*\.?\d+/g) ?? [];
  const subpaths = [];
  let segments = null;
  let cmd = null;
  let x = 0;
  let y = 0;
  let sx = 0;
  let sy = 0;
  let i = 0;
  const num = () => Number(tokens[i++]);
  while (i < tokens.length) {
    if (/[A-Za-z]/.test(tokens[i])) cmd = tokens[i++];
    /* An M followed by more coordinates is a polyline: every pair after the
       first is a lineto. */
    else if (cmd === "M") cmd = "L";
    if (cmd === "M") {
      if (segments) subpaths.push({ segments, closed: false });
      x = num();
      y = num();
      sx = x;
      sy = y;
      segments = [];
      continue;
    }
    if (cmd === "Z") {
      segments.push([x, y, sx, sy]);
      subpaths.push({ segments, closed: true });
      segments = null;
      x = sx;
      y = sy;
      continue;
    }
    const px = x;
    const py = y;
    if (cmd === "H") x = num();
    else if (cmd === "V") y = num();
    else {
      x = num();
      y = num();
    }
    segments.push([px, py, x, y]);
  }
  if (segments) subpaths.push({ segments, closed: false });
  return subpaths;
};

/* Horizontal, vertical, or exactly 45 degrees. Nothing else. */
const kind = ([ax, ay, bx, by]) => {
  const dx = bx - ax;
  const dy = by - ay;
  if (dx === 0 && dy === 0) return "point";
  if (dy === 0) return "h";
  if (dx === 0) return "v";
  if (Math.abs(dx) === Math.abs(dy)) return "d";
  return "off";
};

const table = set.slice(
  set.indexOf("const GLYPHS = {"),
  set.indexOf("} satisfies"),
);
const entries = [...table.matchAll(/^ {2}([A-Za-z]+): \[/gm)].map((m) => m[1]);
check("the table holds every glyph the app draws", entries.length === 16);

const paths = [...table.matchAll(/\{ d: "([^"]+)"(, f: 1)? \}/g)]
  .map((m) => ({ d: m[1], filled: m[2] !== undefined, where: "glyph" }));
check("and the paths parse out of it", paths.length >= 40);

const audit = ({ d, filled, where }) => {
  check(
    `${where} ${d} uses absolute lines only, no curve and no arc`,
    COMMANDS.test(d),
  );
  const subpaths = walk(d);
  const all = subpaths.flatMap((s) => s.segments);
  check(
    `${where} ${d} stays on the lattice`,
    all.length > 0 && all.every((s) => kind(s) !== "off"),
  );
  check(
    `${where} ${d} stays inside the box`,
    all.every((s) => s.every((n) => n >= 0 && n <= 24)),
  );

  /* The signature. A box that encloses cuts two corners, and it cuts them by
     the same 4 units the button does. A box is six segments: four on the
     axes and two diagonals. Nothing else is one -- the eye is a lens, four
     diagonals and no corners; the compass needle is a triangle. */
  for (const sub of subpaths) {
    const diagonals = sub.segments.filter((s) => kind(s) === "d");
    const axis = sub.segments.filter((s) => kind(s) === "h" || kind(s) === "v");
    if (!sub.closed || diagonals.length !== 2 || axis.length !== 4) continue;
    check(
      `${where} ${d} chamfers by 4 units, like the button it sits in`,
      diagonals.every(([ax, , bx]) => Math.abs(bx - ax) === 4),
    );
  }

  /* And a filled solid is a square on the lattice -- a pip at two units, a
     swatch at four -- never a circle and never a rounded one. A filled shape
     that is neither, the compass needle, says so. */
  if (!filled || filled === "solid") return;
  const [sub] = walk(d);
  const xs = sub.segments.flatMap(([ax, , bx]) => [ax, bx]);
  const ys = sub.segments.flatMap(([, ay, , by]) => [ay, by]);
  const w = Math.max(...xs) - Math.min(...xs);
  const h = Math.max(...ys) - Math.min(...ys);
  check(
    `${where} ${d} is a square solid, 2 units or 4 (${w}x${h})`,
    sub.closed && w === h && (w === 2 || w === 4)
      && sub.segments.every((s) => kind(s) === "h" || kind(s) === "v"),
  );
};

for (const path of paths) audit(path);

/* ---- and the four the stylesheet draws, for MapLibre's own controls ----

   They are masks in CSS rather than components, because the elements they
   paint are MapLibre's and this application never renders them. That is a
   place for a glyph to drift unwatched, so the same walk reads them out of
   the stylesheet and holds them to the same spec. */
const sheet = readFileSync(
  new URL("../src/styles.css", import.meta.url),
  "utf8",
);
const masks = [...sheet.matchAll(/--ctrl-glyph: url\("([^"]+)"\)/g)]
  .map((m) => decodeURIComponent(m[1]));
/* Five controls and seven declarations: the two that ENCLOSE -- the geolocate
   ring and the attribution's -- are drawn twice, plain and chamfered, because
   the chamfer is the one thing about these that is palette-deep. */
check(
  `the stylesheet draws the map's controls (${masks.length})`,
  masks.length === 7,
);

for (const mask of masks) {
  check(
    "a control glyph is drawn on the same 24-unit box",
    /viewBox='0 0 24 24'/.test(mask),
  );
  check(
    "at the same 2-unit stroke, square and mitred",
    /stroke-width='2'/.test(mask)
      && /stroke-linecap='square'/.test(mask)
      && /stroke-linejoin='miter'/.test(mask),
  );
  for (const m of mask.matchAll(/<path d='([^']+)'([^>]*)\/>/g)) {
    audit({
      d: m[1],
      filled: /fill=/.test(m[2]) ? "solid" : false,
      where: "control",
    });
  }
}

/* ---- and the table and the exports agree ---- */

const exported = [
  ...set.matchAll(/^export const (\w+) = glyph\("(\w+)", (\w+)\);$/gm),
];
check("every export names a glyph in the table", exported.length === 16);

/* Each of them pairs with one from the shared set, which is what the plain
   palettes render. A glyph with no counterpart draws nothing at all in three
   of the five palettes. */
const shared = new Set(
  [...set.matchAll(/^ {2}(\w+) as (Shared\w+),$/gm)].map((m) => m[2]),
);
check(
  `the shared set supplies sixteen too (${shared.size})`,
  shared.size === 16,
);
for (const [, name, , pair] of exported) {
  check(`${name} has a counterpart for the plain palettes`, shared.has(pair));
}
for (const [, name, key] of exported) {
  check(`${name} draws a glyph that exists`, entries.includes(key));
}
for (const key of entries) {
  check(`${key} is exported`, exported.some(([, , k]) => k === key));
}

/* Nothing renders a glyph it did not import from the set. */
const names = new Set([...exported.map(([, name]) => name), "IconSet"]);
for (const f of files) {
  if (f.path === "components/icons.tsx") continue;
  const imported = new Set(
    [...f.text.matchAll(
      /import \{([^}]*)\} from "\.\/?(?:components\/)?icons"/gs,
    )]
      .flatMap((m) => m[1].split(",").map((s) => s.trim()))
      .filter((s) => s.length > 0),
  );
  for (const name of imported) {
    check(`${f.path} imports ${name}, which the set exports`, names.has(name));
  }
}

console.log(`\nicons: ${checks} checks, ${failures} failures`);
if (failures > 0) process.exit(1);
