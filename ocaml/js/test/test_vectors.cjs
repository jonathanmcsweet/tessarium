// Differential test of the js_of_ocaml artifact against the committed
// vectors. The browser and the server must agree exactly, which is the whole
// reason the grid is integer-only.

const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");

// Paths come from argv so dune can run this inside its sandbox, where nothing
// sits where the source tree says it does.
const bundlePath = resolve(
  process.argv[2] || "../../../_build/default/ocaml/js/tessarium_js.bc.js");
const vectorsPath = resolve(process.argv[3] || "../../../vectors/vectors.json");

// js_of_ocaml picks its export target at load: `module.exports` under
// CommonJS, `globalThis` otherwise. Under a classic Web Worker there is no
// `module`, so the browser takes the second branch and Node the first.
const M = require(bundlePath);
const C = M.tessarium || globalThis.tessarium;
if (!C) { console.error("export missing"); process.exit(1); }

const v = JSON.parse(readFileSync(vectorsPath, "utf8"));
let checks = 0, fails = 0;
const check = (name, ok) => { checks++; if (!ok) { fails++; console.log("  FAIL " + name); } };

check("gridVersion", C.gridVersion === v.grid_version);
check("totalCells", C.totalCells === String(v.total_cells));

/* Keys come from the vectors rather than from this bundle. The browser
   derives with WebCrypto now -- our PBKDF2 compiled to JavaScript would need
   24 seconds for the hardened count -- so there is no deriveKey here to test.
   What the bundle still owes us is that it ENCODES identically, which is what
   the loop below checks against keys the OCaml produced. */
const keys = {};
for (const kv of v.key_derivation) keys[kv.name] = kv.key;
check("no key derivation is exposed by the bundle", C.deriveKey === undefined);
check("the derivation parameters are exposed for the worker",
  C.derivationVersion === v.derivation_version && C.hardeningIterations > 0);
for (const a of v.addresses) {
  const got = C.encodeNs(keys[a.mnemonic], String(a.lat_ns), String(a.lon_ns));
  check(`encodeNs(${a.lat_ns},${a.lon_ns}) got ${got} want ${a.address}`, got === a.address);
  const d = C.decodeNs(keys[a.mnemonic], a.address);
  check("decodeNs(" + a.address + ")", d !== null);
}
/* Addresses that name no location. Generated into the vectors rather than
   written here: which word combinations are invalid is decided by the
   permutation and changes completely with the grid version, so a hand-picked
   example goes stale silently. */
for (const a of v.invalid_addresses) {
  check(`${a} names no location`, C.decodeNs(keys[v.addresses[0].mnemonic], a) === null);
}

const b = C.cellBoundsDeg(51.5074, -0.1278);
check("cellBoundsDeg ordered", b.latLo < b.latHi && b.lonLo < b.lonHi);

// The grid overlay. This walk happens in the core rather than in JavaScript,
// so what is checked here is that it tiles: no gaps, no overlaps, and every
// cell reporting itself as the cell its own centre belongs to. A gap or an
// overlap is invisible on screen at these scales and would show up only as an
// address that disagrees with the square the user clicked.
{
  const lat0 = 51.5074, lon0 = -0.1278;
  const d = 0.0004; // roughly 45 m, a few dozen cells across
  const g = C.gridForBounds(lat0, lon0, lat0 + d, lon0 + d, 20000);
  check("gridForBounds returns cells", g.count > 0);
  check("gridForBounds not truncated at this size", g.truncated === false);
  check("flat array length matches count", g.cells.length === g.count * 4);

  const rows = new Map();
  let ordered = true, centred = true;
  for (let i = 0; i < g.count; i++) {
    const [latLo, latHi, lonLo, lonHi] = g.cells.subarray(i * 4, i * 4 + 4);
    if (!(latLo < latHi && lonLo < lonHi)) ordered = false;
    // A cell's own centre must resolve back to that same cell.
    const c = C.cellBoundsDeg((latLo + latHi) / 2, (lonLo + lonHi) / 2);
    if (c.latLo !== latLo || c.lonLo !== lonLo) centred = false;
    const key = latLo.toFixed(9);
    if (!rows.has(key)) rows.set(key, []);
    rows.get(key).push([lonLo, lonHi]);
  }
  check("every cell has positive extent", ordered);
  check("every cell contains its own centre", centred);

  // Within a row, one cell's upper edge is the next one's lower edge exactly.
  // Half-open at the high edge is what makes that identity hold.
  let contiguous = true;
  for (const spans of rows.values()) {
    spans.sort((p, q) => p[0] - q[0]);
    for (let i = 1; i < spans.length; i++) {
      if (spans[i][0] !== spans[i - 1][1]) contiguous = false;
    }
  }
  check("columns are contiguous within a row", contiguous);

  // Rows stack the same way.
  const edges = [...rows.keys()].map(Number).sort((a, b) => a - b);
  let stacked = true;
  const rowTops = new Map();
  for (let i = 0; i < g.count; i++) {
    const latLo = g.cells[i * 4], latHi = g.cells[i * 4 + 1];
    rowTops.set(latLo.toFixed(9), latHi);
  }
  for (let i = 1; i < edges.length; i++) {
    if (rowTops.get(edges[i - 1].toFixed(9)) !== edges[i]) stacked = false;
  }
  check("rows are contiguous", stacked);

  // Asking for more than the limit must say so rather than quietly return a
  // partial grid the caller then renders as if it were complete.
  const small = C.gridForBounds(lat0, lon0, lat0 + d, lon0 + d, 10);
  check("limit is honoured", small.count === 10);
  check("truncation is reported", small.truncated === true);
}

/* Named, so tools/check-suites.sh can tell that this suite ran without
   matching on the number of checks in it -- which it used to do, and which
   made adding a test look like a suite that had stopped running. */
console.log(`\njs_of_ocaml bundle: ${checks} checks, ${fails} failures`);
process.exit(fails ? 1 : 0);
