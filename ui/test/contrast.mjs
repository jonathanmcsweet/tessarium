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

/* The components are read alongside the stylesheet, because a token is only
   audited honestly if something actually spends it -- and what spends it is
   a Tailwind class in a component, not a rule in here. */
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

let checks = 0;
let failures = 0;
const check = (name, ok) => {
  checks++;
  if (!ok) {
    failures++;
    console.log(`  FAIL  ${name}`);
  }
};

/* Two palettes, audited against the same thresholds. The light one is the
   @theme block; the dark one is written twice -- once under
   prefers-color-scheme and once under [data-theme="dark"] -- because CSS
   cannot say "the device prefers dark OR the user chose dark" in a single
   selector. Both dark blocks are read, and they are required to agree. */
const block = (start) => {
  const from = css.indexOf(start);
  if (from < 0) return null;
  const open = css.indexOf("{", from + start.length - 1);
  let depth = 0;
  let i = open;
  for (; i < css.length; i++) {
    if (css[i] === "{") depth++;
    else if (css[i] === "}" && --depth === 0) break;
  }
  const body = css.slice(open, i);
  const out = {};
  for (const m of body.matchAll(/--color-([a-z-]+):\s*(#[0-9a-fA-F]{6});/g)) {
    out[m[1]] = m[2];
  }
  return out;
};

const light = block("@theme {");
const darkMedia = block("@media (prefers-color-scheme: dark) {");
const darkChosen = block(':root[data-theme="dark"] {');
const night = block(':root[data-theme="night"] {');

check("the light palette is the @theme block", light !== null);
check("the dark palette exists for a dark device", darkMedia !== null);
check("and for someone who chose it", darkChosen !== null);
check("the low-light palette exists for whoever chose it", night !== null);

/* The duplication above is the whole reason for this check. Adding a token
   to one dark block and not the other would leave half the application on
   the light value, which reads as a bug in one theme and nowhere else. */
const names = (o) => Object.keys(o ?? {}).sort().join(",");
check(
  "both dark blocks define exactly the same tokens",
  names(darkMedia) === names(darkChosen),
);
check(
  "with the same values",
  JSON.stringify(darkMedia) === JSON.stringify(darkChosen),
);
check(
  "and the dark set covers every token the light set defines",
  names(light) === names(darkMedia),
);
check(
  "and so does the low-light set",
  names(light) === names(night),
);

/* Low light exists to protect night vision, which is a property no contrast
   ratio can see: it fails the moment any token brings green or blue to the
   screen. Red-dominant, mechanically: no channel may beat red. Amber passes
   (r >= g > b); cyan and violet cannot. */
for (const [name, hex] of Object.entries(night ?? {})) {
  const ch = (i) => parseInt(hex.slice(i, i + 2), 16);
  check(
    `night: --color-${name} (${hex}) spends no light the dark should keep`,
    ch(1) >= ch(3) && ch(1) >= ch(5),
  );
}

let vars = light ?? {};

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
const pairs = () => [
  ["body text on the page", v("ink"), v("bg"), 4.5],
  ["body text on cards", v("ink"), v("card"), 4.5],
  ["hints on the page", v("ink-soft"), v("bg"), 4.5],
  ["hints on cards", v("ink-soft"), v("card"), 4.5],
  ["hints on inputs", v("ink-soft"), v("field"), 4.5],
  ["valid-checksum text", v("ok"), v("card"), 4.5],
  ["invalid text on cards", v("danger"), v("card"), 4.5],
  ["invalid text on inputs", v("danger"), v("field"), 4.5],
  ["button labels", v("on-ink"), v("ink"), 4.5],
  ["disabled button labels", v("on-disabled"), v("disabled"), 4.5],
  ["banner text", v("warn"), v("notice"), 4.5],
  ["banner action labels", v("on-ink"), v("warn"), 4.5],
  ["map warning note", v("warn"), v("notice-soft"), 4.5],
  /* The gate's provenance warning: the most prominent block on the unlock
     screen, and the one a user most needs to be able to read. */
  ["gate warning text", v("ink"), v("alert"), 4.5],
  ["gate warning rule (non-text)", v("accent"), v("alert"), 3.0],
  ["hover rows", v("ink"), v("hover"), 4.5],
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
  /* Direction C: the primary action is a three-stop gradient, so its label
     is audited against every stop -- the middle is the one that fails
     first. Outside the dark theme the stops are all one colour and these
     three collapse into the old solid-button check. */
  [
    "primary label on the gradient's first stop",
    v("on-cta"),
    v("cta-from"),
    4.5,
  ],
  ["primary label on the gradient's middle", v("on-cta"), v("cta-mid"), 4.5],
  ["primary label on the gradient's last stop", v("on-cta"), v("cta-to"), 4.5],
  ["the address itself", v("accent-alt"), v("card"), 4.5],
];

/* The pair list is written once and run against each palette. A colour is
   named by its token, so the same sentence -- "hints on cards" -- is checked
   in light and in dark without the list knowing there are two. */
const audit = (label, palette) => {
  vars = palette ?? {};
  for (const [name, fg, bg, min] of pairs()) {
    const r = ratio(fg, bg);
    check(
      `${label}: ${name}: ${fg} on ${bg} is ${r.toFixed(2)}:1 (needs ${min}:1)`,
      r >= min,
    );
  }
};
audit("light", light);
audit("dark", darkMedia);
audit("night", night);

/* Every audited colour is a token now, which is what made a second palette
   possible at all: a pair naming a literal can only be checked in the theme
   that literal belongs to. So the old "is this shade still in the
   stylesheet" check is replaced by its point -- that each audited token is
   actually spent somewhere, as a Tailwind class or a var(). A pair whose
   colour nothing renders is an audit of nothing. */
const spent = (token) =>
  sources.some((f) =>
    f.includes(`var(--color-${token})`)
    || new RegExp(`[-:\\[]${token}\\b`).test(f)
  );
for (const token of Object.keys(light ?? {})) {
  check(`--color-${token} is rendered somewhere`, spent(token));
}

console.log(`\ncontrast: ${checks} checks, ${failures} failures`);
if (failures > 0) process.exit(1);
