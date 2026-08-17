// Check a corpus emitted by the extracted core against this independently
// written implementation.
//
// The point is the independence. The F* is proved, but the OCaml that comes
// out of it is produced by a trusted-not-verified pipeline, and nothing in the
// repository proves the two agree. This implementation was written separately
// from a reading of the design, so where it disagrees, something is wrong in
// one of them — and that is a signal no second extraction target could give.
//
//   node js/differential.mjs corpus.txt
//
// The corpus comes from `ocaml/tools/differential.exe` and is weighted towards
// band seams, which is where the grid is subtlest and where uniformly random
// points essentially never land.

import { readFileSync } from "node:fs";
import * as w from "./tessarium.mjs";

/* "-" reads stdin, which is how dune runs it: the corpus is piped straight
   from the generator and never touches disk, so the rule has no target and
   therefore actually re-runs rather than being cached as a build artifact. */
const path = process.argv[2];
if (!path) {
  console.error("usage: node js/differential.mjs <corpus|->");
  process.exit(2);
}

const MNEMONIC =
  "abandon abandon abandon abandon abandon abandon abandon abandon abandon " +
  "abandon abandon abandon abandon abandon abandon abandon abandon abandon " +
  "abandon abandon abandon abandon abandon art";

const key = w.deriveKey(MNEMONIC);

let checked = 0;
let seams = 0;
const failures = [];
/* Bounded: a systematic disagreement would otherwise print a million lines and
   bury the first one, which is the only one worth reading. */
const MAX_REPORTED = 10;

const lines = readFileSync(path === "-" ? 0 : path, "utf8").split("\n");
for (const line of lines) {
  if (line === "" || line.startsWith("#")) {
    const m = /(\d+) at band seams/.exec(line);
    if (m) seams = Number(m[1]);
    continue;
  }
  const [latS, lonS, cellS, clatS, clonS, address] = line.split(" ");
  const lat = BigInt(latS);
  const lon = BigInt(lonS);

  const cell = w.pointToCell(lat, lon);
  if (cell !== BigInt(cellS)) {
    if (failures.length < MAX_REPORTED)
      failures.push(`cell ${latS},${lonS}: got ${cell}, want ${cellS}`);
    else failures.push(null);
  }

  const [clat, clon] = w.cellToPoint(cell);
  if (clat !== BigInt(clatS) || clon !== BigInt(clonS)) {
    if (failures.length < MAX_REPORTED)
      failures.push(
        `centre of ${cellS}: got ${clat},${clon}, want ${clatS},${clonS}`,
      );
    else failures.push(null);
  }

  const got = w.encode(key, lat, lon);
  if (got !== address) {
    if (failures.length < MAX_REPORTED)
      failures.push(`encode ${latS},${lonS}: got ${got}, want ${address}`);
    else failures.push(null);
  }

  /* And back. The address must resolve to a point in the same square, which is
     the property a user would state. */
  const back = w.decode(key, address);
  if (back === null) {
    if (failures.length < MAX_REPORTED)
      failures.push(`decode ${address}: resolved to nothing`);
    else failures.push(null);
  } else if (w.pointToCell(back[0], back[1]) !== cell) {
    if (failures.length < MAX_REPORTED)
      failures.push(`decode ${address}: landed in a different square`);
    else failures.push(null);
  }

  checked++;
}

for (const f of failures.slice(0, MAX_REPORTED)) if (f) console.log("  FAIL " + f);
if (failures.length > MAX_REPORTED)
  console.log(`  ... and ${failures.length - MAX_REPORTED} more`);

console.log(
  `${checked} points checked (${seams} straddling band seams), ` +
    `${failures.length} disagreements`,
);
process.exit(failures.length ? 1 : 0);
