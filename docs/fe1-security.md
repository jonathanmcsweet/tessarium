# FE1 at Tessarium's parameters, against the published attacks

The format-preserving encryption literature has real attacks in it, and this
project's private mapping is built from the family those attacks target. A
dismissal is only worth reading if it names the attacks, states what each one
needs, and puts this system's numbers beside them. Every number here is
checkable in this repository.

## The construction

An FE1 generalised Feistel (Black–Rogaway) over Z_a × Z_b:

| Parameter | Value | Where |
|---|---|---|
| a | 6,553,600 = 2^18 × 25 ≈ 2^22.6 | `fstar/Tessarium.Spec.fst` |
| b | 13,107,200 = 2^19 × 25 ≈ 2^23.6 | `fstar/Tessarium.Spec.fst` |
| Domain a·b | 85,899,345,920,000 ≈ 2^46.3 — every address | `Tessarium.Spec.addr_space` |
| Rounds | 16 (even, by proof obligation) | `fstar/Tessarium.Feistel.fst` |
| Round function | keyed BLAKE2s-256, full PRF per round | injected, `ocaml/lib`; vector-pinned machine-integer port in `fstar/low` |
| Tweak | the fixed string `tessarium-grid-3` | not an input anywhere |
| Key | 32 bytes: Argon2id(t=3, m=64 MiB, p=1) over the NFKD phrase, salt `tessarium-kdf-4` ++ passphrase | `ocaml/lib/tessarium.ml`, `ocaml/argon2` |

The split is 2:1 — one bit of imbalance, which the FE1 analysis tolerates.
The product is exactly the address space, so the permutation is exact: no
cycle-walking, no partial rounds.

## What an attacker can ask, and what it costs

Two oracles exist, and both matter more than the algebra.

**The UI answers "what is this square called" on demand.** Encoding happens
on the device and the key never leaves it, so this oracle is the user's own
machine. Anyone who can query it is already running code where the key lives,
and cryptanalysis is not their cheapest move.

**`--api` mode is an encode/decode oracle over HTTP.** Off by default,
loopback only, and rate-limited: `rate_limited_endpoint` in
`ocaml/server/serve.ml` lists every endpoint that touches the key, and they
share one bucket. The arithmetic is why that limiter is load-bearing rather
than hygienic.

| | Time |
|---|---|
| A raw encode, measured at 16 rounds (`ocaml/tools/bench_encode.ml`) | 56 µs |
| A million queries against an *unthrottled* oracle | under a minute |
| A million queries at the enforced 1/second (burst 10) | ~11.6 days |
| The full codebook, all 8.59 × 10^13 addresses, at 1/second | ~2.7 million years |

Basemap endpoints sit outside it: they touch tiles, never the key.

A third channel is quieter. Every address a user shares, paired with where it
really is, is one known plaintext and ciphertext — revealed one at a time, by
choice. The attacks below need millions of *chosen* queries.

## The published attacks

**Bellare–Hoang–Tessaro 2016** — message recovery on Feistel FPE, from many
chosen encryptions. Its demonstrations are on tiny domains, PIN and
credit-card scale, at the standards' 8–10 rounds, because the data required
grows as a power of the half-domain size with the round count. At a ≈ 2^22.6,
b ≈ 2^23.6 and 16 rounds it is far past both the codebook and the
limiter-bounded budget above. Its lesson — Feistel FPE degrades on *small*
domains — points the other way here.

**Durak–Vaudenay 2017** — breaking FF3 over small domains. A slide attack
that needs *chosen tweaks*: FF3 mixes an attacker-supplied tweak into its
round inputs, and the attack needs encryptions under related ones, at 8
rounds. Inapplicable twice over. Tessarium's tweak is a build-time version
string that no API, no UI and no file format accepts as input, and there are
16 rounds. The repair NIST eventually shipped (FF3-1) restricts tweaks — the
input this design never exposed.

**Hoang–Miller–Trieu 2019** — the same slide attack on the same 8-round
tweak-XOR structure, improved to larger domains and less data. The same two
non-starters.

**The generic bound.** With a PRF as the round function, generalised Feistel
security proofs improve with round count, and the attacks above get harder
with it. Sixteen was chosen to sit above all of them with margin, at a cost
of six more MAC calls per address — noise next to the key derivation.

## If the whole map fell anyway

Suppose the impossible: the complete codebook, every address paired with its
square. That is the private *map* reconstructed. It is still not the *key*.
Recovering the key from any number of input/output pairs is generic search.

Two search spaces exist, and the honest claim needs both.

- **Phrase space.** 24 words carry 256 bits of entropy, 128 after Grover.
  Each guess pays the key derivation: Argon2id at 64 MiB is memory-hard, so
  a perfectly parallel GPU farm pays 64 MiB of real memory per concurrent
  guess rather than raw arithmetic.
- **Raw key space.** A 32-byte Feistel key can be guessed directly for 16 MAC
  calls per try, skipping the derivation entirely. So the memory-hardness is
  **not** what protects against raw-key search — 2^256 keys (2^128 after
  Grover) is. A raw-key hit would decrypt the map and yield no phrase: the
  derivation does not run backwards, and nothing here accepts a raw key as an
  identity.

The hardening prices *phrase* guessing, where human-memorable secrets live;
the raw key space needs no pricing. Stating the first without the second
would make the claim false.

## Quantum

This is hashes and a keyed permutation, so Shor has no target. Grover's
square-root speedup is provably optimal for generic search (BBBV 1997), and
every figure above is already the post-Grover number.

The Feistel-specific quantum results deserve their names. Kuwakado–Morii's
distinguishers and their descendants need *superposition queries* to the
keyed construction — running this code with this key on the attacker's own
quantum hardware — and a classical API answers classical bytes. The offline
variants that drop that requirement (Bonnetain et al. 2019) target
Even–Mansour and FX constructions and few-round Feistel distinguishers, not
sixteen rounds with a full PRF inside.

## What this document does not claim

The proofs that bear on this argument establish shape, not secrecy: that
decode inverts encode for *any* round function, that the grid is injective,
and that the machine-integer core behind the C and WebAssembly builds gives
the same answers as the specification, for any round function matching the
specification's. The BLAKE2s that supplies it is pinned by the RFC's vectors
rather than proved to be RFC 7693 — the seam between those two facts. None of
it says anything about pseudorandomness.

That the mapping is unpredictable rests on keyed BLAKE2s behaving as a PRF,
and on the derivation chain above. That is an assumption, named as one in the
README, and the standard one underneath Argon2 and WireGuard's use of the
same primitive.

If BLAKE2s ever falls, the hash is an injected parameter: swap it, bump the
grid version, regenerate the vectors. That path was exercised for real in the
2026-08-20 move off HMAC-SHA256.

## References

- Black, Rogaway. *Ciphers with Arbitrary Finite Domains.* CT-RSA 2002.
- Bellare, Hoang, Tessaro. *Message-Recovery Attacks on Feistel-Based
  Format-Preserving Encryption.* CCS 2016.
- Durak, Vaudenay. *Breaking the FF3 Format-Preserving Encryption Standard
  over Small Domains.* CRYPTO 2017.
- Hoang, Miller, Trieu. *Attacks Only Get Better: How to Break FF3 on Large
  Domains.* EUROCRYPT 2019.
- Bennett, Bernstein, Brassard, Vazirani. *Strengths and Weaknesses of
  Quantum Computing.* SIAM J. Comput. 1997.
- Kuwakado, Morii. *Quantum distinguisher between the 3-round Feistel cipher
  and the random permutation.* ISIT 2010.
- Hosoyamada, Sasaki. *Quantum Demiric-Selçuk Meet-in-the-Middle Attacks:
  Applications to 6-Round Generic Feistel Constructions.* SCN 2018.
- Bonnetain, Hosoyamada, Naya-Plasencia, Sasaki, Schrottenloher. *Quantum
  Attacks without Superposition Queries: the Offline Simon's Algorithm.*
  ASIACRYPT 2019.
