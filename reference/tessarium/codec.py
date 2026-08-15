"""
Address codec and the public encode/decode API.

An address is three BIP-39 words plus a four-digit number:

    slice.mobile.artwork.4271

Mixed radix (2048, 2048, 2048, 10000) over the permuted index.

Roughly 35% of syntactically valid addresses decode to an index at or above
TOTAL_CELLS and are rejected. That rejection is free typo detection: a
mistyped address is overwhelmingly likely to be refused outright rather than
silently resolving somewhere plausible.
"""

from . import feistel, grid
from .bands import GRID_VERSION, TOTAL_CELLS
from .keyderiv import WORDLIST, WORD_INDEX

RADIX_NUM = 10000
SEP = "."

# Bound the mapping to a specific grid. Regenerating the band table changes
# every address rather than silently reinterpreting old ones.
TWEAK = GRID_VERSION


class InvalidAddress(ValueError):
    pass


def index_to_address(y: int) -> str:
    assert 0 <= y < feistel.N
    y, num = divmod(y, RADIX_NUM)
    y, w3 = divmod(y, 2048)
    w1, w2 = divmod(y, 2048)
    return SEP.join([WORDLIST[w1], WORDLIST[w2], WORDLIST[w3], f"{num:04d}"])


def address_to_index(address: str) -> int:
    parts = _split(address)
    if len(parts) != 4:
        raise InvalidAddress(f"expected 3 words and a number, got {len(parts)} parts")
    *words, num_s = parts

    if not (num_s.isdigit() and len(num_s) == 4):
        raise InvalidAddress(f"'{num_s}' is not a four-digit number")
    num = int(num_s)

    idx = []
    for w in words:
        i = _resolve_word(w)
        if i is None:
            raise InvalidAddress(f"'{w}' is not a BIP-39 word")
        idx.append(i)

    return ((idx[0] * 2048 + idx[1]) * 2048 + idx[2]) * RADIX_NUM + num


def _split(address: str) -> list[str]:
    norm = address.strip().lower()
    for ch in ",/ -_":
        norm = norm.replace(ch, SEP)
    return [p for p in norm.split(SEP) if p]


def _resolve_word(w: str):
    """Exact match, else unique 4-letter prefix match.

    BIP-39 guarantees the first four letters identify a word uniquely, so
    'slic' resolves to 'slice'. Shorter fragments are rejected.
    """
    if w in WORD_INDEX:
        return WORD_INDEX[w]
    if len(w) >= 4:
        hits = [i for word, i in WORD_INDEX.items() if word.startswith(w[:4])]
        if len(hits) == 1:
            return hits[0]
    return None


# ---------------------------------------------------------------- public API

def encode(key: bytes, lat_ns: int, lon_ns: int) -> str:
    """Point -> address, under the mapping determined by key."""
    cell = grid.point_to_cell(lat_ns, lon_ns)
    return index_to_address(feistel.encrypt(key, TWEAK, cell))


def decode(key: bytes, address: str) -> tuple[int, int]:
    """Address -> the centre of its cell. Raises if the address is not live."""
    cell = feistel.decrypt(key, TWEAK, address_to_index(address))
    if cell >= TOTAL_CELLS:
        raise InvalidAddress(
            "address does not correspond to any location "
            "(about 35% of word combinations do not; check for a typo)"
        )
    return grid.cell_to_point(cell)


def encode_deg(key: bytes, lat: float, lon: float) -> str:
    """Convenience wrapper. Floats are converted at the boundary only."""
    return encode(key, round(lat * 1e9), round(lon * 1e9))


def decode_deg(key: bytes, address: str) -> tuple[float, float]:
    lat_ns, lon_ns = decode(key, address)
    return lat_ns / 1e9, lon_ns / 1e9
