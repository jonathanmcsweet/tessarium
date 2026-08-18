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
            {"code": iso2(p), "name": p["NAME"], "bbox": bbox(f)}
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
            {"name": name, "bbox": bbox(f)}
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
        "attribution": "Natural Earth, public domain: 110m admin-0 countries, 50m admin-1 states and provinces, 50m populated places",
        "countries": countries,
        "subdivisions": subdivisions,
        "cities": cities,
    }
    json.dump(out, open("ui/src/regions.json", "w"), separators=(",", ":"))
    print(
        f"ui/src/regions.json: {len(countries)} countries, "
        f"{sum(len(v) for v in subdivisions.values())} subdivisions in {len(subdivisions)}, "
        f"{sum(len(v) for v in cities.values())} cities in {len(cities)} "
        f"({dropped} places dropped: no matching country)"
    )


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3])
