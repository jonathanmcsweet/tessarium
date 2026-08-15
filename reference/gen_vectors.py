"""Generate the cross-platform test vectors. Every implementation must match."""
import json, sys, hashlib, random
sys.path.insert(0, ".")
from tessarium import codec, feistel, grid, keyderiv
from tessarium.bands import TOTAL_CELLS, GRID_VERSION

def mnemonic_from_entropy(ent: bytes) -> str:
    cs = hashlib.sha256(ent).digest()[0]
    bits = (int.from_bytes(ent, "big") << 8) | cs
    return " ".join(keyderiv.WORDLIST[(bits >> (11 * (23 - i))) & 0x7FF] for i in range(24))

M0 = mnemonic_from_entropy(bytes(32))
M1 = mnemonic_from_entropy(bytes([0xFF]) * 32)
M2 = mnemonic_from_entropy(hashlib.sha256(b"tessarium test vector seed").digest())

rng = random.Random(1)
v = {
  "grid_version": GRID_VERSION.decode(),
  "total_cells": TOTAL_CELLS,
  "address_space": feistel.N,
  "feistel": {"a": feistel.A, "b": feistel.B, "rounds": feistel.ROUNDS},
  "key_derivation": [],
  "feistel_vectors": [],
  "grid_vectors": [],
  "addresses": [],
}

for name, m in (("zero", M0), ("ones", M1), ("hash", M2)):
    v["key_derivation"].append({"name": name, "mnemonic": m,
                                "key": keyderiv.derive_key(m).hex()})

k = bytes.fromhex("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
for x in [0, 1, 12345, feistel.N - 1, TOTAL_CELLS - 1, 987654321012]:
    v["feistel_vectors"].append({"x": x, "y": feistel.encrypt(k, b"tessarium-grid-1", x)})

pts = [(0,0), (51_508_000_000, -128_100_000), (-33_856_800_000, 151_215_300_000),
       (90_000_000_000, 0), (-90_000_000_000, 0), (0, -180_000_000_000),
       (12_345_600_000, 179_999_999_999)]
pts += [(rng.randrange(-90_000_000_000, 90_000_000_000),
         rng.randrange(-180_000_000_000, 180_000_000_000)) for _ in range(40)]
for lat, lon in pts:
    c = grid.point_to_cell(lat, lon)
    clat, clon = grid.cell_to_point(c)
    v["grid_vectors"].append({"lat_ns": lat, "lon_ns": lon, "cell": c,
                              "centre_lat_ns": clat, "centre_lon_ns": clon})

key0 = keyderiv.derive_key(M0)
for lat, lon in pts[:20]:
    v["addresses"].append({"mnemonic": "zero", "lat_ns": lat, "lon_ns": lon,
                           "address": codec.encode(key0, lat, lon)})

json.dump(v, open("../vectors/vectors.json", "w"), indent=1)
print(f"wrote {len(v['key_derivation'])} keys, {len(v['feistel_vectors'])} feistel, "
      f"{len(v['grid_vectors'])} grid, {len(v['addresses'])} addresses")
print("sample:", v["addresses"][1]["address"], "|", v["addresses"][2]["address"])
