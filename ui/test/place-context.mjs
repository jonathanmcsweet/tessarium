/* The search-result context: containment against the real committed
   catalogue, and the fly-to arithmetic against distances that can be
   checked in an atlas. */

import { readFileSync } from "node:fs";
import {
  bearing8,
  containingCountry,
  containingSubdivision,
  contextDepth,
  contextTerms,
  distanceKm,
  namedSubdivision,
  overlappingSubdivisions,
  placeLabels,
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

/* ------------------------------------------- the context someone typed

   Seven US localities are called Jasper and one Canadian one, and until
   these checks existed the ", GA" in "Jasper, GA" did nothing at all:
   the server's index is tile labels, no label knows its state, so the
   list came back ordered by population and the Georgia one sat sixth,
   below the fold. Every coordinate below is a real row out of the real
   index. */
const JASPER = {
  indiana: [-86.931038, 38.391455],
  alabama: [-87.277515, 33.831211],
  texas: [-93.99662, 30.920193],
  alberta: [-118.082428, 52.874932],
  georgia: [-84.429095, 34.467876],
  tennessee: [-85.626068, 35.074262],
  /* On the Florida/Georgia line: BOTH state boxes hold it. */
  florida: [-82.948194, 30.518276],
};

const subsAt = (lon, lat) => {
  const c = country(lon, lat);
  return c
    ? overlappingSubdivisions(data.subdivisions[c.code] ?? [], lon, lat)
    : [];
};
/* The whole ranking as the dropdown runs it: what was typed after the
   comma, against everything the point can be called. */
const depth = (query, [lon, lat]) =>
  contextDepth(
    contextTerms(query),
    placeLabels(
      country(lon, lat),
      country(lon, lat)?.name ?? null,
      subsAt(lon, lat),
    ),
  );

check(
  "the query splits at the comma",
  contextTerms("Jasper, GA").join() === "ga"
    && contextTerms("Paris,France").join() === "france",
);
check("no comma is no context", contextTerms("Los Angeles").length === 0);
check(
  "context words are folded like the index is",
  contextTerms("x, Québec").join() === "quebec",
);
check(
  "and capped at a region and a country",
  contextTerms("x, a b c d").length === 2,
);

check(
  "a state abbreviation finds its Jasper",
  depth("Jasper, GA", JASPER.georgia) === 1,
);
check(
  "and does not find the others",
  depth("Jasper, GA", JASPER.indiana) === 0
    && depth("Jasper, GA", JASPER.alabama) === 0
    && depth("Jasper, GA", JASPER.tennessee) === 0
    && depth("Jasper, GA", JASPER.alberta) === 0,
);
check(
  "the state written out finds it too",
  depth("Jasper, Georgia", JASPER.georgia) === 1,
);
check(
  "a province abbreviation works the same",
  depth("Jasper, AB", JASPER.alberta) === 1
    && depth("Jasper, AB", JASPER.georgia) === 0,
);
check(
  "a country name answers on its own",
  depth("Jasper, Canada", JASPER.alberta) === 1
    && depth("Jasper, Canada", JASPER.georgia) === 0,
);
check(
  "a country code does too",
  depth("Jasper, CA", JASPER.alberta) === 1,
);
/* An abbreviation is matched WHOLE. Read as a prefix, "GA" would also be
   Gauteng and Galicia, and the state someone asked for would rank level
   with places nobody named. (It IS still Gabon, whose country code is
   literally GA -- a real ambiguity in the codes, and one more reason
   this ranks rather than filters.) */
check(
  "an abbreviation is not a prefix of a longer name",
  depth("x, GA", [28.034, -26.195]) === 0,
);
check(
  "though a code that IS the abbreviation still answers",
  depth("x, GA", [11.6, -0.8]) === 1,
);
check(
  "nor is a short word treated as one",
  depth("Jasper, geo", JASPER.georgia) === 0,
);
/* Four letters or more may start a word, so a half-typed state still
   ranks and a two-word name is reachable by either word. */
check(
  "a longer word may start the name",
  depth("Charlotte, carolina", [-80.843, 35.227]) === 1,
);

/* Ranking, never deciding. The Jasper on the Florida line sits in
   Georgia's box too, and the fix must not hide it -- the boxes overlap
   and the borders are simplified, so a context that filtered would drop
   the right answer every time the catalogue disagreed with the atlas. */
check(
  "an overlapping box still answers the context",
  depth("Jasper, GA", JASPER.florida) === 1,
);

/* And the same overlap decides what the row SAYS. Silence is the
   default, because two boxes cannot say which; naming the one that was
   asked for is the same evidence answering the question actually put. */
check(
  "an ambiguous point still says nothing on its own",
  namedSubdivision(subsAt(...JASPER.florida)) === null,
);
check(
  "but names the state the query asked for",
  namedSubdivision(subsAt(...JASPER.florida), contextTerms("Jasper, GA"))
    === "Georgia",
);
check(
  "and stays silent when the context asks for neither",
  namedSubdivision(subsAt(...JASPER.florida), contextTerms("Jasper, TX"))
    === null,
);
check(
  "an unambiguous point is unaffected by context",
  namedSubdivision(subsAt(...JASPER.georgia), contextTerms("Jasper, TX"))
    === "Georgia",
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
