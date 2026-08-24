// Independent JavaScript implementation.
//
// Written from the specification, not transliterated from the Python, so that
// differential testing against the reference means something. All arithmetic
// uses BigInt: the whole point of the integer-nanodegree design is that a
// browser and a server agree exactly, which Number (float64) would not.
//
// Kept deliberately as the differential oracle, not as architecture: the
// one leg sharing no arithmetic substrate with the F* extraction. Whether
// it survives long-term is an open question recorded in CLAUDE.md; the
// wasm core (from the proved C) does not replace what this checks.

// Keyed BLAKE2s comes from the audited community implementation rather than
// node's OpenSSL binding, which exposes only the unkeyed form. Still an
// implementation independent of everything in the tree.
import { blake2s } from "@noble/hashes/blake2.js";
import { argon2id } from "@noble/hashes/argon2.js";

const enc = new TextEncoder();
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const BANDS = JSON.parse(readFileSync(join(HERE, "bands.json"), "utf8"));
export const WORDLIST = readFileSync(
  join(HERE, "..", "wordlist", "english.txt"), "utf8").trim().split("\n");

const ROWS = BigInt(BANDS.rows);
const NBANDS = BANDS.bands;
const ROWS_PER_BAND = BigInt(BANDS.rows_per_band);
const COLS = BANDS.col_counts.map(BigInt);
const OFFSETS = BANDS.offsets.map(BigInt);
export const TOTAL_CELLS = BigInt(BANDS.total_cells);

const LAT_MIN = -90000000000n, LAT_SPAN = 180000000000n;
const LON_MIN = -180000000000n, LON_SPAN = 360000000000n;

const A = 262144n * 25n;         // 2^18 * 25
const B = 524288n * 25n;         // 2^19 * 25
const N = A * B;
const ROUNDS = 16;
/* The three protocol constants, here as in the core they check. Each is
   hashed into every address. This oracle stops agreeing with the core if
   either side changes one alone, which is exactly what it is for. */
const TWEAK = Buffer.from("tessarium-grid-3");

// ------------------------------------------------------------------- grid

const bucket = (v, vMin, span, k) => ((v - vMin) * k) / span;   // BigInt floor
const ceilDiv = (p, q) => (p + q - 1n) / q;
const edge = (i, vMin, span, k) => vMin + ceilDiv(i * span, k);

export function pointToCell(latNs, lonNs) {
  if (latNs < LAT_MIN || latNs > LAT_MIN + LAT_SPAN) throw new Error("lat out of range");
  if (lonNs < LON_MIN || lonNs > LON_MIN + LON_SPAN) throw new Error("lon out of range");
  if (lonNs === LON_MIN + LON_SPAN) lonNs = LON_MIN;

  let row = bucket(latNs, LAT_MIN, LAT_SPAN, ROWS);
  if (row === ROWS) row = ROWS - 1n;

  const band = Number(row / ROWS_PER_BAND);
  const cols = COLS[band];
  const col = bucket(lonNs, LON_MIN, LON_SPAN, cols);
  return OFFSETS[band] + (row - BigInt(band) * ROWS_PER_BAND) * cols + col;
}

function bandOfIndex(index) {
  let lo = 0, hi = NBANDS - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (OFFSETS[mid] <= index) lo = mid; else hi = mid - 1;
  }
  return lo;
}

export function cellToPoint(index) {
  if (index < 0n || index >= TOTAL_CELLS) throw new Error("cell out of range");
  const band = bandOfIndex(index);
  const cols = COLS[band];
  const rem = index - OFFSETS[band];
  const row = BigInt(band) * ROWS_PER_BAND + rem / cols;
  const col = rem % cols;
  return [
    LAT_MIN + ((2n * row + 1n) * LAT_SPAN) / (2n * ROWS),
    LON_MIN + ((2n * col + 1n) * LON_SPAN) / (2n * cols),
  ];
}

export function cellBounds(index) {
  const band = bandOfIndex(index);
  const cols = COLS[band];
  const rem = index - OFFSETS[band];
  const row = BigInt(band) * ROWS_PER_BAND + rem / cols;
  const col = rem % cols;
  return [edge(row, LAT_MIN, LAT_SPAN, ROWS), edge(row + 1n, LAT_MIN, LAT_SPAN, ROWS),
          edge(col, LON_MIN, LON_SPAN, cols), edge(col + 1n, LON_MIN, LON_SPAN, cols)];
}

// ---------------------------------------------------------------- feistel

function be(value, bytes) {
  const b = Buffer.alloc(bytes);
  let v = value;
  for (let i = bytes - 1; i >= 0; i--) { b[i] = Number(v & 0xFFn); v >>= 8n; }
  return b;
}

function roundFunc(key, tweak, i, x, m) {
  const len = Buffer.alloc(2);
  len.writeUInt16BE(tweak.length);
  const msg = Buffer.concat([Buffer.from("tessarium/v3/fe1"), len, tweak,
                             Buffer.from([i]), be(x, 8)]);
  const d = Buffer.from(blake2s(msg, { key }));
  // v2 reads the first 16 digest bytes little-endian -- BLAKE2s's own order.
  return BigInt("0x" + d.subarray(0, 16).reverse().toString("hex")) % m;
}

export function encrypt(key, tweak, x) {
  let L = x / B, R = x % B;
  for (let i = 1; i <= ROUNDS; i++) {
    const m = (i % 2) ? A : B;
    const t = (L + roundFunc(key, tweak, i, R, m)) % m;
    L = R; R = t;
  }
  return L * B + R;
}

export function decrypt(key, tweak, y) {
  let L = y / B, R = y % B;
  for (let i = ROUNDS; i >= 1; i--) {
    const m = (i % 2) ? A : B;
    const t = (R - roundFunc(key, tweak, i, L, m) % m + m) % m;
    R = L; L = t;
  }
  return L * B + R;
}

// ------------------------------------------------------------ key + codec

export function deriveKey(mnemonic, passphrase = "") {
  const norm = mnemonic.normalize("NFKD").trim().toLowerCase();
  const words = norm.split(/\s+/);
  if (words.length !== 24) throw new Error("24-word mnemonic required");
  // Single-stage Argon2id since kdf-3 (t=3, m=64 MiB, p=1 -- the same three
  // numbers the OCaml stubs and the wasm glue bake; a drift between the four
  // spellings changes every key and the differential rings). The passphrase
  // rides in the salt behind the version prefix, NFKD-normalised, verbatim
  // otherwise.
  return Buffer.from(argon2id(
    enc.encode(words.join(" ").normalize("NFKD")),
    enc.encode("tessarium-kdf-4" + passphrase.normalize("NFKD")),
    { t: 3, m: 65536, p: 1, dkLen: 32 },
  ));
}

export function indexToAddress(y) {
  const num = y % 10000n; let r = y / 10000n;
  const w3 = r % 2048n; r = r / 2048n;
  const w2 = r % 2048n; const w1 = r / 2048n;
  return [WORDLIST[Number(w1)], WORDLIST[Number(w2)], WORDLIST[Number(w3)],
          String(num).padStart(4, "0")].join(".");
}

export function addressToIndex(address) {
  const parts = address.trim().toLowerCase().replace(/[,\/ \-_]/g, ".")
                       .split(".").filter(Boolean);
  if (parts.length !== 4) throw new Error("expected 3 words and a number");
  const num = parts[3];
  if (!/^\d{4}$/.test(num)) throw new Error("not a four-digit number");
  const idx = parts.slice(0, 3).map((w) => {
    let i = WORDLIST.indexOf(w);
    // An abbreviation is a PREFIX of the word. Matching on the input's first
    // four letters instead would resolve "cannot" to "cannon" -- a different
    // square, returned as if it were the one asked for. Deliberately the same
    // rule as resolve_word in ocaml/lib/tessarium.ml, since this oracle only
    // disagrees usefully when it is not copying the core's mistakes.
    if (i < 0 && w.length >= 4) {
      const hits = WORDLIST.map((x, j) => (x.startsWith(w) ? j : -1))
                           .filter((j) => j >= 0);
      if (hits.length === 1) i = hits[0];
    }
    if (i < 0) throw new Error(`'${w}' is not a BIP-39 word`);
    return BigInt(i);
  });
  return ((idx[0] * 2048n + idx[1]) * 2048n + idx[2]) * 10000n + BigInt(num);
}

export function encode(key, latNs, lonNs) {
  return indexToAddress(encrypt(key, TWEAK, pointToCell(latNs, lonNs)));
}

export function decode(key, address) {
  const cell = decrypt(key, TWEAK, addressToIndex(address));
  if (cell >= TOTAL_CELLS) throw new Error("address does not resolve to a location");
  return cellToPoint(cell);
}
