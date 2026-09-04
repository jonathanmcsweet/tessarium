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

/* ------------------------- naming a view by its middle --------------------

   A download of the current view is named after where its middle is, by
   src/regions.ts `placeAt`: smallest city box first, then a subdivision,
   then the country whose border polygon contains the point. That name is
   what the download is called forever, so the catalogue has to be able to
   answer -- and this is the data half of that. The behaviour half is in
   ui/test/e2e.mjs, which downloads a view over London and reads the row.

   The rule mirrored rather than imported: this file reads the committed
   JSON, which is the thing that can silently change under the lookup. */
const inBox = (b, lon, lat) =>
  lon >= b[0] && lon <= b[2] && lat >= b[1] && lat <= b[3];
const boxArea = (b) => (b[2] - b[0]) * (b[3] - b[1]);
const placeAt = (lon, lat) => {
  let name;
  let smallest = Infinity;
  for (const list of Object.values(data.cities)) {
    for (const c of list) {
      if (inBox(c.bbox, lon, lat) && boxArea(c.bbox) < smallest) {
        smallest = boxArea(c.bbox);
        name = c.name;
      }
    }
  }
  if (name) return name;
  smallest = Infinity;
  for (const list of Object.values(data.subdivisions)) {
    for (const sub of list) {
      for (const b of sub.boxes) {
        if (inBox(b, lon, lat) && boxArea(b) < smallest) {
          smallest = boxArea(b);
          name = sub.name;
        }
      }
    }
  }
  if (name) return name;
  for (const c of data.countries) {
    if (c.polygon.length > 0) {
      if (inside(c.polygon, lon, lat)) return c.name;
    } else if (c.boxes.some((b) => inBox(b, lon, lat))) return c.name;
  }
  return undefined;
};

for (
  const [lon, lat, expected, why] of [
    [-0.09, 51.51, "London", "the view that started all of this"],
    [2.3522, 48.8566, "Paris", "a city in a country with many"],
    [139.69, 35.68, "Tokyo", "a city the picker's placeholder names"],
    [-84.39, 33.75, "Atlanta", "a city inside a subdivision, city wins"],
    [-98.5, 38.5, "Kansas", "no city, so the subdivision answers"],
    [-8.0, 39.5, "Portugal", "no city or subdivision, so the country does"],
  ]
) {
  const got = placeAt(lon, lat);
  check(
    `${lon}, ${lat} is named ${expected} -- ${why} (got ${got})`,
    got === expected,
  );
}
/* Open water has no answer, and must not invent one: the download then goes
   unnamed and the server writes the box's own corners, which is ugly and
   true. A nearest-city guess would be neither. */
check(
  "a point in the mid-Atlantic is named by nothing",
  placeAt(-40, 30) === undefined,
);
/* The rule that makes a city beat its own country: a point in central
   London is inside the London box AND inside the United Kingdom polygon,
   and the specific one has to win or every view is named after a country. */
check(
  "central London is inside both its city box and its country",
  data.cities.GB.some((c) => c.name === "London" && inBox(c.bbox, -0.09, 51.51))
    && inside(
      data.countries.find((c) => c.code === "GB").polygon,
      -0.09,
      51.51,
    ),
);

console.log(`\nregion catalogue: ${checks} checks, ${failures} failures`);
if (failures > 0) process.exit(1);
