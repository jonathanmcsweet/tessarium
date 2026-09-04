/* Where a glyph is allowed to come from.

   Icons come from one set, so that a tick means the same thing everywhere and
   two dismiss controls on screen at once are the same shape. Hand-drawing one
   breaks that quietly: an SVG path with the wrong stroke width sits next to
   lucide's at a slightly different weight, and nothing fails -- it just looks
   like two applications.

   That is not hypothetical. The toast's dismiss control shipped as a
   hand-written cross while the banner beside it used the set's, and every
   test passed: the suite could see that a dismiss control existed, that it
   was labelled, that it worked, and that its colours held contrast. None of
   those is the question "is it the same X as the other X".

   So the source is read instead. A raw <svg> is not banned outright -- there
   is one shape the icon set has no business supplying -- but each one has to
   be named here with its reason, which turns "I drew a glyph" into an edit
   somebody has to justify rather than an omission nobody sees. */

import { readdirSync, readFileSync } from "node:fs";

let checks = 0;
let failures = 0;
const check = (name, ok) => {
  checks++;
  if (!ok) {
    failures++;
    console.log(`  FAIL  ${name}`);
  }
};

/* The shapes that are not icons, and why the icon set cannot supply them.

   A tooltip's arrow is geometry, not iconography: React Aria positions an
   OverlayArrow and leaves the shape to the caller, so the triangle that
   points at the button is part of the tooltip's construction. No icon set
   ships it, because it is not an icon. */
const allowed = new Map([
  [
    "components/IconButton.tsx",
    "the tooltip's arrow, which React Aria positions and leaves to the caller",
  ],
]);

const files = [];
const walk = (dir, prefix) => {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    /* Generated. Its contents are the message catalogues, not markup. */
    if (e.name === "paraglide") continue;
    const child = new URL(`${e.name}${e.isDirectory() ? "/" : ""}`, dir);
    if (e.isDirectory()) walk(child, `${prefix}${e.name}/`);
    else if (/\.tsx?$/.test(e.name)) {
      files.push({
        path: `${prefix}${e.name}`,
        text: readFileSync(child, "utf8"),
      });
    }
  }
};
walk(new URL("../src/", import.meta.url), "");

check("there is source to read", files.length > 0);

/* The set is in use at all -- if this ever went to zero the rule below would
   pass by drawing nothing. */
const usesSet = files.filter((f) => /from "lucide-react"/.test(f.text));
check("icons come from the shared set", usesSet.length > 0);

const drawn = files.filter((f) => /<svg[\s>]/.test(f.text));

for (const f of drawn.map((f) => f.path).sort()) {
  check(
    `${f} draws a glyph by hand, which needs a reason here`,
    allowed.has(f),
  );
}

/* And the other way: an exception that stopped being one should not stay on
   the list, or the list becomes a place where rules go to be forgotten. */
for (const path of [...allowed.keys()].sort()) {
  check(
    `${path} is still listed as drawing its own shape`,
    drawn.some((f) => f.path === path),
  );
}

console.log(`\nicons: ${checks} checks, ${failures} failures`);
if (failures > 0) process.exit(1);
