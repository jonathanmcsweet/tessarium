/* The low-light map's flavour overrides, checked against the real flavour.

   MapView tints Protomaps' "black" flavour for the low-light theme: roads a
   little warmer, labels from grey toward soft red. Each override is keyed by a
   flavour property name. A name that does not exist in the flavour throws
   nothing -- the spread carries a key nothing reads, and the map stays cold
   exactly where the override was meant to warm it. water_label and peak_label
   were both such typos.

   The keys are read out of MapView.tsx as text, the way contrast.mjs reads
   styles.css: one source of truth. */

import { namedFlavor } from "@protomaps/basemaps";
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

const src = readFileSync(
  new URL("../src/components/MapView.tsx", import.meta.url),
  "utf8",
);

/* The `KEY: "#rrggbb"` pairs inside a named `const NAME = { ... }` literal. */
const table = (name) => {
  const at = src.indexOf(`const ${name} = {`);
  if (at < 0) return null;
  const body = src.slice(at, src.indexOf("}", at));
  return [...body.matchAll(/(\w+):\s*"(#[0-9a-fA-F]{6})"/g)]
    .map((m) => [m[1], m[2]]);
};

const roads = table("NIGHT_ROADS");
const labels = table("NIGHT_LABELS");
check("the road tint table is found in MapView", roads !== null);
check("the label tint table is found in MapView", labels !== null);

const black = namedFlavor("black");

/* Every override key must name a real flavour property, or it warms nothing.
   This catches the two typos. */
for (const [group, pairs] of [["road", roads], ["label", labels]]) {
  for (const [key] of pairs ?? []) {
    check(
      `${group} override "${key}" is a real flavour property`,
      Object.hasOwn(black, key),
    );
  }
}

/* And the tint is warm: red is the dominant channel. A grey slipped into this
   table would pass the key check and quietly undo the theme. */
const warm = (hex) => {
  const c = (i) => parseInt(hex.slice(i, i + 2), 16);
  return c(1) >= c(3) && c(3) >= c(5) && c(1) > c(5);
};
for (const [group, pairs] of [["road", roads], ["label", labels]]) {
  for (const [key, hex] of pairs ?? []) {
    check(`${group} "${key}" (${hex}) is warmer than its neutral`, warm(hex));
  }
}

/* Labels are the lightest marks on the map, so each must be lighter than
   black's own grey for that property -- proof the override moved it rather
   than recolouring it at the same lightness. */
const lum = (hex) => {
  const c = (i) => parseInt(hex.slice(i, i + 2), 16);
  return c(1) + c(3) + c(5);
};
for (const [key, hex] of labels ?? []) {
  const base = black[key];
  check(
    `label "${key}" is at least as light as black's ${base}`,
    typeof base === "string" && lum(hex) >= lum(base),
  );
}

console.log(`\nnight flavour: ${checks} checks, ${failures} failures`);
if (failures > 0) process.exit(1);
