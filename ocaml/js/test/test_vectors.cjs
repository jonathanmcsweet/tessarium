// Differential test of the js_of_ocaml artifact against the committed
// vectors. The browser and the server must agree exactly, which is the whole
// reason the grid is integer-only.

const { readFileSync } = require("node:fs");
const M = require("../../../_build/default/ocaml/js/tessarium_js.bc.js");
const C = M.tessarium || globalThis.tessarium;
if (!C) { console.error("export missing"); process.exit(1); }

const v = JSON.parse(readFileSync("../../../vectors/vectors.json", "utf8"));
let checks = 0, fails = 0;
const check = (name, ok) => { checks++; if (!ok) { fails++; console.log("  FAIL " + name); } };

check("gridVersion", C.gridVersion === v.grid_version);
check("totalCells", C.totalCells === String(v.total_cells));

const keys = {};
for (const kv of v.key_derivation) {
  const r = C.deriveKey(kv.mnemonic, "");
  if (r.error) { check("derive " + kv.name + ": " + r.error, false); continue; }
  keys[kv.name] = r.key;
  check("deriveKey[" + kv.name + "]", r.key === kv.key);
}
for (const a of v.addresses) {
  const got = C.encodeNs(keys[a.mnemonic], String(a.lat_ns), String(a.lon_ns));
  check(`encodeNs(${a.lat_ns},${a.lon_ns}) got ${got} want ${a.address}`, got === a.address);
  const d = C.decodeNs(keys[a.mnemonic], a.address);
  check("decodeNs(" + a.address + ")", d !== null);
}
const b = C.cellBoundsDeg(51.5074, -0.1278);
check("cellBoundsDeg ordered", b.latLo < b.latHi && b.lonLo < b.lonHi);
console.log(`\n${checks} checks, ${fails} failures`);
process.exit(fails ? 1 : 0);
