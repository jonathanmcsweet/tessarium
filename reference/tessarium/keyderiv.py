"""
Seed phrase -> Feistel key.

mnemonic --PBKDF2-HMAC-SHA512--> BIP-39 seed --HKDF-SHA256--> 32-byte key

PBKDF2 is deliberately slow. Derive once per session and cache the result;
it must never sit in the per-request path.

24-word mnemonics only. A 12-word mnemonic carries 128 bits of entropy, which
Grover reduces to an effective 64 bits. 24 words carries 256, leaving 128
after Grover. There is no reason to offer the weaker option.
"""

import hashlib, hmac, unicodedata
from pathlib import Path

WORDLIST = (Path(__file__).parent / "wordlist.txt").read_text().split()
assert len(WORDLIST) == 2048
WORD_INDEX = {w: i for i, w in enumerate(WORDLIST)}

REQUIRED_WORDS = 24
HKDF_SALT = b"tessarium/v1/salt"
HKDF_INFO = b"tessarium/v1/feistel-key"
KEY_LEN = 32


class BadMnemonic(ValueError):
    pass


def _normalize(s: str) -> str:
    return unicodedata.normalize("NFKD", s.strip().lower())


def validate_mnemonic(mnemonic: str) -> list[str]:
    """Check word count, membership and BIP-39 checksum. Returns the words."""
    words = _normalize(mnemonic).split()
    if len(words) != REQUIRED_WORDS:
        raise BadMnemonic(
            f"expected {REQUIRED_WORDS} words, got {len(words)}. "
            "12-word phrases are not accepted: 128 bits of entropy is only "
            "64 bits against a quantum adversary."
        )
    unknown = [w for w in words if w not in WORD_INDEX]
    if unknown:
        raise BadMnemonic(f"not BIP-39 words: {', '.join(unknown[:4])}")

    bits = 0
    for w in words:
        bits = (bits << 11) | WORD_INDEX[w]
    # 24 words = 264 bits = 256 entropy + 8 checksum
    checksum = bits & 0xFF
    entropy = (bits >> 8).to_bytes(32, "big")
    if hashlib.sha256(entropy).digest()[0] != checksum:
        raise BadMnemonic("checksum failed -- likely a typo in one word")
    return words


def mnemonic_to_seed(mnemonic: str, passphrase: str = "") -> bytes:
    """BIP-39 standard seed derivation. 64 bytes."""
    words = validate_mnemonic(mnemonic)
    return hashlib.pbkdf2_hmac(
        "sha512",
        " ".join(words).encode(),
        ("mnemonic" + _normalize(passphrase)).encode(),
        2048,
        dklen=64,
    )


def hkdf_sha256(ikm: bytes, salt: bytes, info: bytes, length: int) -> bytes:
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    out, block, counter = b"", b"", 1
    while len(out) < length:
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        out += block
        counter += 1
    return out[:length]


def derive_key(mnemonic: str, passphrase: str = "") -> bytes:
    """Full path: mnemonic -> 32-byte Feistel key."""
    return hkdf_sha256(mnemonic_to_seed(mnemonic, passphrase),
                       HKDF_SALT, HKDF_INFO, KEY_LEN)
