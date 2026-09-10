/* Where a glyph is allowed to come from.

   Icons come from one set, so a tick means the same thing everywhere. Drawing
   one by hand breaks that quietly: an SVG path with the wrong stroke width
   sits next to lucide's at a slightly different weight, nothing fails, and
   the screen looks like two applications.

   That happened. The toast's dismiss control shipped as a hand-written cross
   while the banner beside it used the set's, and every test passed: the suite
   could see the control existed, was labelled, worked, and held contrast.
   None of those asks "is it the same shape as the other one".

   So the source is read. A raw <svg> is allowed, but each file that draws one
   must be listed below with its reason. */

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

/* The shapes that are not icons, and why the set cannot supply them.

   A tooltip's arrow is geometry, not iconography: React Aria positions the
   OverlayArrow and leaves the shape to the caller. No icon set ships one. */
const allowed = new Map([
  [
    "components/Tip.tsx",
    "the tooltip's arrow, which React Aria positions and leaves to the caller",
  ],
]);

const files = sourceFiles(new URL("../src/", import.meta.url));

check("there is source to read", files.length > 0);

/* The set is in use at all. At zero, the rule below would pass by drawing
   nothing. */
const usesSet = files.filter((f) => /from "lucide-react"/.test(f.text));
check("icons come from the shared set", usesSet.length > 0);

const drawn = files.filter((f) => /<svg[\s>]/.test(f.text));

for (const f of drawn.map((f) => f.path).sort()) {
  check(
    `${f} draws a glyph by hand, which needs a reason here`,
    allowed.has(f),
  );
}

/* And the other way: an exception that stopped being one must leave the
   list, or the list becomes where rules go to be forgotten. */
for (const path of [...allowed.keys()].sort()) {
  check(
    `${path} is still listed as drawing its own shape`,
    drawn.some((f) => f.path === path),
  );
}

console.log(`\nicons: ${checks} checks, ${failures} failures`);
if (failures > 0) process.exit(1);
