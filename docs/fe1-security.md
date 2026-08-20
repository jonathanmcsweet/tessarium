# FE1 at Tessarium's parameters, against the published attacks

This is the write-up the roadmap demanded: the format-preserving encryption
literature has real attacks in it, this project's mapping is built from the
same family those attacks target, and a dismissal is only worth reading if
it names the attacks, their requirements, and this system's numbers. Every
number here is verifiable in this repository; where a claim rests on a
measurement, the progress ledger records how it was taken.

## The construction

The private mapping is an FE1 generalised Feistel (Black–Rogaway) over
Z_a × Z_b with

| Parameter | Value | Where |
|---|---|---|
| a | 6,553,600 = 2^18 × 25 ≈ 2^22.6 | `fstar/Tessarium.Spec.fst` |
| b | 13,107,200 = 2^19 × 25 ≈ 2^23.6 | `fstar/Tessarium.Spec.fst` |
| Domain a·b | 8.59 × 10^13 (every address) | |
| Rounds | 16 (even, by proof obligation) | `fstar/Tessarium.Feistel.fst` |
| Round function | keyed BLAKE2s-256, full PRF per round | injected, `ocaml/lib`; vector-pinned machine-integer port in `fstar/low` |
| Tweak | the fixed string `tessarium-grid-2` | not an input anywhere |
| Key | 32 bytes: mnemonic → PBKDF2-HMAC-SHA512 × 2,048 (BIP-39) → PBKDF2-HMAC-SHA512 × 200,000, salt `tessarium-kdf-2` | `ocaml/lib/tessarium.ml` |

The a:b split is 2:1 — near-balanced, one bit of imbalance, which the FE1
analysis tolerates (the pair it replaced was 250:1; the correction is in
the ledger). The product is exactly the address space, so the bijection is
exact: no cycle-walking, no partial rounds.

## What an attacker can hold, and what it costs

Two oracles exist, and both matter more than the algebra:

- **The UI answers "what is this square's address" on demand.** Encoding is
  local (the key never leaves the device), so this oracle is the user's own
  machine — an attacker who can query it is already running code where the
  key lives, and cryptanalysis is not their cheapest move.
- **`--api` mode is an encode/decode oracle over HTTP.** It is off by
  default, loopback-only, and rate-limited. The limiter is load-bearing and
  this document is where that is written down — literally: writing it
  revealed that only `/api/session` was throttled, and encode/decode were
  raw oracles; the limiter now covers every key-touching endpoint
  (`rate_limited_endpoint` in `ocaml/server/serve.ml`, mutation-tested).
  A raw encode is ~81 µs measured at 16 rounds
  (`ocaml/tools/bench_encode.ml`), so an *unthrottled* oracle would answer
  a million queries in under two minutes. At the enforced 1 request/second
  (burst 10, shared across session, encode and decode), a million queries
  is ~11.6 days of uninterrupted hammering, and the full codebook — all
  8.59 × 10^13 addresses — is about 2.7 million years. The basemap
  endpoints sit outside this bucket: they touch tiles, never the key, and
  carry their own work bounds.

Shared addresses are the third channel: each address a user reveals, paired
with where it truly is, is one known plaintext/ciphertext pair. Users
reveal these one at a time, by choice. The attacks below are measured in
millions of *chosen* queries.

## The published attacks, one at a time

**Bellare–Hoang–Tessaro 2016** (message-recovery on Feistel FPE, CCS 2016).
Recovers unknown parts of messages given many chosen encryptions, against
FF1/FF3-style networks. Its demonstrations live on tiny domains — PIN- and
credit-card-digit scale, at the standards' round counts (8–10) — because
the data requirement grows as a power of the half-domain size with the
round count. At a ≈ 2^22.6, b ≈ 2^23.6 and 16 rounds, the required data is
astronomically beyond both the codebook itself and the limiter-bounded
query budget above. The structural lesson BHT teaches — Feistel FPE
security degrades on *small* domains — cuts the other way here: this
domain is ~2^46.3.

**Durak–Vaudenay 2017** (breaking FF3 over small domains, CRYPTO 2017).
A slide attack requiring *chosen tweaks*: FF3 XORs an attacker-supplied
tweak into its round inputs, and the attack needs encryptions under related
tweaks, on 8 rounds. Structurally inapplicable twice over: Tessarium's
tweak is a compile-time version constant (`tessarium-grid-2`) that no
API, UI or file format accepts as input, and there are 16 rounds, not 8.
The fix NIST eventually shipped (FF3-1) restricts tweaks — the very input
this design never exposed.

**Hoang–Miller–Trieu 2019** ("Attacks Only Get Better", EUROCRYPT 2019).
Improves Durak–Vaudenay to larger domains and fewer data, but remains a
slide attack on FF3's 8-round, tweak-XOR structure. Same two structural
non-starters as above.

**The generic bound.** With a PRF as round function, generalized Feistel
security *proofs* (Black–Rogaway's original analysis; Patarin's and later
Hoang–Rogaway's bounds for many rounds) give security that improves with
round count. The attack *families* above are parameterized by round count
with data requirements growing accordingly; every practical demonstration
in the literature targets the standards' 8–10-round instantiations.
Sixteen was chosen (raised from ten in this project's history, with the
rationale in the ledger) to sit above all of it with margin, at a cost of
six more MAC calls per address — noise next to the KDF.

## The endgame an attacker cannot reach past

Suppose the impossible: the complete codebook, every address paired with
its square. That is the private *map*, fully reconstructed — and it is
still not the *key*. The key sits behind keyed BLAKE2s as a PRF: recovering
it from any number of input/output pairs is generic key search.

Two search spaces exist, and the honest claim needs both stated together:

- **Phrase space.** 24 words carry 256 bits of entropy (128 effective
  post-Grover). Each guess pays the KDF: 202,048 PBKDF2 iterations —
  deliberately, 98.7× BIP-39's baseline.
- **Raw key space.** A 32-byte Feistel key can be guessed directly for 16
  MAC calls per try, skipping the KDF entirely. The KDF hardening is therefore
  NOT what protects against raw-key search — 2^256 keys (2^128
  post-Grover) is. A raw-key hit would decrypt the map but yields no
  phrase: the KDF cannot be run backwards, and nothing in this system
  accepts a raw key as an identity.

Stating the first without the second would make the hardening claim false.
The hardening prices *phrase* guessing, where human-memorable secrets live;
the raw keyspace needs no pricing.

## Quantum

Everything here is hashes and a keyed permutation; Shor has no target.
Grover's square-root speedup is provably optimal for generic search (BBBV
1997), and every strength figure above is already the post-Grover number.

The Feistel-specific quantum results deserve their names: Kuwakado–Morii's
distinguishers and their descendants require *superposition queries* to the
keyed construction — running Tessarium's code with Tessarium's key on
the attacker's quantum hardware. A classical API answers classical bytes;
software the attacker does not control is out of these attacks' model. The
"offline" variants that drop the superposition-query requirement
(Bonnetain–Hosoyamada–Naya-Plasencia–Sasaki–Schrottenloher 2019) target
Even–Mansour and FX-style constructions and few-round Feistel
distinguishers, not sixteen rounds with a full PRF inside. Citing those
papers against this design is the expected move; this paragraph exists so
the dismissal reads as informed rather than unaware.

## What this document does not claim

The F\* proofs establish that decode inverts encode for *any* round
function, and that the grid is injective. They say nothing about
pseudorandomness. Unpredictability of the mapping rests on keyed BLAKE2s
behaving as a PRF — an assumption, named as such in the README, and the
standard one underneath Argon2 and WireGuard's use of the same primitive —
and on the key-derivation chain above. If BLAKE2s falls, the hash is an
injected parameter: swap it, bump the grid version, regenerate the vectors
(exercised for real in the 2026-08-20 HMAC-SHA256 → BLAKE2s move).

## References

- Black, Rogaway. *Ciphers with Arbitrary Finite Domains.* CT-RSA 2002.
- Bellare, Hoang, Tessaro. *Message-Recovery Attacks on Feistel-Based
  Format-Preserving Encryption.* CCS 2016.
- Durak, Vaudenay. *Breaking the FF3 Format-Preserving Encryption Standard
  over Small Domains.* CRYPTO 2017.
- Hoang, Miller, Trieu. *Attacks Only Get Better: How to Break FF3 on
  Large Domains.* EUROCRYPT 2019.
- Bennett, Bernstein, Brassard, Vazirani. *Strengths and Weaknesses of
  Quantum Computing.* SIAM J. Comput. 1997.
- Kuwakado, Morii. *Quantum distinguisher between the 3-round Feistel
  cipher and the random permutation.* ISIT 2010.
- Hosoyamada, Sasaki. *Quantum Demiric-Selçuk Meet-in-the-Middle Attacks:
  Applications to 6-Round Generic Feistel Constructions.* SCN 2018.
- Bonnetain, Hosoyamada, Naya-Plasencia, Sasaki, Schrottenloher. *Quantum
  Attacks without Superposition Queries: the Offline Simon's Algorithm.*
  ASIACRYPT 2019.
