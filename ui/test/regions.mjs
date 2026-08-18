/* Invariants of the committed region catalogue.

   The catalogue is generated (tools/gen-regions.py) and committed, so a
   generator bug ships silently as data unless something looks at the data.
   The load-bearing check is city containment: every city the picker offers
   must sit inside its country's simplified border polygon, because a city
   OUTSIDE it silently vanishes from that country's clipped download --
   which is how over-eager border simplification once cost Canada all of
   Vancouver Island, Victoria included. */

import { readFileSync } from "node:fs";

const data = JSON.parse(
  readFileSync(new URL("../src/regions.json", import.meta.url), "utf8"),
);

let checks = 0;
let failures = 0;
const check = (name, ok) => {
  checks++;
  if (!ok) {
    failures++;
    console.log(`  FAIL  ${name}`);
  }
};

/* Even-odd ray cast, mirroring ocaml/pmtiles/clip.ml. */
const inside = (rings, x, y) => {
  let odd = false;
  for (const ring of rings) {
    for (let i = 0; i < ring.length; i++) {
      const [x1, y1] = ring[i];
      const [x2, y2] = ring[(i + 1) % ring.length];
      if (y1 > y !== y2 > y && x < ((x2 - x1) * (y - y1)) / (y2 - y1) + x1) {
        odd = !odd;
      }
    }
  }
  return odd;
};

const worldBox = ([a, b, c, d]) =>
  a >= -180 && c <= 180 && b >= -90 && d <= 90 && a < c && b < d;

for (const country of data.countries) {
  const name = country.name;
  check(`${name}: at least one box`, country.boxes.length >= 1);
  check(
    `${name}: boxes are honest`,
    country.boxes.every((b) => worldBox(b) && b[2] - b[0] <= 180),
  );
  check(
    `${name}: polygon within the server's caps`,
    country.polygon.length <= 64
      && country.polygon.reduce((n, r) => n + r.length, 0) <= 2048
      && country.polygon.every((r) => r.length >= 3),
  );
  if (country.polygon.length > 0 && country.code) {
    const cities = data.cities[country.code] ?? [];
    for (const city of cities) {
      const [a, b, c, d] = city.bbox;
      check(
        `${name}: ${city.name} is inside the simplified border`,
        inside(country.polygon, (a + c) / 2, (b + d) / 2),
      );
    }
  }
}

check(
  "Russia straddles the antimeridian as two boxes",
  data.countries.find((c) => c.code === "RU").boxes.length === 2,
);
check(
  "Fiji straddles the antimeridian as two boxes",
  data.countries.find((c) => c.code === "FJ").boxes.length === 2,
);

console.log(`\nregion catalogue: ${checks} checks, ${failures} failures`);
if (failures > 0) process.exit(1);
