// Differential test: the JS implementation must reproduce every committed vector.
import { readFileSync } from "node:fs";
import * as w from "./tessarium.mjs";

const V = JSON.parse(readFileSync(new URL("../vectors/vectors.json", import.meta.url)));
let pass = 0, fail = 0;
const check = (n, ok, d = "") => ok ? (pass++, 0) : (fail++, console.log(`  FAIL ${n} ${d}`));

check("total_cells", w.TOTAL_CELLS === BigInt(V.total_cells));

const keys = {};
for (const kd of V.key_derivation) {
  const k = w.deriveKey(kd.mnemonic, kd.passphrase ?? "");
  keys[kd.name] = k;
  check(`key ${kd.name}`, k.toString("hex") === kd.key, `${k.toString("hex").slice(0,16)} vs ${kd.key.slice(0,16)}`);
}

const fk = Buffer.from("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff", "hex");
for (const fv of V.feistel_vectors) {
  const y = w.encrypt(fk, Buffer.from("tessarium-grid-3"), BigInt(fv.x));
  check(`feistel ${fv.x}`, y === BigInt(fv.y), `${y} vs ${fv.y}`);
  check(`feistel inv ${fv.x}`, w.decrypt(fk, Buffer.from("tessarium-grid-3"), y) === BigInt(fv.x));
}

for (const g of V.grid_vectors) {
  const c = w.pointToCell(BigInt(g.lat_ns), BigInt(g.lon_ns));
  check(`cell ${g.lat_ns}`, c === BigInt(g.cell), `${c} vs ${g.cell}`);
  const [la, lo] = w.cellToPoint(c);
  check(`centre ${g.cell}`, la === BigInt(g.centre_lat_ns) && lo === BigInt(g.centre_lon_ns));
}

for (const a of V.addresses) {
  const got = w.encode(keys[a.mnemonic], BigInt(a.lat_ns), BigInt(a.lon_ns));
  check(`addr ${a.lat_ns}`, got === a.address, `${got} vs ${a.address}`);
  const [la, lo] = w.decode(keys[a.mnemonic], a.address);
  const c = w.pointToCell(BigInt(a.lat_ns), BigInt(a.lon_ns));
  check(`addr rt ${a.lat_ns}`, w.pointToCell(la, lo) === c);
}

console.log(`\n${pass} checks passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
