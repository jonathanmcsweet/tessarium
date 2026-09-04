/* WCAG AA contrast, enforced.

   The palette lives in styles.css custom properties; this test recomputes
   every foreground/background pair the stylesheet actually uses and fails
   the build when one slips under its threshold -- an audit that runs once
   is an audit that rots. Pairs are listed by hand because resolving CSS
   cascade mechanically is a project of its own; the definedness checks
   below keep the list honest by failing when a listed colour leaves the
   stylesheet.

   Written as data in, results out: every check is a { name, ok } record in
   one list, and the only effects are the two prints and the exit code at
   the bottom. */

import { readdirSync, readFileSync } from "node:fs";

const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");

/* The components are read alongside the stylesheet, because a token is only
   audited honestly if something actually spends it -- and what spends it is
   a Tailwind class in a component, not a rule in here. */
const sourceFiles = (dir) =>
  readdirSync(dir, { withFileTypes: true })
    .filter((e) => e.name !== "paraglide")
    .flatMap((e) => {
      const child = new URL(`${e.name}${e.isDirectory() ? "/" : ""}`, dir);
      if (e.isDirectory()) return sourceFiles(child);
      return /\.tsx?$/.test(e.name) ? [readFileSync(child, "utf8")] : [];
    });
const sources = [css, ...sourceFiles(new URL("../src/", import.meta.url))];

const check = (name, ok) => ({ name, ok });

/* Five palettes, audited against the same thresholds.

   Cyberpunk dark is the @theme block, because it is the default and the
   default is what paints before any attribute is set. The rest are
   [data-theme] blocks. Plain dark is written twice -- once under
   [data-theme="dark"] and once under prefers-color-scheme for whoever chose
   "match my device" -- because CSS cannot say "the device prefers dark OR
   the user chose dark" in a single selector. Both are read, and they are
   required to agree. */

/* The index just past the brace that closes the block opening at `open`.
   A scan carried by reduce: the running state is the depth and the answer,
   and the answer, once found, is simply carried to the end. */
const blockEnd = (text, open) =>
  [...text.slice(open)].reduce(
    (state, c, i) =>
      state.end >= 0
        ? state
        : c === "{"
        ? { depth: state.depth + 1, end: -1 }
        : c === "}" && state.depth === 1
        ? { depth: 0, end: open + i }
        : c === "}"
        ? { depth: state.depth - 1, end: -1 }
        : state,
    { depth: 0, end: -1 },
  ).end;

/* A palette block's tokens. Two kinds: --color-* hex values, which the
   audits below can reason about, and --map-* numbers (the overlay wash's
   opacity), which join the completeness checks -- a number forgotten in one
   plain-dark block is the same class of bug as a colour. */
const block = (start) => {
  const from = css.indexOf(start);
  if (from < 0) return null;
  const open = css.indexOf("{", from + start.length - 1);
  const body = css.slice(open, blockEnd(css, open));
  return {
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

const cyberDark = block("@theme {");
const plainLight = block(':root[data-theme="system"],');
const plainDark = block(':root[data-theme="dark"] {');
const plainDarkDevice = block("@media (prefers-color-scheme: dark) {");
const cyberLight = block(':root[data-theme="cyber-light"] {');
const night = block(':root[data-theme="night"] {');

const presence = [
  check("the default palette is the @theme block", cyberDark !== null),
  check(
    "plain light exists, for the choice and for the device",
    plainLight !== null,
  ),
  check("plain dark exists for whoever chose it", plainDark !== null),
  check("and for a dark device on 'match my device'", plainDarkDevice !== null),
  check("cyberpunk light exists for whoever chose it", cyberLight !== null),
  check("the low-light palette exists for whoever chose it", night !== null),
];

const tokens = (p) => ({ ...(p?.colors ?? {}), ...(p?.numbers ?? {}) });
const names = (p) => Object.keys(tokens(p)).sort().join(",");

/* The duplication above is the whole reason for this check. Adding a token
   to one plain-dark block and not the other would leave half the
   application on the default's value, which reads as a bug in one theme and
   nowhere else. */
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

/* And every palette has to be complete. A token defined by the default and
   missing from a chosen theme does not fall back to something sensible --
   it falls back to the DEFAULT's value, so a plain theme would quietly wear
   one magenta. That is the failure this catches, and it is invisible on
   screen until it is the one token you are looking at. */
const palettes = [
  ["plain light", plainLight],
  ["plain dark", plainDark],
  ["cyberpunk light", cyberLight],
  ["low light", night],
];
const completeness = palettes.map(([label, palette]) =>
  check(
    `${label} defines every token the default does`,
    names(cyberDark) === names(palette),
  )
);

/* Low light exists to protect night vision, which is a property no contrast
   ratio can see: it fails the moment any token brings green or blue to the
   screen. Red-dominant, mechanically: no channel may beat red. Amber passes
   (r >= g > b); cyan and violet cannot. */
const channel = (hex, i) => parseInt(hex.slice(i, i + 2), 16);
const nightVision = Object.entries(night?.colors ?? {}).map(([name, hex]) =>
  check(
    `night: --color-${name} (${hex}) spends no light the dark should keep`,
    channel(hex, 1) >= channel(hex, 3) && channel(hex, 1) >= channel(hex, 5),
  )
);

/* The overlay wash's opacity travels with the palette. A value the CSS
   parses and MapLibre cannot spend -- empty, negative, past one -- would
   paint the coverage veil solid or not at all. */
const opacity = [["cyberpunk dark", cyberDark], ...palettes].map((
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
   AA for normal text; 3.0 is the non-text minimum, used here only for
   component borders and the accent's non-text roles. No large-text
   exemptions: the last one (the 19px address) died when a mobile media
   query shrank it. Token names, not values: the same sentence -- "hints on
   cards" -- is checked in light and in dark without the list knowing there
   are two. */
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
  /* The gate's provenance warning: the most prominent block on the unlock
     screen, and the one a user most needs to be able to read. */
  ["gate warning text", "ink", "alert", 4.5],
  ["gate warning rule (non-text)", "accent", "alert", 3.0],
  ["hover rows", "ink", "hover", 4.5],
  ["the address line", "accent-text", "card", 4.5],
  ["the accent as non-text (selection, checkboxes)", "accent", "card", 3.0],
  ["input borders on cards (non-text)", "line-strong", "card", 3.0],
  ["input borders on their fill (non-text)", "line-strong", "field", 3.0],
  ["placeholder text on inputs", "ink-soft", "field", 4.5],
  /* Direction C: the primary action is a three-stop gradient, so its label
     is audited against every stop -- the middle is the one that fails
     first. Outside the dark theme the stops are all one colour and these
     three collapse into the old solid-button check. */
  ["primary label on the gradient's first stop", "on-cta", "cta-from", 4.5],
  ["primary label on the gradient's middle", "on-cta", "cta-mid", 4.5],
  ["primary label on the gradient's last stop", "on-cta", "cta-to", 4.5],
  ["the address itself", "accent-alt", "card", 4.5],
  /* The one place the accent is a FILL behind text -- the confirm on the
     lock dialogue. It wore a literal `text-white`, which is a colour
     belonging to no palette and so audited in none of them: 3.95:1 in
     light, 3.03:1 in dark, 3.19:1 in low light, all of them under AA and
     none of them visible to this file until the pair was written down. */
  ["the label on a destructive button", "on-accent", "accent", 4.5],
];

/* Each pair is three checks: both tokens exist in the palette, and the
   ratio holds. A missing token still gets a ratio line -- computed against
   black, the way the old version did -- so one absence does not silence the
   pair that needed it. */
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

const audits = [["cyberpunk dark", cyberDark], ...palettes]
  .flatMap(([label, palette]) => audit(label, palette));

/* Every audited colour is a token now, which is what made a second palette
   possible at all: a pair naming a literal can only be checked in the theme
   that literal belongs to. So the old "is this shade still in the
   stylesheet" check is replaced by its point -- that each audited token is
   actually spent somewhere, as a Tailwind class, a var(), or a
   getComputedStyle read (the map overlay names its tokens as strings). A
   token nothing renders is an audit of nothing. */
const spentSomewhere = (token) =>
  sources.some((f) =>
    f.includes(`var(--color-${token})`)
    || new RegExp(`[-:\\[]${token}\\b`).test(f)
  );
const spent = Object.keys(tokens(cyberDark)).map((token) =>
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
