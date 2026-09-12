/* WCAG AA contrast, enforced.

   The palette lives in styles.css custom properties. This recomputes every
   foreground/background pair the stylesheet uses and fails the build when one
   slips under its threshold. Pairs are listed by hand because resolving the
   CSS cascade mechanically is a project of its own; the definedness checks
   below keep the list honest by failing when a listed colour leaves the
   stylesheet. */

import { readFileSync } from "node:fs";
import { blockEnd, sourceFiles } from "./source.mjs";

const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");

/* Components are read alongside the stylesheet: a token is only audited
   honestly if something spends it, and what spends it is a Tailwind class in
   a component, not a rule in the stylesheet. */
const sources = [
  css,
  ...sourceFiles(new URL("../src/", import.meta.url)).map((f) => f.text),
];

const check = (name, ok) => ({ name, ok });

/* Five palettes, audited against the same thresholds.

   Edgerunner dark is the @theme block: it is the default, and the default
   paints before any attribute is set. The rest are [data-theme] blocks. Plain
   dark is written twice -- under [data-theme="dark"] and under
   prefers-color-scheme, for whoever chose "match my device" -- because CSS
   cannot say "the device prefers dark OR the user chose dark" in one
   selector. Both are read, and both must agree. */

/* A palette block's tokens: --color-* hex values, and --map-* numbers (the
   overlay wash's opacity). The numbers join the completeness checks -- a
   number forgotten in one plain-dark block is the same bug as a colour. */
const block = (start) => {
  const from = css.indexOf(start);
  if (from < 0) return null;
  const open = css.indexOf("{", from + start.length - 1);
  const body = css.slice(open, blockEnd(css, open));
  return {
    body,
    colors: Object.fromEntries(
      [...body.matchAll(/--color-([a-z-]+):\s*(#[0-9a-fA-F]{6});/g)]
        .map((m) => [m[1], m[2]]),
    ),
    numbers: Object.fromEntries(
      [...body.matchAll(/--map-([a-z-]+):\s*([\d.]+);/g)]
        .map((m) => [`map-${m[1]}`, Number(m[2])]),
    ),
  };
};

const edgeDark = block("@theme {");
const plainLight = block(':root[data-theme="system"],');
const plainDark = block(':root[data-theme="dark"] {');
const plainDarkDevice = block("@media (prefers-color-scheme: dark) {");
const edgeLight = block(':root[data-theme="edge-light"] {');
const night = block(':root[data-theme="night"] {');

const presence = [
  check("the default palette is the @theme block", edgeDark !== null),
  check(
    "plain light exists, for the choice and for the device",
    plainLight !== null,
  ),
  check("plain dark exists for whoever chose it", plainDark !== null),
  check("and for a dark device on 'match my device'", plainDarkDevice !== null),
  check("edgerunner light exists for whoever chose it", edgeLight !== null),
  check("the low-light palette exists for whoever chose it", night !== null),
];

const tokens = (p) => ({ ...(p?.colors ?? {}), ...(p?.numbers ?? {}) });
const names = (p) => Object.keys(tokens(p)).sort().join(",");

/* Adding a token to one plain-dark block and not the other leaves half the
   app on the default's value, which reads as a bug in one theme only. */
const agreement = [
  check(
    "both plain-dark blocks define exactly the same tokens",
    names(plainDark) === names(plainDarkDevice),
  ),
  check(
    "with the same values",
    JSON.stringify(tokens(plainDark))
      === JSON.stringify(tokens(plainDarkDevice)),
  ),
];

/* And every palette has to be complete. A token missing from a chosen theme
   does not fall back to something sensible -- it falls back to the DEFAULT's
   value, so a plain theme wears one magenta. Invisible on screen until it is
   the token you are looking at. */
const palettes = [
  ["plain light", plainLight],
  ["plain dark", plainDark],
  ["edgerunner light", edgeLight],
  ["low light", night],
];
const completeness = palettes.map(([label, palette]) =>
  check(
    `${label} defines every token the default does`,
    names(edgeDark) === names(palette),
  )
);

/* The cut corner: the shape half of the edgerunner look, a chamfer off the
   top-right and bottom-left of every button. It is a palette token rather
   than a constant so that a palette can put it down, and the plain three do
   -- a bevelled button is not a plain button.

   Read as text, not resolved. "At rest" here means the block SAYS none: a
   palette that says nothing about the cut inherits the default's chamfer,
   which is exactly the bug this catches. Edgerunner light is the one palette
   that should stay silent, because it is meant to keep it. */
const cutAtRest = (p) =>
  /--cut:\s*none;/.test(p?.body ?? "")
  && /--cut-icon:\s*none;/.test(p?.body ?? "");

const corners = [
  check(
    "the default palette cuts its corners",
    /--cut:\s*polygon\(/.test(edgeDark?.body ?? "")
      && /--cut-icon:\s*polygon\(/.test(edgeDark?.body ?? ""),
  ),
  ...[
    ["plain light", plainLight],
    ["plain dark", plainDark],
    ["plain dark on a dark device", plainDarkDevice],
    ["low light", night],
  ].map(([label, palette]) =>
    check(`${label} squares them instead`, cutAtRest(palette))
  ),
  check(
    "edgerunner light says nothing, and so keeps the default's",
    edgeLight !== null && !/--cut/.test(edgeLight.body),
  ),
];

/* Low light protects night vision, which no contrast ratio can see: it fails
   the moment a token brings green or blue to the screen. Red-dominant,
   mechanically: no channel may beat red. Amber passes (r >= g > b); cyan and
   violet cannot. */
const channel = (hex, i) => parseInt(hex.slice(i, i + 2), 16);
const nightVision = Object.entries(night?.colors ?? {}).map(([name, hex]) =>
  check(
    `night: --color-${name} (${hex}) spends no light the dark should keep`,
    channel(hex, 1) >= channel(hex, 3) && channel(hex, 1) >= channel(hex, 5),
  )
);

/* The overlay wash's opacity travels with the palette. A value the CSS parses
   and MapLibre cannot spend -- empty, negative, past one -- paints the
   coverage veil solid or not at all. */
const opacity = [["edgerunner dark", edgeDark], ...palettes].map((
  [label, palette],
) =>
  check(
    `${label}: the wash opacity is a number in (0, 1]`,
    (() => {
      const value = palette?.numbers["map-blank-opacity"];
      return typeof value === "number" && value > 0 && value <= 1;
    })(),
  )
);

const lum = (hex) => {
  const c = (i) => {
    const v = channel(hex, i) / 255;
    return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * c(1) + 0.7152 * c(3) + 0.0722 * c(5);
};
const ratio = (a, b) => {
  const [hi, lo] = [lum(a), lum(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
};

/* [description, foreground token, background token, required ratio]. 4.5 is
   AA for normal text; 3.0 is the non-text minimum, used only for component
   borders and the accent's non-text roles. No large-text exemptions: the last
   one (the 19px address) died when a mobile media query shrank it. Token
   names, not values, so one entry covers every palette. */
const PAIRS = [
  ["body text on the page", "ink", "bg", 4.5],
  ["body text on cards", "ink", "card", 4.5],
  ["hints on the page", "ink-soft", "bg", 4.5],
  ["hints on cards", "ink-soft", "card", 4.5],
  ["hints on inputs", "ink-soft", "field", 4.5],
  ["valid-checksum text", "ok", "card", 4.5],
  ["invalid text on cards", "danger", "card", 4.5],
  ["invalid text on inputs", "danger", "field", 4.5],
  ["button labels", "on-ink", "ink", 4.5],
  ["disabled button labels", "on-disabled", "disabled", 4.5],
  ["banner text", "warn", "notice", 4.5],
  ["banner action labels", "on-ink", "warn", 4.5],
  ["map warning note", "warn", "notice-soft", 4.5],
  /* The unlock screen's write-it-down notice -- its most prominent block,
     and the one a user most needs to read. */
  ["gate warning text", "ink", "alert", 4.5],
  ["gate warning rule (non-text)", "accent", "alert", 3.0],
  ["hover rows", "ink", "hover", 4.5],
  ["the address line", "accent-text", "card", 4.5],
  ["the accent as non-text (selection, checkboxes)", "accent", "card", 3.0],
  ["input borders on cards (non-text)", "line-strong", "card", 3.0],
  ["input borders on their fill (non-text)", "line-strong", "field", 3.0],
  ["placeholder text on inputs", "ink-soft", "field", 4.5],
  /* The primary action is a three-stop gradient, so its label is audited
     against every stop; the middle fails first. Outside the dark theme the
     stops are one colour and these three collapse into one check. */
  ["primary label on the gradient's first stop", "on-cta", "cta-from", 4.5],
  ["primary label on the gradient's middle", "on-cta", "cta-mid", 4.5],
  ["primary label on the gradient's last stop", "on-cta", "cta-to", 4.5],
  ["the address itself", "accent-alt", "card", 4.5],
  /* The one place the accent is a FILL behind text: the confirm on the lock
     dialogue. It wore a literal `text-white`, which belongs to no palette and
     so was audited in none: 3.95:1 light, 3.03:1 dark, 3.19:1 low light, all
     under AA and none visible here until this pair was written down. */
  /* The mark on the selected square, which MapView reads off the token and
     hands to MapLibre. It was the label on the destructive button too, until
     that button took the primary action's gradient. */
  ["the mark on the selected square", "on-accent", "accent", 4.5],
];

/* Each pair is three checks: both tokens exist, and the ratio holds. A
   missing token still gets a ratio line, computed against black, so one
   absence does not silence the pair that needed it. */
const audit = (label, palette) =>
  PAIRS.flatMap(([name, fg, bg, min]) => {
    const value = (token) => palette?.colors[token] ?? "#000000";
    const r = ratio(value(fg), value(bg));
    return [
      check(`--color-${fg} is defined`, Boolean(palette?.colors[fg])),
      check(`--color-${bg} is defined`, Boolean(palette?.colors[bg])),
      check(
        `${label}: ${name}: ${value(fg)} on ${value(bg)} is ${
          r.toFixed(2)
        }:1 (needs ${min}:1)`,
        r >= min,
      ),
    ];
  });

const audits = [["edgerunner dark", edgeDark], ...palettes]
  .flatMap(([label, palette]) => audit(label, palette));

/* Every audited colour is a token, which is what made a second palette
   possible: a pair naming a literal can only be checked in the theme that
   literal belongs to. So each audited token must be spent somewhere -- a
   Tailwind class, a var(), or a getComputedStyle read (the map overlay names
   its tokens as strings). A token nothing renders is an audit of nothing. */
const spentSomewhere = (token) =>
  sources.some((f) =>
    f.includes(`var(--color-${token})`)
    || new RegExp(`[-:\\[]${token}\\b`).test(f)
  );
const spent = Object.keys(tokens(edgeDark)).map((token) =>
  check(
    `--${
      token.startsWith("map-") ? "" : "color-"
    }${token} is rendered somewhere`,
    spentSomewhere(token),
  )
);

const results = [
  ...presence,
  ...agreement,
  ...completeness,
  ...corners,
  ...nightVision,
  ...opacity,
  ...audits,
  ...spent,
];
const failures = results.filter((r) => !r.ok);
failures.forEach((f) => {
  console.log(`  FAIL  ${f.name}`);
});
console.log(
  `\ncontrast: ${results.length} checks, ${failures.length} failures`,
);
if (failures.length > 0) process.exit(1);
