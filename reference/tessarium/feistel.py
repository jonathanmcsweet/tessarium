"""
Format-preserving permutation over the exact address space.

The address space is N = 2048^3 * 10^4 = 2^37 * 625, which factors into a
near-balanced pair:

    a = 2^18 * 25 =  6_553_600     (~22.6 bits)
    b = 2^19 * 25 = 13_107_200     (~23.6 bits)
    a * b = N                       exactly

Because a * b hits N on the nose, this is a bijection on [0, N) with no
cycle-walking, and therefore no probabilistic termination argument to carry
through a proof.

The construction is Black-Rogaway FE1 (Ciphers with Arbitrary Finite Domains,
CT-RSA 2002). Halves swap domains each round, so an even round count returns
them to their original ranges.

Round count is 10. Four rounds is distinguishable; the cost here is a few
microseconds and the margin is free.
"""

import hmac, hashlib

A = 2**18 * 25          #  6_553_600
B = 2**19 * 25          # 13_107_200
N = A * B               # 85_899_345_920_000
ROUNDS = 10

assert N == 2048**3 * 10000


def _round_func(key: bytes, tweak: bytes, i: int, x: int, m: int) -> int:
    """PRF output reduced into [0, m).

    128 bits are taken before reduction. With m < 2^24 the modulo bias is
    around 2^-104, which is far below any threshold that matters.
    """
    msg = (b"tessarium/v1/fe1"
           + len(tweak).to_bytes(2, "big") + tweak
           + i.to_bytes(1, "big")
           + x.to_bytes(8, "big"))
    digest = hmac.new(key, msg, hashlib.sha256).digest()
    return int.from_bytes(digest[:16], "big") % m


def encrypt(key: bytes, tweak: bytes, x: int) -> int:
    """Permute x within [0, N)."""
    assert 0 <= x < N
    left, right = divmod(x, B)          # left in [0,A), right in [0,B)
    for i in range(1, ROUNDS + 1):
        m = A if i % 2 else B
        left, right = right, (left + _round_func(key, tweak, i, right, m)) % m
    return left * B + right


def decrypt(key: bytes, tweak: bytes, y: int) -> int:
    """Inverse of encrypt."""
    assert 0 <= y < N
    left, right = divmod(y, B)
    for i in range(ROUNDS, 0, -1):
        m = A if i % 2 else B
        left, right = (right - _round_func(key, tweak, i, left, m)) % m, left
    return left * B + right
