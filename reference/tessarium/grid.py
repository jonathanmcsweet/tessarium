"""
Banded equal-area-ish grid over the globe, in exact integer nanodegrees.

No floating point appears anywhere in this module. Every operation is integer
arithmetic so that the OCaml, C and JavaScript implementations produce
bit-identical results. Floats are used only in the offline design script that
generates the band table.

Coordinate convention
---------------------
latitude  in nanodegrees, [-90_000_000_000, +90_000_000_000]
longitude in nanodegrees, [-180_000_000_000, +180_000_000_000)

Longitude wraps; +180 is folded onto -180. Latitude does not wrap; +90 is
clamped into the final row.
"""

from .bands import ROWS, BANDS, ROWS_PER_BAND, COL_COUNTS, OFFSETS, TOTAL_CELLS

LAT_MIN_NS = -90_000_000_000
LAT_SPAN_NS = 180_000_000_000
LON_MIN_NS = -180_000_000_000
LON_SPAN_NS = 360_000_000_000

UINT64_MAX = 2**64 - 1


class OutOfRange(ValueError):
    pass


def _bucket(v: int, v_min: int, span: int, k: int) -> int:
    """floor((v - v_min) * k / span), exactly injective [v_min, v_min+span) -> [0, k).

    The intermediate product is the widest value in the whole encode path.
    Asserted here so the bound is checked in the reference and can be carried
    over as a proof obligation in F*.
    """
    off = v - v_min
    prod = off * k
    assert 0 <= prod <= UINT64_MAX, "intermediate exceeds uint64"
    return prod // span


def point_to_cell(lat_ns: int, lon_ns: int) -> int:
    """Map a point to its cell index in [0, TOTAL_CELLS)."""
    if not (LAT_MIN_NS <= lat_ns <= LAT_MIN_NS + LAT_SPAN_NS):
        raise OutOfRange(f"latitude {lat_ns} out of range")
    if not (LON_MIN_NS <= lon_ns <= LON_MIN_NS + LON_SPAN_NS):
        raise OutOfRange(f"longitude {lon_ns} out of range")

    # fold the wrapping edge; clamp the non-wrapping one
    if lon_ns == LON_MIN_NS + LON_SPAN_NS:
        lon_ns = LON_MIN_NS
    row = _bucket(lat_ns, LAT_MIN_NS, LAT_SPAN_NS, ROWS)
    if row == ROWS:                      # lat exactly +90
        row = ROWS - 1

    band = row // ROWS_PER_BAND
    cols = COL_COUNTS[band]
    col = _bucket(lon_ns, LON_MIN_NS, LON_SPAN_NS, cols)

    return OFFSETS[band] + (row - band * ROWS_PER_BAND) * cols + col


def _band_of_index(index: int) -> int:
    """Binary search OFFSETS for the band containing this cell index."""
    lo, hi = 0, BANDS - 1
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if OFFSETS[mid] <= index:
            lo = mid
        else:
            hi = mid - 1
    return lo


def cell_to_point(index: int) -> tuple[int, int]:
    """Map a cell index to the cell's centre point, in nanodegrees."""
    if not (0 <= index < TOTAL_CELLS):
        raise OutOfRange(f"cell index {index} out of range")

    band = _band_of_index(index)
    cols = COL_COUNTS[band]
    rem = index - OFFSETS[band]
    row = band * ROWS_PER_BAND + rem // cols
    col = rem % cols

    # centre of the cell: lower edge + half a step, done without division loss
    lat_ns = LAT_MIN_NS + ((2 * row + 1) * LAT_SPAN_NS) // (2 * ROWS)
    lon_ns = LON_MIN_NS + ((2 * col + 1) * LON_SPAN_NS) // (2 * cols)
    return lat_ns, lon_ns


def _ceil_div(p: int, q: int) -> int:
    return -((-p) // q)


def edge(k_index: int, v_min: int, span: int, k: int) -> int:
    """Lowest v with _bucket(v, ...) == k_index.

    _bucket is a floor operation, so inverting it takes a CEILING, not a
    floor:

        _bucket(v) == c  <->  c*span <= (v-v_min)*k < (c+1)*span
                         <->  ceil(c*span/k) <= v-v_min < ceil((c+1)*span/k)

    Using floor here instead puts the upper edge one nanodegree short, so
    points in that sliver appear to fall outside their own cell. Caught by
    the containment and band-seam tests.
    """
    return v_min + _ceil_div(k_index * span, k)


def cell_bounds(index: int) -> tuple[int, int, int, int]:
    """(lat_lo, lat_hi, lon_lo, lon_hi) in nanodegrees, half-open at hi."""
    band = _band_of_index(index)
    cols = COL_COUNTS[band]
    rem = index - OFFSETS[band]
    row = band * ROWS_PER_BAND + rem // cols
    col = rem % cols
    return (
        edge(row, LAT_MIN_NS, LAT_SPAN_NS, ROWS),
        edge(row + 1, LAT_MIN_NS, LAT_SPAN_NS, ROWS),
        edge(col, LON_MIN_NS, LON_SPAN_NS, cols),
        edge(col + 1, LON_MIN_NS, LON_SPAN_NS, cols),
    )
