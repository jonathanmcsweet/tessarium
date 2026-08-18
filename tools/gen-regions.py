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


def outer_rings(geometry):
    if geometry["type"] == "Polygon":
        return [geometry["coordinates"][0]]
    return [part[0] for part in geometry["coordinates"]]


def simplify_rings(geometry, budget):
    """Outer rings only -- holes (Lesotho) download a sliver extra, which is
    harmless where missing an enclave would not be -- simplified until the
    whole multipolygon fits the point budget, then quantised to 2 decimals
    (~1 km), which is the fidelity the 110m source has anyway."""
    rings = [[(round(x, 2), round(y, 2)) for x, y in ring] for ring in outer_rings(geometry)]
    eps = 0.01
    while True:
        out = []
        for ring in rings:
            slim = douglas_peucker(ring, eps)
            dedup = [pt for i, pt in enumerate(slim) if i == 0 or pt != slim[i - 1]]
            if len(dedup) > 1 and dedup[0] == dedup[-1]:
                dedup = dedup[:-1]
            if len(dedup) >= 3:
                out.append(dedup)
        if sum(len(r) for r in out) <= budget or eps > 20:
            return [[[x, y] for x, y in ring] for ring in out]
        eps *= 1.6


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
    countries = []
    for f in json.load(open(countries_path))["features"]:
        p = f["properties"]
        countries.append(
            {
                "code": iso2(p),
                "name": p["NAME"],
                "boxes": clustered_boxes(f["geometry"]),
                "polygon": simplify_rings(f["geometry"], 300),
            }
        )
    countries.sort(key=lambda c: c["name"])

    subdivisions = {}
    for f in json.load(open(states_path))["features"]:
        p = f["properties"]
        code = p.get("iso_a2")
        name = p.get("name")
        if not code or not name:
            continue
        subdivisions.setdefault(code, []).append(
            {"name": name, "boxes": clustered_boxes(f["geometry"])}
        )
    for entries in subdivisions.values():
        entries.sort(key=lambda e: e["name"])

    known = {c["code"] for c in countries if c["code"]}
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
        f"{sum(len(v) for v in subdivisions.values())} subdivisions in {len(subdivisions)}, "
        f"{sum(len(v) for v in cities.values())} cities in {len(cities)} "
        f"({dropped} places dropped: no matching country)"
    )


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3])
