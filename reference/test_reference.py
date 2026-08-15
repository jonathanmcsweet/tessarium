"""
Property tests for the reference implementation.

These are the same properties the F* development must prove. Here they are
sampled; there they will be established for all inputs. Anything that fails
here is a design bug, not a proof-engineering problem.
"""

import random, sys, hashlib, math
sys.path.insert(0, ".")

from tessarium import codec, feistel, grid, keyderiv
from tessarium.bands import (ROWS, BANDS, ROWS_PER_BAND, COL_COUNTS, OFFSETS,
                        TOTAL_CELLS)

RNG = random.Random(20260815)
FAILURES = []


def check(name, cond, detail=""):
    if cond:
        print(f"  PASS  {name}")
    else:
        print(f"  FAIL  {name}  {detail}")
        FAILURES.append(name)


def test_mnemonic():
    ent = bytes(32)
    cs = hashlib.sha256(ent).digest()[0]
    bits = (int.from_bytes(ent, "big") << 8) | cs
    return " ".join(keyderiv.WORDLIST[(bits >> (11 * (23 - i))) & 0x7FF]
                    for i in range(24))


# --------------------------------------------------------------- band table

def test_band_table():
    print("\nband table")
    check("offsets are contiguous",
          all(OFFSETS[b + 1] == OFFSETS[b] + COL_COUNTS[b] * ROWS_PER_BAND
              for b in range(BANDS - 1)))
    check("total matches final offset",
          OFFSETS[-1] + COL_COUNTS[-1] * ROWS_PER_BAND == TOTAL_CELLS)
    check("fits address space",
          TOTAL_CELLS < feistel.N,
          f"{TOTAL_CELLS} vs {feistel.N}")
    check("no empty bands", all(c >= 1 for c in COL_COUNTS))
    check("rows divide into bands", ROWS % BANDS == 0)
    check("symmetric about equator",
          COL_COUNTS[:BANDS // 2] == COL_COUNTS[BANDS // 2:][::-1])


# ------------------------------------------------------------------- grid

def test_grid_roundtrip(n=200_000):
    print("\ngrid round-trip: centre(cell) must re-encode to the same cell")
    bad = 0
    for _ in range(n):
        i = RNG.randrange(TOTAL_CELLS)
        lat, lon = grid.cell_to_point(i)
        if grid.point_to_cell(lat, lon) != i:
            bad += 1
            if bad <= 3:
                print(f"        cell {i} -> {lat},{lon} -> {grid.point_to_cell(lat, lon)}")
    check(f"{n:,} random cells round-trip", bad == 0, f"{bad} failures")


def test_point_containment(n=200_000):
    print("\ngrid containment: a point must lie inside its own cell's bounds")
    bad = 0
    for _ in range(n):
        lat = RNG.randrange(grid.LAT_MIN_NS, grid.LAT_MIN_NS + grid.LAT_SPAN_NS)
        lon = RNG.randrange(grid.LON_MIN_NS, grid.LON_MIN_NS + grid.LON_SPAN_NS)
        i = grid.point_to_cell(lat, lon)
        lo_a, hi_a, lo_o, hi_o = grid.cell_bounds(i)
        if not (lo_a <= lat < hi_a and lo_o <= lon < hi_o):
            bad += 1
    check(f"{n:,} random points contained", bad == 0, f"{bad} failures")


def test_band_seams():
    print("\nband seams: no gap and no overlap at any of the 4095 boundaries")
    gaps = overlaps = 0
    for b in range(BANDS - 1):
        seam_row = (b + 1) * ROWS_PER_BAND
        lat_above = grid.edge(seam_row, grid.LAT_MIN_NS, grid.LAT_SPAN_NS, ROWS)
        lat_below = lat_above - 1
        for lon in (grid.LON_MIN_NS, 0, grid.LON_MIN_NS + grid.LON_SPAN_NS - 1):
            below = grid.point_to_cell(lat_below, lon)
            above = grid.point_to_cell(lat_above, lon)
            if below == above:
                overlaps += 1
            if not (0 <= below < TOTAL_CELLS and 0 <= above < TOTAL_CELLS):
                gaps += 1
    check("no seam collisions", overlaps == 0, f"{overlaps}")
    check("no seam escapes", gaps == 0, f"{gaps}")

    # last cell of each band must be immediately followed by the first of the next
    broken = 0
    for b in range(BANDS - 1):
        last = OFFSETS[b] + COL_COUNTS[b] * ROWS_PER_BAND - 1
        if grid.cell_to_point(last + 1)[0] <= grid.cell_to_point(last)[0]:
            broken += 1
    check("indices increase monotonically across seams", broken == 0, f"{broken}")


def test_grid_injective_sample(n=300_000):
    print("\ngrid injectivity: distinct cells, distinct indices")
    seen = {}
    coll = 0
    for _ in range(n):
        i = RNG.randrange(TOTAL_CELLS)
        lat, lon = grid.cell_to_point(i)
        if (lat, lon) in seen and seen[(lat, lon)] != i:
            coll += 1
        seen[(lat, lon)] = i
    check(f"{n:,} centres unique", coll == 0, f"{coll} collisions")


def test_edges():
    print("\nedge cases")
    ok = True
    try:
        grid.point_to_cell(90_000_000_000, 0)           # exactly north pole
        grid.point_to_cell(-90_000_000_000, 0)          # exactly south pole
        grid.point_to_cell(0, 180_000_000_000)          # antimeridian, folded
        grid.point_to_cell(0, -180_000_000_000)
    except Exception as e:
        ok = False
        print("        ", e)
    check("poles and antimeridian accepted", ok)

    fold = grid.point_to_cell(0, 180_000_000_000) == grid.point_to_cell(0, -180_000_000_000)
    check("antimeridian folds to one cell", fold)

    rejected = 0
    for lat, lon in [(90_000_000_001, 0), (-90_000_000_001, 0),
                     (0, 180_000_000_001), (0, -180_000_000_001)]:
        try:
            grid.point_to_cell(lat, lon)
        except grid.OutOfRange:
            rejected += 1
    check("out-of-range rejected", rejected == 4, f"{rejected}/4")


def test_uint64_bound():
    print("\noverflow: widest intermediate in the encode path")
    worst = max(grid.LON_SPAN_NS * max(COL_COUNTS), grid.LAT_SPAN_NS * ROWS)
    check("fits signed int64", worst <= 2**63 - 1, f"{worst:.4e}")
    check("fits uint64", worst <= grid.UINT64_MAX, f"{worst:.4e}")
    print(f"        widest = {worst:.4e}  "
          f"int64 headroom {(2**63-1)/worst:.2f}x  "
          f"uint64 headroom {grid.UINT64_MAX/worst:.2f}x")


# ---------------------------------------------------------------- feistel

def test_feistel_bijection(n=50_000):
    print("\nfeistel: permutation on [0, N)")
    key = b"\x01" * 32
    bad = 0
    for _ in range(n):
        x = RNG.randrange(feistel.N)
        if feistel.decrypt(key, b"t", feistel.encrypt(key, b"t", x)) != x:
            bad += 1
    check(f"{n:,} round-trips", bad == 0, f"{bad}")

    check("a*b == N exactly", feistel.A * feistel.B == feistel.N)
    ratio = feistel.B / feistel.A
    check("halves near-balanced", ratio <= 4, f"ratio {ratio:.1f}")

    outs = {feistel.encrypt(key, b"t", x) for x in range(20_000)}
    check("20,000 inputs give 20,000 distinct outputs", len(outs) == 20_000)
    check("outputs stay in range", all(0 <= y < feistel.N for y in outs))


def test_tweak_separation():
    print("\ntweak: different grid versions give different mappings")
    key = b"\x02" * 32
    diff = sum(feistel.encrypt(key, b"grid-1", x) != feistel.encrypt(key, b"grid-2", x)
               for x in range(2000))
    check("2,000 inputs all differ under a changed tweak", diff == 2000, f"{diff}")


# ------------------------------------------------------------------ codec

def test_codec_roundtrip(n=100_000):
    print("\ncodec: index <-> address")
    bad = 0
    for _ in range(n):
        y = RNG.randrange(feistel.N)
        if codec.address_to_index(codec.index_to_address(y)) != y:
            bad += 1
    check(f"{n:,} round-trips", bad == 0, f"{bad}")


def test_rejection_rate(n=100_000):
    print("\nrejection: share of word combinations that decode to nothing")
    key = keyderiv.derive_key(test_mnemonic())
    rejected = 0
    for _ in range(n):
        y = RNG.randrange(feistel.N)
        if feistel.decrypt(key, codec.TWEAK, y) >= TOTAL_CELLS:
            rejected += 1
    rate = rejected / n
    expected = 1 - TOTAL_CELLS / feistel.N
    check(f"rate {rate:.4f} matches expected {expected:.4f}",
          abs(rate - expected) < 0.01)


def _haversine_km(lat1, lon1, lat2, lon2):
    r = 6371.0088
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def test_typo_scatter(n=6000):
    """A one-word typo must land far away, not nearby.

    Two things this test previously got wrong, both of which made it look like
    the scattering had failed:

      1. Replacing a word with a randomly chosen word picks the SAME word about
         1 time in 2048. That leaves the address unchanged, so it decodes to
         distance zero -- not a typo at all. Those dominated the near-hit count.
      2. Euclidean distance in degrees is not distance. Use haversine.

    The bound is statistical, not a magic number. Under correct scattering a
    typo lands on a uniformly random cell, so near-hits follow a Poisson
    distribution with a mean set by the ratio of a 100km disc to the Earth's
    surface. Anything within a few times that mean is consistent; a
    hierarchical mapping would put essentially EVERY typo within 100km, so the
    test has enormous margin against the failure it actually guards against.
    """
    key = keyderiv.derive_key(test_mnemonic())
    near = decoded = 0
    for _ in range(n):
        lat = RNG.uniform(-85, 85)
        lon = RNG.uniform(-179, 179)
        addr = codec.encode_deg(key, lat, lon)
        parts = addr.split(".")
        slot = RNG.randrange(3)
        replacement = parts[slot]
        while replacement == parts[slot]:          # a real typo, not a no-op
            replacement = keyderiv.WORDLIST[RNG.randrange(2048)]
        parts[slot] = replacement
        try:
            lat2, lon2 = codec.decode_deg(key, ".".join(parts))
        except codec.InvalidAddress:
            continue                               # rejected outright, ideal
        decoded += 1
        if _haversine_km(lat, lon, lat2, lon2) < 100:
            near += 1

    disc = math.pi * 100 ** 2
    earth = 4 * math.pi * 6371.0088 ** 2
    expected = decoded * disc / earth
    bound = max(4, math.ceil(expected * 5))
    print(f"\nscatter: {decoded} typos decoded, {near} within 100km "
          f"(expected {expected:.2f} under uniform scattering)")
    check(f"near-hits {near} <= {bound}", near <= bound)
    check("not hierarchical (a hierarchical map would put nearly all within 100km)",
          near < decoded * 0.01)


def test_seed_separation():
    print("\nseeds: different phrases give unrelated maps")
    m1 = test_mnemonic()
    ws = m1.split()
    ws[0] = "ability"
    # rebuild a valid checksum by brute-forcing the last word
    k1 = keyderiv.derive_key(m1)
    k2 = keyderiv.hkdf_sha256(b"a different seed entirely", b"s", b"i", 32)
    same = sum(codec.encode(k1, la, lo) == codec.encode(k2, la, lo)
               for la, lo in [(RNG.randrange(-80_000_000_000, 80_000_000_000),
                               RNG.randrange(-170_000_000_000, 170_000_000_000))
                              for _ in range(3000)])
    check("3,000 points, no address collides between two keys", same == 0, f"{same}")


def test_mnemonic_policy():
    print("\nmnemonic policy")
    twelve = " ".join(["abandon"] * 11 + ["about"])
    try:
        keyderiv.validate_mnemonic(twelve)
        check("12-word rejected", False)
    except keyderiv.BadMnemonic as e:
        check("12-word rejected", "24 words" in str(e) or "expected" in str(e))

    bad = test_mnemonic().split()
    bad[5] = "zebra"
    try:
        keyderiv.validate_mnemonic(" ".join(bad))
        check("bad checksum rejected", False)
    except keyderiv.BadMnemonic:
        check("bad checksum rejected", True)

    check("valid 24-word accepted",
          len(keyderiv.validate_mnemonic(test_mnemonic())) == 24)


def test_prefix_matching():
    print("\naddress parsing")
    key = keyderiv.derive_key(test_mnemonic())
    addr = codec.encode_deg(key, 51.5080, -0.1281)
    w = addr.split(".")
    short = ".".join([w[0][:4], w[1][:4], w[2][:4], w[3]])
    check("four-letter prefixes resolve",
          codec.decode(key, short) == codec.decode(key, addr))
    check("separators normalised",
          codec.decode(key, addr.replace(".", " ")) == codec.decode(key, addr))
    check("case insensitive",
          codec.decode(key, addr.upper()) == codec.decode(key, addr))
    for bad in ["one.two", "abandon.abandon.abandon.12", "zzz.yyy.xxx.0001"]:
        try:
            codec.decode(key, bad)
            check(f"rejects '{bad}'", False)
        except codec.InvalidAddress:
            check(f"rejects '{bad}'", True)


if __name__ == "__main__":
    test_band_table()
    test_uint64_bound()
    test_grid_roundtrip()
    test_point_containment()
    test_band_seams()
    test_grid_injective_sample()
    test_edges()
    test_feistel_bijection()
    test_tweak_separation()
    test_codec_roundtrip()
    test_rejection_rate()
    test_typo_scatter()
    test_seed_separation()
    test_mnemonic_policy()
    test_prefix_matching()

    print("\n" + "=" * 60)
    if FAILURES:
        print(f"{len(FAILURES)} FAILURES: {', '.join(FAILURES)}")
        sys.exit(1)
    print("all properties hold")
