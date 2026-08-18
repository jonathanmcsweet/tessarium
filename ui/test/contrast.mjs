/* WCAG AA contrast, enforced.

   The palette lives in styles.css custom properties; this test recomputes
   every foreground/background pair the stylesheet actually uses and fails
   the build when one slips under its threshold -- an audit that runs once
   is an audit that rots. Pairs are listed by hand because resolving CSS
   cascade mechanically is a project of its own; the literal-presence checks
   below keep the list honest by failing when a listed colour leaves the
   stylesheet. */

import { readFileSync } from "node:fs";

const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");

let checks = 0;
let failures = 0;
const check = (name, ok) => {
  checks++;
  if (!ok) {
    failures++;
    console.log(`  FAIL  ${name}`);
  }
};

const vars = {};
for (const m of css.matchAll(/--([a-z-]+):\s*(#[0-9a-fA-F]{6});/g)) {
  vars[m[1]] = m[2];
}

const lum = (hex) => {
  const c = (i) => {
    const v = parseInt(hex.slice(i, i + 2), 16) / 255;
    return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * c(1) + 0.7152 * c(3) + 0.0722 * c(5);
};
const ratio = (a, b) => {
  const [hi, lo] = [lum(a), lum(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
};

const v = (name) => {
  const value = vars[name];
  check(`--${name} is defined`, Boolean(value));
  return value ?? "#000000";
};

/* [description, foreground, background, required ratio]. 4.5 is AA for
   normal text; 3.0 only where the text is always large -- the address line
   is 19px at weight 600, nothing else earns the lower bar. */
const pairs = [
  ["body text on the page", v("ink"), v("bg"), 4.5],
  ["body text on cards", v("ink"), v("card"), 4.5],
  ["hints on the page", v("ink-soft"), v("bg"), 4.5],
  ["hints on cards", v("ink-soft"), v("card"), 4.5],
  ["hints on inputs", v("ink-soft"), "#fbfcfd", 4.5],
  ["valid-checksum text", v("ok"), v("card"), 4.5],
  ["invalid text on cards", "#b4232a", v("card"), 4.5],
  ["invalid text on inputs", "#b4232a", "#fbfcfd", 4.5],
  ["button labels", "#ffffff", v("ink"), 4.5],
  ["disabled button labels", "#4c5b69", "#e3e8ed", 4.5],
  ["banner text", v("warn"), "#fff8e6", 4.5],
  ["banner action labels", "#ffffff", v("warn"), 4.5],
  ["map warning note", v("warn"), "#fffaf0", 4.5],
  ["hover rows", v("ink"), "#eef1f4", 4.5],
  [
    "the address line (19px, weight 600: large text)",
    v("accent"),
    v("card"),
    3.0,
  ],
];

for (const [name, fg, bg, min] of pairs) {
  const r = ratio(fg, bg);
  check(
    `${name}: ${fg} on ${bg} is ${r.toFixed(2)}:1 (needs ${min}:1)`,
    r >= min,
  );
}

/* The hand-written literals above must still exist in the stylesheet;
   otherwise the pair silently audits a colour nobody renders. */
for (
  const literal of [
    "#fbfcfd",
    "#b4232a",
    "#4c5b69",
    "#e3e8ed",
    "#fff8e6",
    "#fffaf0",
    "#eef1f4",
  ]
) {
  check(`${literal} still appears in styles.css`, css.includes(literal));
}

console.log(`\ncontrast: ${checks} checks, ${failures} failures`);
if (failures > 0) process.exit(1);
