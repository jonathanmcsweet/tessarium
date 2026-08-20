/* Where a search result would take the map, said before the click.

   The search index (ocaml/server/place_index.ml) carries a name, a kind
   and a point -- no administrative context, because tile labels do not
   know their country. Names repeat: the United States alone has several
   localities called Atlanta, so a bare "Atlanta — locality" row is a coin
   flip. This module derives context offline, from data already shipped:
   which catalogue country contains the point (the simplified Natural
   Earth border polygons behind the download picker), which subdivision
   box where the catalogue has them (nine large countries), and how far
   and which way the map would fly. No query leaves the machine.

   Floats throughout: this is display at the UI boundary, never the
   encode path. The borders are simplified, so a point close to one can
   resolve to no country (offshore of the simplified coast) -- context
   then simply says less, it never guesses. */

type Box = [number, number, number, number];

export type CountryShape = {
  name: string;
  code: string | null;
  boxes: Box[];
  polygon: [number, number][][];
};

export type SubdivisionShape = { name: string; boxes: Box[]; };

const inBox = (b: Box, lon: number, lat: number) =>
  lon >= b[0] && lat >= b[1] && lon <= b[2] && lat <= b[3];

const boxArea = (boxes: Box[]) =>
  boxes.reduce((a, b) => a + (b[2] - b[0]) * (b[3] - b[1]), 0);

/* Even-odd ray cast over the outer rings -- the same rule as the server's
   clipper (ocaml/pmtiles/clip.ml) and test/regions.mjs. */
const inRings = (rings: [number, number][][], lon: number, lat: number) => {
  let odd = false;
  for (const ring of rings) {
    for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      const pi = ring[i];
      const pj = ring[j];
      /* Unreachable: i and j always index the ring. The checks keep the
         indexed access honest under noUncheckedIndexedAccess. */
      if (!pi || !pj) continue;
      const [xi, yi] = pi;
      const [xj, yj] = pj;
      if (
        yi > lat !== yj > lat
        && lon < ((xj - xi) * (lat - yi)) / (yj - yi) + xi
      ) {
        odd = !odd;
      }
    }
  }
  return odd;
};

/* The country whose border polygon contains the point; smallest box area
   breaks ties (an enclave beats its surrounder). Only a country WITHOUT a
   polygon in the catalogue (Antarctica) may claim a point on its box
   alone -- a box is far too generous for neighbours (France's contains
   chunks of four countries). */
export function containingCountry<C extends CountryShape>(
  countries: readonly C[],
  lon: number,
  lat: number,
): C | null {
  const boxed = countries.filter((c) =>
    c.boxes.some((b) => inBox(b, lon, lat))
  );
  const exact = boxed.filter(
    (c) => c.polygon.length > 0 && inRings(c.polygon, lon, lat),
  );
  const pool = exact.length > 0
    ? exact
    : boxed.filter((c) => c.polygon.length === 0);
  if (pool.length === 0) return null;
  return pool.reduce((a, b) => (boxArea(b.boxes) < boxArea(a.boxes) ? b : a));
}

/* Subdivisions are boxes only, so the smallest containing box wins; wrong
   only near borders, where the neighbouring state's name still says which
   side of the country the map is about to fly to. */
export function containingSubdivision(
  subdivisions: readonly SubdivisionShape[],
  lon: number,
  lat: number,
): string | null {
  const hits = subdivisions.filter((s) =>
    s.boxes.some((b) => inBox(b, lon, lat))
  );
  if (hits.length === 0) return null;
  return hits.reduce((a, b) => (boxArea(b.boxes) < boxArea(a.boxes) ? b : a))
    .name;
}

const R_KM = 6371;
const rad = (d: number) => (d * Math.PI) / 180;

/* Great-circle distance, rounded to whole kilometres. */
export function distanceKm(
  fromLon: number,
  fromLat: number,
  toLon: number,
  toLat: number,
): number {
  const dLat = rad(toLat - fromLat);
  const dLon = rad(toLon - fromLon);
  const a = Math.sin(dLat / 2) ** 2
    + Math.cos(rad(fromLat)) * Math.cos(rad(toLat)) * Math.sin(dLon / 2) ** 2;
  return Math.round(2 * R_KM * Math.asin(Math.sqrt(a)));
}

export const DIRECTIONS = [
  "n",
  "ne",
  "e",
  "se",
  "s",
  "sw",
  "w",
  "nw",
] as const;
export type Direction = (typeof DIRECTIONS)[number];

/* Initial great-circle bearing, folded to an eight-wind compass point.
   The trig takes the short way round, so a destination across the
   antimeridian points the right way rather than the long way. */
export function bearing8(
  fromLon: number,
  fromLat: number,
  toLon: number,
  toLat: number,
): Direction {
  const dLon = rad(toLon - fromLon);
  const y = Math.sin(dLon) * Math.cos(rad(toLat));
  const x = Math.cos(rad(fromLat)) * Math.sin(rad(toLat))
    - Math.sin(rad(fromLat)) * Math.cos(rad(toLat)) * Math.cos(dLon);
  const deg = (Math.atan2(y, x) * 180) / Math.PI;
  /* The ?? is unreachable: the index is taken mod 8. */
  return DIRECTIONS[Math.round(((deg + 360) % 360) / 45) % 8] ?? "n";
}
