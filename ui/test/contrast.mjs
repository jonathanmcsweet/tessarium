/* WCAG AA contrast, enforced.

   The palette lives in styles.css custom properties; this test recomputes
   every foreground/background pair the stylesheet actually uses and fails
   the build when one slips under its threshold -- an audit that runs once
   is an audit that rots. Pairs are listed by hand because resolving CSS
   cascade mechanically is a project of its own; the literal-presence checks
   below keep the list honest by failing when a listed colour leaves the
   stylesheet. */

import { readdirSync, readFileSync } from "node:fs";

const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");

/* Colours no longer live only in the stylesheet. The palette does -- it is
   the @theme block -- but a one-off shade is now written where it is spent,
   as a Tailwind arbitrary value in the component's class list. So the
   literal-presence check below reads the components too; otherwise moving a
   colour from a CSS rule to the element that uses it would read as deleting
   it. */
const srcDir = new URL("../src/", import.meta.url);
const sources = [css];
const walk = (dir) => {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (e.name === "paraglide") continue;
    const child = new URL(`${e.name}${e.isDirectory() ? "/" : ""}`, dir);
    if (e.isDirectory()) walk(child);
    else if (/\.tsx?$/.test(e.name)) sources.push(readFileSync(child, "utf8"));
  }
};
walk(srcDir);
const rendered = (literal) => sources.some((f) => f.includes(literal));

let checks = 0;
let failures = 0;
const check = (name, ok) => {
  checks++;
  if (!ok) {
    failures++;
    console.log(`  FAIL  ${name}`);
  }
};

/* The palette is the @theme block: `--color-ink` and friends, which is both
   the name Tailwind generates `text-ink` from and the name the app's own
   rules spend. Reading them here means the audit and the app cannot hold
   different opinions about what a colour is. */
const vars = {};
for (const m of css.matchAll(/--color-([a-z-]+):\s*(#[0-9a-fA-F]{6});/g)) {
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
  check(`--color-${name} is defined`, Boolean(value));
  return value ?? "#000000";
};

/* [description, foreground, background, required ratio]. 4.5 is AA for
   normal text; 3.0 is the non-text minimum, used here only for component
   borders and the accent's non-text roles. No large-text exemptions: the
   last one (the 19px address) died when a mobile media query shrank it. */
const pairs = [
  ["body text on the page", v("ink"), v("bg"), 4.5],
  ["body text on cards", v("ink"), v("card"), 4.5],
  ["hints on the page", v("ink-soft"), v("bg"), 4.5],
  ["hints on cards", v("ink-soft"), v("card"), 4.5],
  ["hints on inputs", v("ink-soft"), v("field"), 4.5],
  ["valid-checksum text", v("ok"), v("card"), 4.5],
  ["invalid text on cards", v("danger"), v("card"), 4.5],
  ["invalid text on inputs", v("danger"), v("field"), 4.5],
  ["button labels", "#ffffff", v("ink"), 4.5],
  ["disabled button labels", "#4c5b69", "#e3e8ed", 4.5],
  ["banner text", v("warn"), "#fff8e6", 4.5],
  ["banner action labels", "#ffffff", v("warn"), 4.5],
  ["map warning note", v("warn"), "#fffaf0", 4.5],
  /* The gate's provenance warning: the most prominent block on the unlock
     screen, and the one a user most needs to be able to read. */
  ["gate warning text", v("ink"), "#fff5f3", 4.5],
  ["gate warning rule (non-text)", v("accent"), "#fff5f3", 3.0],
  ["hover rows", v("ink"), "#eef1f4", 4.5],
  ["the address line", v("accent-text"), v("card"), 4.5],
  [
    "the accent as non-text (selection, checkboxes)",
    v("accent"),
    v("card"),
    3.0,
  ],
  ["input borders on cards (non-text)", v("line-strong"), v("card"), 3.0],
  ["input borders on their fill (non-text)", v("line-strong"), v("field"), 3.0],
  ["placeholder text on inputs", v("ink-soft"), v("field"), 4.5],
];

for (const [name, fg, bg, min] of pairs) {
  const r = ratio(fg, bg);
  check(
    `${name}: ${fg} on ${bg} is ${r.toFixed(2)}:1 (needs ${min}:1)`,
    r >= min,
  );
}

/* The hand-written literals above must still exist somewhere the app
   renders; otherwise the pair silently audits a colour nobody shows. The
   palette itself needs no such check -- `v()` fails when a token leaves the
   theme. */
for (
  const literal of [
    "#4c5b69",
    "#e3e8ed",
    "#fff8e6",
    "#fffaf0",
    "#eef1f4",
  ]
) {
  check(`${literal} is still rendered somewhere`, rendered(literal));
}

console.log(`\ncontrast: ${checks} checks, ${failures} failures`);
if (failures > 0) process.exit(1);
