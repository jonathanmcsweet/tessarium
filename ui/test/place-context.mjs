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

const country = (lon, lat) =>
  containingCountry(
    data.countries,
    lon,
    lat,
    (c) => data.cities[c.code] ?? [],
  );
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
/* Subdivision boxes overlap; a point in several must not pick one with
   false confidence. New York City sits in New Jersey's box too. */
const nyc = country(-74.006, 40.713);
check(
  "an ambiguous subdivision stays silent instead of guessing wrong",
  nyc?.name === "United States of America"
    && sub(nyc, -74.006, 40.713) === null,
);
/* Boxes overlap where polygons do not: Karlsruhe sits inside France's
   bounding box, and only the border polygon keeps it German. */
check(
  "a point in a neighbour's box still resolves by border",
  country(8.404, 49.014)?.name === "Germany",
);
check("the open ocean resolves to nothing", country(-30, 0) === null);
check(
  "offshore inside a country's box is still nothing",
  country(-4, 45.5) === null,
);
/* The generator appends off-coast city quads to the rings without
   widening the boxes, so a box prefilter loses island capitals. */
check(
  "an island capital outside its country's box still resolves",
  country(8.784, 3.75)?.name === "Eq. Guinea",
);
check(
  "and across the Pacific too",
  country(168.317, -17.733)?.name === "Vanuatu",
);
/* Simplified borders overlap: BOTH Congo capitals sit inside BOTH
   Congos' rings. Each country's own catalogued city is what says whose
   bank is whose. */
check(
  "a capital on an overlapped border keeps its country",
  country(15.313, -4.328)?.name === "Dem. Rep. Congo",
);
check(
  "and the capital on the other bank keeps the other one",
  country(15.283, -4.257)?.name === "Congo",
);
check(
  "a border town with one side's city keeps that side",
  country(25.86, -17.86)?.name === "Zambia",
);
/* The catalogue drops enclave holes, so Lesotho's points are inside the
   South African outer ring too; nested boxes are what says enclave. */
check(
  "an enclave beats the country that surrounds it",
  country(27.48, -29.31)?.name === "Lesotho",
);
/* Away from any catalogued city, so only the nested-box rule can say
   this is Lesotho: the dropped hole leaves it inside South Africa's
   outer ring, where the depth rule would pick the surrounder. */
check(
  "and its countryside does too",
  country(28.2, -29.6)?.name === "Lesotho",
);

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
