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
   encode path. The borders are simplified, so near one the attribution
   can be wrong in both directions: a coastal point can resolve to no
   country, and a border town can resolve to the neighbour whose
   simplified polygon overreaches. The tiebreaks below get the shipped
   catalogue's own city list right; they are context for a dropdown, not
   a boundary authority. */

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

/* How deep inside the rings the point sits: its distance to the nearest
   polygon edge, in degrees stretched for latitude. Only ever COMPARED,
   between candidates a few hundred kilometres apart, so the flat
   approximation is enough. */
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

/* The country whose border polygon contains the point. NO box prefilter
   for polygon countries: the generator appends off-coast city quads to
   the rings without widening the boxes, so the boxes do not bound the
   polygon (Malabo and Port Vila live outside their countries' boxes).

   Simplified borders overlap, so several polygons can contain one point
   -- both Congo capitals sit inside both Congos' rings. Ties resolve by
   the strongest data shipped, in order: a candidate whose OWN catalogue
   city box holds the point claims it (nearest such city's centre when
   both do -- Kinshasa outranks Brazzaville from the east bank); a
   candidate whose boxes nest wholly inside the other's is an enclave
   whose hole the catalogue dropped and wins (rural Maseru district is
   Lesotho, not the South Africa around it); otherwise the point belongs
   to the polygon it sits deepest inside (a border town beats the
   neighbour's simplification overreach). Only a country WITHOUT a
   polygon (Antarctica) may claim a point on its box alone. */
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

/* ------------------------------------------- the context someone typed

   "Jasper, GA" is how a person names a place, and until now the part
   after the comma did nothing at all. The server cannot help: its index
   is built from tile labels, and a tile label does not know its country,
   so no entry for Jasper contains "GA" anywhere and the context can only
   ever rank a name against itself (ocaml/server/place_index.ml says as
   much). The context this file already derives for DISPLAY is the same
   context the query is asking about, so the ranking happens here, on
   data already shipped, with nothing leaving the machine.

   Ranking, never filtering, for the same reason the display is hedged:
   the boxes overlap and the borders are simplified, so a context that
   decided would hide the right answer whenever the catalogue disagreed
   with the atlas. */

/* Lower case with the accents taken off, so "Québec" answers "quebec".
   The server folds its own index the same way; this folds only what was
   typed and the catalogue's own labels, both of which are already
   Unicode strings rather than index bytes. */
export const foldLabel = (s: string) =>
  s.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();

/* Everything after the first comma, in words, folded. Mirrors the
   server's own split (place_index.ml, [parse_query]) including its cap:
   two words is a region and a country, and more than that is noise. */
export function contextTerms(query: string): string[] {
  const comma = query.indexOf(",");
  if (comma < 0) return [];
  return foldLabel(query.slice(comma + 1))
    .split(/[^\p{L}\p{N}]+/u)
    .filter((t) => t.length > 0)
    .slice(0, 2);
}

/* Whether one label answers one term.

   A short term is an abbreviation and must match a whole label: "GA" is
   Georgia, and read as a prefix it would also be Gabon, Galicia and
   Gauteng. Four characters or more may start a word instead, so
   "carolina" finds North Carolina and "united" finds the United
   States. */
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

   How well the row answered the NAME comes first, straight from the index
   -- "Jasper, GA" must not answer with Jasper County Landfill just
   because the landfill is in Georgia. Only among rows the index calls
   equally good does the context decide.

   Used with a stable sort, so rows neither key separates keep the order
   the index gave them. That is what makes a query with no context at all
   come back in exactly the order it always did: every depth is 0, so
   every comparison falls through to the index's own. */
export const compareRows = (
  a: { result: { score: number; }; at: { depth: number; }; },
  b: { result: { score: number; }; at: { depth: number; }; },
): number => a.result.score - b.result.score || b.at.depth - a.at.depth;

/* Everything a point can be called, folded: its country by the name the
   reader sees, by the catalogue's own name and by its code, and every
   subdivision whose box holds it, by name and abbreviation. One list, so
   the label a row shows and the ranking that put it there are reading the
   same thing. */
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
   overlap: New York City sits in both New York's and New Jersey's. One
   box holding the point is the answer. Several is silence rather than a
   confident wrong one -- the country still shows, which is never less
   than before -- UNLESS the typed context named one of them, and then
   saying it is the same box evidence answering the question actually
   put. */
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

/* The no-context case, kept as its own name because most callers have no
   query to hand: which subdivision holds this point, or nothing. */
export function containingSubdivision(
  subdivisions: readonly SubdivisionShape[],
  lon: number,
  lat: number,
): string | null {
  return namedSubdivision(overlappingSubdivisions(subdivisions, lon, lat));
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
