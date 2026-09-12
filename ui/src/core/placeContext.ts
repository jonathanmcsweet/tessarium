type Box = [number, number, number, number];

export type CountryShape = {
  name: string;
  code: string | null;
  boxes: Box[];
  polygon: [number, number][][];
};

export type SubdivisionShape = {
  name: string;
  /* The postal abbreviation, where the catalogue has one: "GA", "AB". It
     is what people actually type after the comma. */
  abbr?: string | undefined;
  boxes: Box[];
};

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

/* How deep inside the rings the point sits: distance to the nearest polygon
   edge, in degrees stretched for latitude. Only ever COMPARED, between
   candidates a few hundred kilometres apart, so a flat approximation is
   enough. */
const ringDepth = (rings: [number, number][][], lon: number, lat: number) => {
  const kx = Math.cos((lat * Math.PI) / 180);
  let best = Infinity;
  for (const ring of rings) {
    for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      const pi = ring[i];
      const pj = ring[j];
      if (!pi || !pj) continue;
      const ax = (pi[0] - lon) * kx;
      const ay = pi[1] - lat;
      const bx = (pj[0] - lon) * kx;
      const by = pj[1] - lat;
      const dx = bx - ax;
      const dy = by - ay;
      const t = dx === 0 && dy === 0
        ? 0
        : Math.max(0, Math.min(1, -(ax * dx + ay * dy) / (dx * dx + dy * dy)));
      best = Math.min(best, Math.hypot(ax + t * dx, ay + t * dy));
    }
  }
  return best;
};

const boxesNest = (inner: Box[], outer: Box[]) =>
  inner.every((b) =>
    outer.some((o) =>
      b[0] >= o[0] && b[1] >= o[1] && b[2] <= o[2] && b[3] <= o[3]
    )
  );

export type CityBox = { name: string; bbox: Box; };

/* The country whose border polygon contains the point. NO box prefilter for
   polygon countries: the generator appends off-coast city quads to the
   rings without widening the boxes, so the boxes do not bound the polygon
   (Malabo and Port Vila fall outside their countries' boxes).

   Simplified borders overlap, so several polygons can contain one point --
   both Congo capitals sit inside both Congos' rings. Ties resolve on the
   strongest data shipped, in this order:

     1. a candidate whose OWN catalogue city box holds the point, nearest
        city centre first (Kinshasa outranks Brazzaville from the east bank)
     2. a candidate whose boxes nest wholly inside the other's, which is an
        enclave whose hole the catalogue dropped (rural Maseru district is
        Lesotho, not the South Africa around it)
     3. the polygon the point sits deepest inside, so a border town beats
        the neighbour's simplification overreach

   Only a country WITHOUT a polygon (Antarctica) may claim a point on its
   box alone. */
export function containingCountry<C extends CountryShape>(
  countries: readonly C[],
  lon: number,
  lat: number,
  citiesOf: (c: C) => readonly CityBox[] = () => [],
): C | null {
  const exact = countries.filter(
    (c) => c.polygon.length > 0 && inRings(c.polygon, lon, lat),
  );
  if (exact.length === 1) return exact[0] ?? null;
  if (exact.length > 1) {
    const owned = exact
      .map((c) => {
        const near = citiesOf(c)
          .filter((city) => inBox(city.bbox, lon, lat))
          .map((city) =>
            Math.hypot(
              (city.bbox[0] + city.bbox[2]) / 2 - lon,
              (city.bbox[1] + city.bbox[3]) / 2 - lat,
            )
          );
        return { c, near: near.length > 0 ? Math.min(...near) : Infinity };
      })
      .filter((o) => o.near < Infinity);
    if (owned.length > 0) {
      return owned.reduce((a, b) => (b.near < a.near ? b : a)).c;
    }
    return exact.reduce((a, b) => {
      if (boxesNest(a.boxes, b.boxes)) return a;
      if (boxesNest(b.boxes, a.boxes)) return b;
      return ringDepth(b.polygon, lon, lat) > ringDepth(a.polygon, lon, lat)
        ? b
        : a;
    });
  }
  const boxOnly = countries.filter(
    (c) => c.polygon.length === 0 && c.boxes.some((b) => inBox(b, lon, lat)),
  );
  if (boxOnly.length === 0) return null;
  return boxOnly.reduce((a, b) => boxArea(b.boxes) < boxArea(a.boxes) ? b : a);
}

/* Every subdivision whose box holds the point. Usually one, often more --
   New York City sits in both New York's box and New Jersey's. The callers
   want different things from that list, so it is returned whole rather
   than resolved here. */
export function overlappingSubdivisions<S extends SubdivisionShape>(
  subdivisions: readonly S[],
  lon: number,
  lat: number,
): S[] {
  return subdivisions.filter((s) => s.boxes.some((b) => inBox(b, lon, lat)));
}

/* Lower case with the accents taken off, so "Québec" answers "quebec". The
   server folds its own index the same way; this folds only what was typed
   and the catalogue's own labels. */
export const foldLabel = (s: string) =>
  s.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();

export function contextTerms(query: string): string[] {
  const comma = query.indexOf(",");
  if (comma < 0) return [];
  return foldLabel(query.slice(comma + 1))
    .split(/[^\p{L}\p{N}]+/u)
    .filter((t) => t.length > 0)
    .slice(0, 2);
}

/* A short term is an abbreviation and must match a whole label: read as a
   prefix, "GA" would be Gabon, Galicia and Gauteng as well as Georgia. Four
   characters or more may start a word instead, so "carolina" finds North
   Carolina and "united" finds the United States. */
const answers = (term: string, label: string) =>
  term === label
  || (term.length >= 4
    && label.split(/[^\p{L}\p{N}]+/u).some((w) => w.startsWith(term)));

/* What a subdivision can be called, folded: its name and, where the
   catalogue has one, its postal abbreviation. */
export const subdivisionLabels = (s: SubdivisionShape): string[] =>
  s.abbr ? [foldLabel(s.name), foldLabel(s.abbr)] : [foldLabel(s.name)];

/* How many of the typed terms this place's own labels answer. Higher is
   a better match; zero is not a rejection. */
export function contextDepth(
  terms: readonly string[],
  labels: readonly string[],
): number {
  return terms.filter((t) => labels.some((l) => answers(t, l))).length;
}

/* The order results are offered in, lower first on both keys.

   How well the row answered the NAME comes first, straight from the index:
   "Atlanta, GA" must not answer with the County Landfill just because the
   landfill is in Georgia. The context decides only among rows the index
   calls equally good.

   Used with a stable sort, so rows neither key separates keep the index's
   own order. With no context every depth is 0, so every comparison falls
   through and the order is exactly what it always was. */
export const compareRows = (
  a: { result: { score: number; }; at: { depth: number; }; },
  b: { result: { score: number; }; at: { depth: number; }; },
): number => a.result.score - b.result.score || b.at.depth - a.at.depth;

/* Everything a point can be called, folded: its country by the name the
   reader sees, by the catalogue's own name and by its code, plus every
   subdivision whose box holds it, by name and abbreviation. One list, so
   the label a row shows and the ranking that put it there read the same
   thing. */
export function placeLabels(
  country: { name: string; code: string | null; } | null,
  countryLabel: string | null,
  subdivisions: readonly SubdivisionShape[],
): string[] {
  const out: string[] = [];
  if (country) {
    if (countryLabel) out.push(foldLabel(countryLabel));
    out.push(foldLabel(country.name));
    if (country.code) out.push(foldLabel(country.code));
  }
  for (const s of subdivisions) out.push(...subdivisionLabels(s));
  return out;
}

/* Which subdivision to NAME. Subdivisions are boxes only, and boxes
   overlap: New York City sits in both New York's and New Jersey's. One box
   holding the point is the answer; several is silence rather than a
   confident wrong one, and the country still shows.*/
export function namedSubdivision(
  subdivisions: readonly SubdivisionShape[],
  terms: readonly string[] = [],
): string | null {
  if (subdivisions.length === 1) return subdivisions[0]?.name ?? null;
  const asked = subdivisions.filter((s) =>
    contextDepth(terms, subdivisionLabels(s)) > 0
  );
  return asked.length === 1 ? asked[0]?.name ?? null : null;
}


export function containingSubdivision(
  subdivisions: readonly SubdivisionShape[],
  lon: number,
  lat: number,
): string | null {
  return namedSubdivision(overlappingSubdivisions(subdivisions, lon, lat));
}

const R_KM = 6371;
const rad = (d: number) => (d * Math.PI) / 180;

/* Great-circle distance, given back in whole kilometres. */
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
