/* The search-result context: containment against the real committed
   catalogue, and the fly-to arithmetic against distances that can be
   checked in an atlas. */

import { readFileSync } from "node:fs";
import {
  bearing8,
  containingCountry,
  containingSubdivision,
  distanceKm,
} from "../src/core/placeContext.ts";

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

const country = (lon, lat) => containingCountry(data.countries, lon, lat);
const sub = (c, lon, lat) =>
  containingSubdivision(data.subdivisions[c.code] ?? [], lon, lat);

/* The bug that motivated all of this: several US localities named
   Atlanta, indistinguishable in the dropdown. */
const atlantaGa = country(-84.388, 33.749);
check(
  "Atlanta, the big one, is in the United States",
  atlantaGa?.name === "United States of America",
);
check(
  "and in Georgia",
  sub(atlantaGa, -84.388, 33.749) === "Georgia",
);
const atlantaMi = country(-84.144, 45.005);
check(
  "Atlanta, Michigan is told apart by its state",
  atlantaMi?.name === "United States of America"
    && sub(atlantaMi, -84.144, 45.005) === "Michigan",
);

check("Paris resolves to France", country(2.352, 48.857)?.name === "France");
check(
  "a country without catalogued subdivisions says nothing rather than guessing",
  sub(country(2.352, 48.857), 2.352, 48.857) === null,
);
/* Boxes overlap where polygons do not: Karlsruhe sits inside France's
   bounding box, and only the border polygon keeps it German. */
check(
  "a point in a neighbour's box still resolves by border",
  country(8.404, 49.014)?.name === "Germany",
);
check("the open ocean resolves to nothing", country(-30, 0) === null);

/* Distances a road atlas can confirm; tolerance covers the spherical
   approximation, not sloppiness. */
const paris = [2.352, 48.857];
const london = [-0.128, 51.507];
const dist = distanceKm(...paris, ...london);
check(`Paris to London is ~344 km (got ${dist})`, dist > 335 && dist < 355);
check(
  "ten equatorial degrees are ~1113 km",
  Math.abs(distanceKm(0, 0, 10, 0) - 1113) <= 2,
);
check(
  "the antimeridian is not the long way round",
  distanceKm(179, 0, -179, 0) < 250,
);
check("a place is 0 km from itself", distanceKm(5, 5, 5, 5) === 0);

check("London is north-west of Paris", bearing8(...paris, ...london) === "nw");
check("Paris is south-east of London", bearing8(...london, ...paris) === "se");
check("due east stays east", bearing8(0, 0, 10, 0) === "e");
check(
  "across the antimeridian points the short way",
  bearing8(179, 0, -179, 0) === "e",
);
/* A bearing just west of due north sits at the top of the compass, on the
   n/nw sector boundary's north side -- the case that tells rounding from
   truncation, which every mid-sector bearing cannot. */
check("nearly due north is still north", bearing8(0, 0, -0.3, 5) === "n");

console.log(`place context: ${checks} checks, ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
