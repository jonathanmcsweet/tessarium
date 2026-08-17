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

import math, json, sys
from pathlib import Path

WORDS, NUM = 2048, 10000
N = WORDS**3 * NUM

HERE = Path(__file__).parent
GRID_VERSION = "tessarium-grid-1"

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


def cumulative(col_counts: list) -> list:
    """Running total of column counts, length len(col_counts) + 1.

    Storing cumulative counts rather than the two tables the grid consumes is
    what keeps the proof small. offsets[b] is cum[b] * rows_per_band and
    col_counts[b] is cum[b+1] - cum[b], both by definition, so band-offset
    contiguity needs no proof at all. The only fact left to establish about the
    data is that adjacent differences lie in (0, max], which gives positive
    column counts and the per-band width bound together.
    """
    acc, out = 0, [0]
    for c in col_counts:
        acc += c
        out.append(acc)
    return out


def _chunk_literal(name: str, values: list, per_line: int = 8) -> str:
    lines = [f'[@@"opaque_to_smt"]', f"let {name} : (l: list nat{{Cons? l}}) = ["]
    for i in range(0, len(values), per_line):
        row = "; ".join(str(v) for v in values[i:i + per_line])
        lines.append(f"  {row}" + (";" if i + per_line < len(values) else ""))
    lines.append("]")
    return "\n".join(lines)


def emit_fstar(t: dict, path, chunks: int = 17) -> None:
    """Write the band table as a verifiable F* module.

    Reads the committed table rather than regenerating it: this emitter must
    never be able to perturb the grid.

    The data is split into chunks, each marked opaque to SMT. Both properties
    matter and were measured. Opacity: a module that puts 4096 literals into the
    SMT encoding makes every query in that module intractable, down to trivial
    index bounds, while the normaliser can still compute over an opaque term.
    Chunking: one whole-table `assert_norm` costs 56 s and 6.6 GB, where
    per-chunk obligations folded together cost about 2 s and 300 MB.
    """
    cum = cumulative(t["col_counts"])
    n = len(cum)
    if n % chunks:
        raise ValueError(f"{n} cumulative entries do not divide into {chunks} chunks")
    size = n // chunks
    parts = [cum[i * size:(i + 1) * size] for i in range(chunks)]
    max_col = max(cum[i + 1] - cum[i] for i in range(n - 1))

    # The interface hides the literals outright: downstream modules see an
    # abstract list plus the two facts about it, so no SMT query anywhere else
    # in the development can ever be handed 4097 constants.
    path.with_suffix(".fsti").write_text(f'''module Tessarium.Table.Data

/// GENERATED by `python3 grid_design.py --emit-fstar` from design/bands.json.
/// DO NOT EDIT.
///
/// `cumcols_list` is abstract on purpose. The implementation holds {n}
/// literals, and a module that lets those into its SMT encoding cannot
/// discharge even a trivial index bound. Everything downstream works from the
/// two lemmas below instead.

module L = FStar.List.Tot

open Tessarium.Scan

let grid_version : string = "{GRID_VERSION}"

let rows          : pos = {t["rows"]}
let bands         : pos = {t["bands"]}
let rows_per_band : pos = {t["rows_per_band"]}
let total_cells   : pos = {t["total_cells"]}

/// Widest band, at the equator. Bounds every intermediate in the encode path.
let max_col_count : pos = {max_col}

/// Cumulative column counts: cum[b] is the total number of columns in every
/// band before b. Storing the running total rather than the two tables the
/// grid consumes is what makes band-offset contiguity true by definition:
/// offsets[b] is cum[b] * rows_per_band and col_counts[b] is cum[b+1] - cum[b].
/// The length lives in the type rather than in a lemma, so that indexing the
/// table is well-typed everywhere without first calling something.
val cumcols_list : l: list nat{{Cons? l /\\ L.length l == bands + 1}}

/// Adjacent differences lie in (0, max_col_count]. Strict increase gives every
/// band a positive column count; the bound gives the per-band width limit.
val lemma_diffs : unit -> Lemma (diffs_ok cumcols_list max_col_count)

/// The table starts at zero, so band 0 begins at cell 0.
val lemma_base : unit -> Lemma (L.index cumcols_list 0 == 0)

/// The grand total, which is what makes the grid fit the address space.
val lemma_total : unit -> Lemma (L.index cumcols_list bands * rows_per_band == total_cells)
''')

    out = [f'''module Tessarium.Table.Data

/// GENERATED by `python3 grid_design.py --emit-fstar` from design/bands.json.
/// DO NOT EDIT.
///
/// Regenerating the band table changes every address that has ever been
/// issued. If it ever changes, the tweak string must be bumped and every test
/// vector regenerated, rather than silently reinterpreting old addresses.

module L = FStar.List.Tot

open Tessarium.Scan

(* The constants live in the interface and are inherited here. *)

(* ------------------------------------------------------------------- data *)

/// Cumulative column counts, {n} entries: cum[b] is the total number of
/// columns in all bands before b. Held in {chunks} chunks of {size} so that no
/// proof obligation ever spans the whole table.''']

    for i, part in enumerate(parts):
        out.append(_chunk_literal(f"c{i}", part))

    out.append('''
(* ----------------------------------------------------------------- tails *)

/// Right-associated, so each fold step below compares one concrete chunk's
/// last element against the head of everything that follows it.''')

    last = chunks - 1
    out.append(f"let t{last} : (l: list nat{{Cons? l}}) = c{last}")
    for i in range(chunks - 2, -1, -1):
        out.append(f"""let t{i} : (l: list nat{{Cons? l}}) =
  lemma_hd_append c{i} t{i + 1};
  c{i} `L.append` t{i + 1}""")

    out.append('''
(* ----------------------------------------------- per-chunk facts and fold *)

/// Each of these is discharged by the normaliser over one chunk alone. The
/// SMT solver never sees a literal.''')

    out.append(f"""
val length_fold : unit -> Lemma (L.length t0 == bands + 1)
let length_fold () =""")
    for i in range(chunks):
        out.append(f"  assert_norm (L.length c{i} == {size});")
    for i in range(chunks - 2, -1, -1):
        out.append(f"  L.append_length c{i} t{i + 1};")
    out.append("  ()")

    out.append(f"""
let cumcols_list =
  length_fold ();
  t0""")

    out.append(f"""
let lemma_diffs () =
  assert_norm (diffs_ok c{last} max_col_count == true);""")
    for i in range(chunks - 2, -1, -1):
        out.append(f"""  assert_norm (diffs_ok c{i} max_col_count == true);
  assert_norm (L.last c{i} == {parts[i][-1]});
  assert_norm (L.hd c{i + 1} == {parts[i + 1][0]});""")
        if i < chunks - 2:
            out.append(f"  lemma_hd_append c{i + 1} t{i + 2};")
        out.append(f"  lemma_diffs_append c{i} t{i + 1} max_col_count;")
    out.append("  ()")

    # The grand total is the final element. Reaching it by `assert_norm` on
    # L.index walks all the cells and costs 22 s / 4.3 GB; folding `last`
    # across the chunks instead leaves one small per-chunk normalisation.
    out.append(f"""
let lemma_base () =
  lemma_hd_append c0 t1;
  assert_norm (L.hd c0 == {cum[0]})""")

    out.append(f"""
let lemma_total () =
  L.lemma_unsnoc_is_last cumcols_list;""")
    for i in range(chunks - 1):
        out.append(f"  L.lemma_append_last c{i} t{i + 1};")
    out.append(f"  assert_norm (L.last c{last} == {cum[-1]})")

    path.write_text("\n".join(out) + "\n")


if __name__ == "__main__":
    if "--emit-fstar" in sys.argv:
        table = json.loads((HERE / "bands.json").read_text())
        out = HERE.parent / "fstar" / "Tessarium.Table.Data.fst"
        emit_fstar(table, out)
        print(f"wrote {out} ({out.stat().st_size / 1024:.1f} KB, "
              f"{table['bands']} bands)")
        sys.exit(0)

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
