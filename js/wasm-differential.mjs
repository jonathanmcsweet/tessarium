// The wasm core against the extracted core's corpus.
//
// wasm/core.wasm is the same vendored C the server's HTTP API answers from
// over the FFI, compiled to wasm32 -- and since the browser half of the
// switch landed it IS the browser's answer path, not a wall beside it. What
// this driver checks is therefore the arithmetic the UI actually runs. It
// replays the differential corpus (computed by the extracted core with
// digestif) through it: encode must reproduce every address, decode must
// land exactly on every centre, bounds must contain both. The key comes
// from the corpus header -- the wasm core's contract starts AT the key;
// the independent JS implementation keeps deriving it from the mnemonic.
//
//   node js/wasm-differential.mjs <corpus|-> <core.wasm> <bands.json> <english.txt>
//
// The band table is fed as prefix sums of the INDEPENDENT
// implementation's bands.json: if that table ever drifted from the
// core's, seal_cum or the very first point would ring.

import { readFileSync } from "node:fs";

const [corpusPath, wasmPath, bandsPath, wordsPath] = process.argv.slice(2);
if (!wordsPath) {
  console.error(
    "usage: node js/wasm-differential.mjs <corpus|-> <core.wasm> <bands.json> <english.txt>",
  );
  process.exit(2);
}

const LAT_MIN = -90000000000n;
const LON_MIN = -180000000000n;

const words = readFileSync(wordsPath, "utf8").trim().split("\n");
const bands = JSON.parse(readFileSync(bandsPath, "utf8"));

/* Exactly ONE import is expected: wasi random_get, which the prebuilt
   libc init (crt) calls once for its stack guard. Allow-listed by name
   -- anything else appearing rings instead of being quietly stubbed --
   and given deterministic zeros: this is a differential wall, and the
   guard value cannot affect any computed answer (a smashed stack traps
   either way). _initialize runs first, per the wasi reactor ABI. */
const module_ = await WebAssembly.compile(readFileSync(wasmPath));
const imports = WebAssembly.Module.imports(module_);
const unexpected = imports.filter(
  (i) => !(i.module === "wasi_snapshot_preview1" && i.name === "random_get"),
);
if (unexpected.length > 0) {
  console.error(
    "core.wasm grew imports: " + unexpected.map((i) => i.name).join(", "),
  );
  process.exit(1);
}
const instance = await WebAssembly.instantiate(module_, {
  wasi_snapshot_preview1: {
    random_get: (ptr, len) => {
      new Uint8Array(instance.exports.memory.buffer, ptr, len).fill(0);
      return 0;
    },
  },
});
const core = instance.exports;
core._initialize();

/* cum is the prefix-sum view of col_counts; seal_cum re-checks the whole
   shape (base, monotonicity, width bound, grand total) before anything
   runs. */
let acc = 0n;
if (!core.set_cum(0, 0n)) throw new Error("set_cum refused index 0");
bands.col_counts.forEach((c, i) => {
  acc += BigInt(c);
  if (!core.set_cum(i + 1, acc)) throw new Error(`set_cum refused ${i + 1}`);
});
if (!core.seal_cum()) {
  console.error("seal_cum rejected the band table");
  process.exit(1);
}
const out = () => new BigUint64Array(core.memory.buffer, core.out_ptr(), 4);

let keyWords = null;
let checked = 0;
let rejected = 0;
const failures = [];
const MAX_REPORTED = 10;
const fail = (s) => failures.push(failures.length < MAX_REPORTED ? s : null);

const lines = readFileSync(
  corpusPath === "-" ? 0 : corpusPath,
  "utf8",
).split("\n");
for (const line of lines) {
  if (line === "" || line.startsWith("#")) {
    const m = /^# key: ([0-9a-f]{64})$/.exec(line);
    if (m)
      // BLAKE2s's own byte order: eight LITTLE-endian words of the raw key.
      keyWords = Array.from({ length: 8 }, (_, i) => {
        const w = m[1].slice(i * 8, i * 8 + 8);
        return BigInt(
          "0x" + w.slice(6, 8) + w.slice(4, 6) + w.slice(2, 4) + w.slice(0, 2),
        );
      });
    continue;
  }
  if (!keyWords) throw new Error("corpus has no # key: header");
  const [latS, lonS, , clatS, clonS, address] = line.split(" ");
  const dlat = BigInt(latS) - LAT_MIN;
  const dlon = BigInt(lonS) - LON_MIN;

  if (!core.encode(...keyWords, dlat, dlon)) {
    fail(`encode refused ${latS},${lonS}`);
    continue;
  }
  const [w1, w2, w3, n] = out();
  const got = `${words[Number(w1)]}.${words[Number(w2)]}.${
    words[Number(w3)]
  }.${String(n).padStart(4, "0")}`;
  if (got !== address) fail(`encode ${latS},${lonS}: got ${got}, want ${address}`);

  const flag = core.decode(...keyWords, w1, w2, w3, n);
  if (flag !== 1) fail(`decode ${address}: flag ${flag}`);
  else {
    const [rlat, rlon] = out();
    if (rlat + LAT_MIN !== BigInt(clatS) || rlon + LON_MIN !== BigInt(clonS))
      fail(`decode ${address}: not the centre`);
  }

  if (!core.bounds(dlat, dlon)) fail(`bounds refused ${latS},${lonS}`);
  else {
    const [laLo, laHi, loLo, loHi] = out();
    /* The corpus centre is canonical, so it sits inside its cell for
       every point; the raw point does too, PER AXIS, except exactly at
       that axis's spec edge (+90 clamps into the last row, +180 folds
       onto -180) -- a +90 point still has its longitude contained. */
    const cLat = BigInt(clatS) - LAT_MIN;
    const cLon = BigInt(clonS) - LON_MIN;
    if (!(laLo <= cLat && cLat < laHi && loLo <= cLon && cLon < loHi))
      fail(`bounds at ${latS},${lonS} exclude the centre`);
    if (dlat < 180000000000n && !(laLo <= dlat && dlat < laHi))
      fail(`bounds at ${latS},${lonS} exclude the latitude`);
    if (dlon < 360000000000n && !(loLo <= dlon && dlon < loHi))
      fail(`bounds at ${latS},${lonS} exclude the longitude`);
  }

  /* A neighbouring number under the same words: no oracle for the
     answer, but the rejected arm must execute and return cleanly --
     about a third of these do reject. */
  const t = core.decode(...keyWords, w1, w2, w3, (n + 1n) % 10000n);
  if (t === 0) rejected++;
  else if (t !== 1) fail(`tweaked decode returned ${t}`);

  checked++;
}

/* checked > 100: the rejection rate is ~35%, so any real corpus
   exercises the arm; the guard only spares tiny hand runs, where zero
   rejections is plausible rather than diagnostic. */
if (rejected === 0 && checked > 100)
  fail("no tweaked address was rejected: the flag=0 arm never ran");

for (const f of failures.slice(0, MAX_REPORTED)) if (f) console.log("  FAIL " + f);
if (failures.length > MAX_REPORTED)
  console.log(`  ... and ${failures.length - MAX_REPORTED} more`);

console.log(
  `wasm core: ${checked} points checked, 0 disagreements expected, ${failures.length} found (${rejected} tweaked rejections exercised)`,
);
process.exit(failures.length === 0 ? 0 : 1);
