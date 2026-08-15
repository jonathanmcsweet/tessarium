"""
Band table design and validation.

Produces a banded lat/lon grid over the whole globe, in exact integer
nanodegrees, that fits inside the 2048^3 * 10^4 address space.

Design shape:
  - Uniform row height globally: R rows spanning 180 degrees of latitude.
  - Rows are grouped into B bands of equal row count. Every row in a band
    shares one column count C_b. This keeps the shipped table small (B
    entries, not R) while letting cell width track cos(latitude).
  - C_b is derived from the EQUATOR-WARD edge of the band, so no cell in the
    band is ever wider than the target. Cells get narrower toward the pole
    within a band, never wider. Erring in the safe direction.

Bucketing is floor((v - v_min) * K / span), which is exactly injective from
[v_min, v_min+span) onto [0, K) for any K. That removes any divisibility
constraint on R, B or C_b.
"""

import math, json

WORDS, NUM = 2048, 10000
N = WORDS**3 * NUM

R_E = 6371008.8
AREA = 4 * math.pi * R_E**2
M_PER_DEG_LAT = math.pi * R_E / 180.0

LAT_SPAN_NS = 180_000_000_000
LON_SPAN_NS = 360_000_000_000

INT64_MAX = 2**63 - 1
UINT64_MAX = 2**64 - 1


def build(rows: int, bands: int, target_m: float):
    """Build a band table. Returns None if it does not fit."""
    assert rows % bands == 0, "rows must divide evenly into bands"
    rows_per_band = rows // bands
    row_h_deg = 180.0 / rows

    col_counts = []
    for b in range(bands):
        lat_lo = -90.0 + b * 180.0 / bands
        lat_hi = lat_lo + 180.0 / bands
        # equator-ward edge: the edge with the larger |cos|
        edge = lat_lo if abs(lat_lo) < abs(lat_hi) else lat_hi
        c = math.cos(math.radians(edge))
        cols = int(360.0 * M_PER_DEG_LAT * c / target_m)
        col_counts.append(max(1, cols))

    total = sum(c * rows_per_band for c in col_counts)
    if total > N:
        return None

    # cumulative cell offset at the start of each band
    offsets, acc = [], 0
    for c in col_counts:
        offsets.append(acc)
        acc += c * rows_per_band

    return {
        "rows": rows,
        "bands": bands,
        "rows_per_band": rows_per_band,
        "target_m": target_m,
        "col_counts": col_counts,
        "offsets": offsets,
        "total_cells": total,
        "row_h_m": row_h_deg * M_PER_DEG_LAT,
    }


def geometry(t):
    """Cell dimensions across latitudes, excluding the polar caps."""
    rows_per_band = t["rows_per_band"]
    worst_w = 0.0
    widths = []
    for b, cols in enumerate(t["col_counts"]):
        lat_lo = -90.0 + b * 180.0 / t["bands"]
        lat_hi = lat_lo + 180.0 / t["bands"]
        for lat in (lat_lo, lat_hi):
            if abs(lat) >= 89.0:
                continue
            w = 360.0 / cols * M_PER_DEG_LAT * math.cos(math.radians(lat))
            widths.append(w)
            worst_w = max(worst_w, w)
    return {
        "max_width_m": worst_w,
        "min_width_m": min(widths),
        "mean_width_m": sum(widths) / len(widths),
    }


def overflow_check(t):
    """Largest intermediate products in the encode path."""
    lat_prod = LAT_SPAN_NS * t["rows"]
    lon_prod = LON_SPAN_NS * max(t["col_counts"])
    return {
        "lat_product": lat_prod,
        "lon_product": lon_prod,
        "fits_int64": max(lat_prod, lon_prod) <= INT64_MAX,
        "fits_uint64": max(lat_prod, lon_prod) <= UINT64_MAX,
        "int64_headroom": INT64_MAX / max(lat_prod, lon_prod),
    }


if __name__ == "__main__":
    target = 3.0
    ideal_rows = 180.0 * M_PER_DEG_LAT / target
    print(f"ideal row count at {target}m: {ideal_rows:,.0f}\n")

    print(f"{'rows':>10} {'bands':>7} {'cells':>16} {'fill':>7} "
          f"{'row_h':>7} {'maxW':>7} {'table_KB':>9}")
    print("-" * 70)

    best = None
    for rows in (6_291_456, 6_400_000, 6_553_600, 6_672_000, 6_750_000):
        for bands in (512, 1024, 2048, 4096):
            if rows % bands:
                continue
            t = build(rows, bands, target)
            if not t:
                print(f"{rows:>10,} {bands:>7} {'DOES NOT FIT':>16}")
                continue
            g = geometry(t)
            kb = bands * 12 / 1024
            print(f"{rows:>10,} {bands:>7} {t['total_cells']:>16,} "
                  f"{t['total_cells']/N:>6.3f} {t['row_h_m']:>6.3f}m "
                  f"{g['max_width_m']:>6.3f}m {kb:>8.1f}")
            score = abs(t["row_h_m"] - target) + abs(g["max_width_m"] - target)
            if best is None or score < best[0]:
                best = (score, t, g)

    _, t, g = best
    print(f"\nchosen: rows={t['rows']:,} bands={t['bands']}")
    print(f"  total cells   {t['total_cells']:,}  ({t['total_cells']/N:.4f} of space)")
    print(f"  invalid space {(1-t['total_cells']/N)*100:.1f}%  (typo rejection rate)")
    print(f"  row height    {t['row_h_m']:.4f} m")
    print(f"  cell width    min {g['min_width_m']:.4f}  mean {g['mean_width_m']:.4f}  max {g['max_width_m']:.4f} m")
    print(f"  cols equator  {max(t['col_counts']):,}")
    print(f"  cols at pole  {min(t['col_counts']):,}")
    print(f"  table size    {t['bands']*12/1024:.1f} KB")

    o = overflow_check(t)
    print(f"\noverflow: lat_prod={o['lat_product']:.4e} lon_prod={o['lon_product']:.4e}")
    print(f"  int64 ok={o['fits_int64']} (headroom {o['int64_headroom']:.2f}x)  uint64 ok={o['fits_uint64']}")

    with open("bands.json", "w") as f:
        json.dump({k: t[k] for k in
                   ("rows", "bands", "rows_per_band", "target_m",
                    "col_counts", "offsets", "total_cells")}, f)
    print("\nwrote bands.json")
