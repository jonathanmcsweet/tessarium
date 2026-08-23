#!/usr/bin/env python3
"""Regenerate ui/src/regions.json, the country and state picker's catalogue.

Bounding boxes come from Natural Earth (public domain): 110m admin-0 for
countries, 50m admin-1 for first-level subdivisions (which that dataset
carries for the big federations -- US, Canada, Australia, Brazil, India,
China), and 50m populated places for cities. Run offline, output committed,
like design/grid_design.py: the build must not need the network.

    tools/gen-regions.py ne_110m_admin_0_countries.geojson \
                         ne_50m_admin_1_states_provinces.geojson \
                         ne_50m_populated_places_simple.geojson

Boxes, not polygons: a country download includes slivers of its neighbours.
Countries crossing the antimeridian (Russia, Fiji, the US via the Aleutians)
get a near-world-wide box; the server's tile budget keeps even those sane,
and polygon-clipped downloads are on the roadmap, not pretended here.

Cities are points in the dataset, so their boxes are drawn here: taller for
the metropolises (scalerank is Natural Earth's prominence measure, 0 the
largest), and widened by latitude so a northern city is not handed a sliver.
The exact size is a judgement call, not data -- a city download means "the
city and its surroundings", and at full depth even the generous boxes stay
in the tens of megabytes.

Country codes are ISO 3166-1 alpha-2 so the UI can localise names with
Intl.DisplayNames; the shipped name is the fallback."""

import json
import math
import sys


def perp_dist(pt, a, b):
    (px, py), (ax, ay), (bx, by) = pt, a, b
    dx, dy = bx - ax, by - ay
    if dx == dy == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def douglas_peucker(points, eps):
    if len(points) < 3:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        lo, hi = stack.pop()
        best, idx = 0.0, None
        for i in range(lo + 1, hi):
            d = perp_dist(points[i], points[lo], points[hi])
            if d > best:
                best, idx = d, i
        if idx is not None and best > eps:
            keep[idx] = True
            stack.append((lo, idx))
            stack.append((idx, hi))
    return [pt for pt, k in zip(points, keep) if k]


def simplify_ring(ring, eps):
    """A closed ring anchored for DP on its two most distant points -- DP
    anchored on the closure point degenerates to a zero-length chord and
    collapses small rings entirely (which once cost Canada all of
    Vancouver Island)."""
    pts = ring[:-1] if len(ring) > 1 and ring[0] == ring[-1] else list(ring)
    if len(pts) < 3:
        return pts
    far = max(
        range(1, len(pts)),
        key=lambda i: (pts[i][0] - pts[0][0]) ** 2 + (pts[i][1] - pts[0][1]) ** 2,
    )
    out = douglas_peucker(pts[: far + 1], eps)[:-1] + douglas_peucker(
        pts[far:] + [pts[0]], eps
    )[:-1]
    dedup = [pt for i, pt in enumerate(out) if i == 0 or pt != out[i - 1]]
    if len(dedup) > 1 and dedup[0] == dedup[-1]:
        dedup = dedup[:-1]
    return dedup


def quad(box):
    a, b, c, d = box
    return [[a, b], [c, b], [c, d], [a, d]]


def ring_box(ring):
    xs = [p[0] for p in ring]
    ys = [p[1] for p in ring]
    return [min(xs), min(ys), max(xs), max(ys)]


def point_in_rings(rings, x, y):
    odd = False
    for ring in rings:
        n = len(ring)
        for i in range(n):
            x1, y1 = ring[i]
            x2, y2 = ring[(i + 1) % n]
            if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
                odd = not odd
    return odd


def outer_rings(geometry):
    if geometry["type"] == "Polygon":
        return [geometry["coordinates"][0]]
    return [part[0] for part in geometry["coordinates"]]


def simplify_rings(geometry, budget):
    """Outer rings only -- holes (Lesotho) download a sliver extra, which is
    harmless where missing an enclave would not be -- simplified until the
    whole multipolygon fits the point budget, then quantised to 2 decimals
    (~1 km), which is the fidelity the 110m source has anyway. A ring the
    simplifier collapses survives as its bounding quad: an island may grow
    a little water, never vanish."""
    rings = [[(round(x, 2), round(y, 2)) for x, y in ring] for ring in outer_rings(geometry)]
    eps = 0.01
    while True:
        out = []
        for ring in rings:
            slim = simplify_ring(ring, eps)
            if len(slim) < 3:
                a, b, c, d = ring_box(ring)
                if c > a and d > b:
                    out.append([(a, b), (c, b), (c, d), (a, d)])
                continue
            out.append(slim)
        if sum(len(r) for r in out) <= budget or eps > 20:
            return [[[x, y] for x, y in ring] for ring in out]
        eps *= 1.6


def encircles_pole(geometry):
    """A ring sweeping (nearly) the full longitude range encircles a pole,
    and even-odd ray casting in lon/lat space is meaningless for it."""
    return any(
        max(x for x, _ in ring) - min(x for x, _ in ring) >= 355
        for ring in outer_rings(geometry)
    )


def country_polygon(geometry, cities, name):
    """Simplified border that provably contains every catalogued city.
    Cities are exactly what a country download must include, so they are the
    acceptance test: the budget escalates while any falls out, and one whose
    point genuinely sits off the coarse 110m coastline (harbours, atolls)
    gets its drawn city box appended as an extra ring."""
    if encircles_pole(geometry):
        # Antarctica. No polygon: it downloads box-planned, like a viewport.
        return []
    budget = 300
    while True:
        rings = simplify_rings(geometry, budget)
        missing = [c for c in cities if not point_in_rings(rings, *c["center"])]
        if not missing or budget >= 1600:
            break
        budget = min(1600, int(budget * 1.6))
    for c in missing:
        rings.append(quad(c["bbox"]))
    points = sum(len(r) for r in rings)
    if len(rings) > 64 or points > 2048:
        raise SystemExit(
            f"{name}: polygon exceeds the server caps ({len(rings)} rings, {points} points)"
        )
    return rings


def part_boxes(geometry):
    boxes = []
    for ring in outer_rings(geometry):
        box = [180.0, 90.0, -180.0, -90.0]
        walk(ring, box)
        boxes.append([round(v, 3) for v in box])
    return boxes


def merge_boxes(boxes):
    a = [180.0, 90.0, -180.0, -90.0]
    for b in boxes:
        a = [min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3])]
    return a


def clustered_boxes(geometry):
    """One box normally; two when the geometry straddles the antimeridian.
    Natural Earth splits geometry at 180, so parts sit cleanly on one side;
    clustering them east/west turns the US or Russia near-world-wide box
    into two honest ones. The download API takes several regions, so a
    multi-box country is simply several requests sharing one polygon."""
    boxes = part_boxes(geometry)
    merged = merge_boxes(boxes)
    if merged[2] - merged[0] <= 180:
        return [merged]
    if encircles_pole(geometry):
        # Antarctica really does span every longitude; two honest halves.
        return [
            [-180.0, merged[1], 0.0, merged[3]],
            [0.0, merged[1], 180.0, merged[3]],
        ]
    west = [b for b in boxes if b[0] < 0]
    east = [b for b in boxes if b[0] >= 0]
    if not west or not east:
        return [merged]
    return [merge_boxes(west), merge_boxes(east)]


def walk(coords, box):
    if isinstance(coords[0], (int, float)):
        lon, lat = coords[0], coords[1]
        box[0] = min(box[0], lon)
        box[1] = min(box[1], lat)
        box[2] = max(box[2], lon)
        box[3] = max(box[3], lat)
    else:
        for c in coords:
            walk(c, box)


def bbox(feature):
    box = [180.0, 90.0, -180.0, -90.0]
    walk(feature["geometry"]["coordinates"], box)
    return [round(v, 3) for v in box]


def iso2(props):
    for key in ("ISO_A2_EH", "ISO_A2", "iso_a2"):
        v = props.get(key, "")
        if isinstance(v, str) and len(v) == 2 and v.isalpha() and v.isupper():
            return v
    return None


def city_box(lon, lat, scalerank):
    half_lat = 0.35 if scalerank <= 1 else 0.2 if scalerank <= 4 else 0.12
    half_lon = half_lat / max(0.2, math.cos(math.radians(lat)))
    return [
        round(max(lon - half_lon, -180.0), 3),
        round(max(lat - half_lat, -85.0), 3),
        round(min(lon + half_lon, 180.0), 3),
        round(min(lat + half_lat, 85.0), 3),
    ]


def main(countries_path, states_path, places_path):
    country_features = json.load(open(countries_path))["features"]

    subdivisions = {}
    for f in json.load(open(states_path))["features"]:
        p = f["properties"]
        code = p.get("iso_a2")
        name = p.get("name")
        if not code or not name:
            continue
        # The postal abbreviation, because "Jasper, GA" is how a person
        # writes it. Natural Earth carries it for the federations we ship
        # subdivisions for; where it is missing or is just the name again,
        # the field is left out rather than shipped as a duplicate.
        abbr = p.get("postal") or ""
        entry = {"name": name, "boxes": clustered_boxes(f["geometry"])}
        if abbr and abbr.casefold() != name.casefold():
            entry["abbr"] = abbr
        subdivisions.setdefault(code, []).append(entry)
    for entries in subdivisions.values():
        entries.sort(key=lambda e: e["name"])

    known = {
        iso2(f["properties"]) for f in country_features if iso2(f["properties"])
    }
    picked = {}
    dropped = 0
    for f in json.load(open(places_path))["features"]:
        p = f["properties"]
        code, name = p.get("iso_a2"), p.get("name")
        if not (isinstance(code, str) and code in known and name):
            dropped += 1
            continue
        # Duplicate names inside a country: keep the more populous one.
        prev = picked.get((code, name))
        if prev and prev["pop"] >= (p.get("pop_max") or 0):
            continue
        picked[(code, name)] = {
            "pop": p.get("pop_max") or 0,
            "entry": {
                "name": name,
                "bbox": city_box(
                    p["longitude"], p["latitude"], p.get("scalerank", 8)
                ),
            },
        }
    cities = {}
    for (code, _), v in picked.items():
        cities.setdefault(code, []).append(v["entry"])
    for entries in cities.values():
        entries.sort(key=lambda e: e["name"])

    countries = []
    for f in country_features:
        p = f["properties"]
        code = iso2(p)
        accepted = [
            {
                "center": (
                    (c["bbox"][0] + c["bbox"][2]) / 2,
                    (c["bbox"][1] + c["bbox"][3]) / 2,
                ),
                "bbox": c["bbox"],
            }
            for c in (cities.get(code, []) if code else [])
        ]
        countries.append(
            {
                "code": code,
                "name": p["NAME"],
                "boxes": clustered_boxes(f["geometry"]),
                "polygon": country_polygon(f["geometry"], accepted, p["NAME"]),
            }
        )
    countries.sort(key=lambda c: c["name"])

    out = {
        "attribution": "Natural Earth, public domain: 110m admin-0 countries (boxes and simplified border polygons), 50m admin-1 states and provinces, 50m populated places",
        "countries": countries,
        "subdivisions": subdivisions,
        "cities": cities,
    }
    json.dump(out, open("ui/src/regions.json", "w"), separators=(",", ":"))
    points = sum(len(r) for c in countries for r in c["polygon"])
    print(
        f"ui/src/regions.json: {len(countries)} countries ({points} polygon points), "
        f"{sum(len(v) for v in subdivisions.values())} subdivisions in {len(subdivisions)} "
        f"({sum(1 for v in subdivisions.values() for e in v if 'abbr' in e)} abbreviated), "
        f"{sum(len(v) for v in cities.values())} cities in {len(cities)} "
        f"({dropped} places dropped: no matching country)"
    )


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3])
