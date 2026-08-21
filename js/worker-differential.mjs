// The real browser worker, driven in node, against the extracted core.
//
// Every other wall in this project checks a component. This one checks the
// thing the user actually runs: ui/public/core.worker.js, unmodified, loaded
// into a sandbox that gives it the four globals a Worker would (`self`,
// `importScripts`, `fetch`, `crypto`) and nothing else. It then drives the
// same message protocol the main thread does.
//
// It exists because of a specific hole. When the browser switched from the
// js_of_ocaml core to wasm/core.wasm, NOTHING in the repo failed if the
// switch were silently reverted -- the two cores agree, which is precisely
// why no test comparing answers can tell which one produced them. The server
// half needed a purpose-built fingerprint for the same reason
// (ocaml/server/test/test_server.ml). This is the browser's, and it is
// stronger than a fingerprint: the sandbox owns `fetch`, so "the worker
// loaded the wasm core" is observed rather than inferred, and every answer
// below is then held to the extraction it was transcribed from.
//
// What it pins, all of which drifted or broke at least once:
//
//   - the cell walk. The worker transcribes Tessarium.cells_in_bounds into
//     BigInt JavaScript. A first version compared `limit` against the flat
//     array's length rather than a cell count and drew a quarter of the grid.
//   - the degree boundary. The worker rounds degrees to nanodegrees itself
//     now; Math.round breaks ties toward +Infinity where OCaml's Float.round
//     breaks them away from zero, which moves points on negative half-units
//     into a different cell.
//   - truncation. Both walks must mean the same thing by it: at least one
//     overlapping cell was not returned.
//   - the whole chain, once: unlock with a committed vector phrase and check
//     the vector's own addresses come back. That runs argon2.wasm and
//     core.wasm end to end, through the same code the browser runs.
//
// Usage: node worker-differential.mjs <worker.js> <bundle.js> <core.wasm>
//        <argon2.wasm> <vectors.json>

import { readFileSync } from "node:fs";
import { createContext, runInContext } from "node:vm";
import { webcrypto } from "node:crypto";

const [workerPath, bundlePath, corePath, argonPath, vectorsPath] =
  process.argv.slice(2);

let checks = 0, failures = 0;
const check = (name, ok) => {
  checks += 1;
  if (!ok) {
    failures += 1;
    console.log(`  FAIL  ${name}`);
  }
};

// ---------------------------------------------------------------- sandbox

/* What the worker is allowed to see. A Worker global scope is not a browser
   window: no DOM, no document, no localStorage. Keeping this list short is
   itself a check -- if the worker ever starts needing something new, this
   file stops running and someone has to decide whether it should. */
const wasmFiles = { "/core.wasm": corePath, "/argon2.wasm": argonPath };
const fetched = [];

const sandbox = {
  console,
  WebAssembly,
  Response,
  BigInt,
  Uint8Array,
  Float64Array,
  BigUint64Array,
  Array,
  Object,
  Error,
  TextEncoder,
  TextDecoder,
  Math,
  JSON,
  Number,
  String,
  Promise,
  crypto: webcrypto,
  setTimeout,
  clearTimeout,
  /* A Worker served from HTTPS or from loopback has this; the worker refuses
     to derive a key without it, as policy rather than as a technical need.
     Set here because the browser this stands in for would set it, not to get
     around the guard -- `make run` and the desktop app are both loopback. */
  isSecureContext: true,
};
sandbox.self = sandbox;
sandbox.globalThis = sandbox;
createContext(sandbox);

sandbox.importScripts = (p) => {
  if (p !== "/tessarium.js") throw new Error(`unexpected importScripts ${p}`);
  runInContext(readFileSync(bundlePath, "utf8"), sandbox, { filename: p });
};

/* The observation the whole file turns on. A worker that answers from
   js_of_ocaml never asks for /core.wasm. */
sandbox.fetch = async (p) => {
  fetched.push(p);
  const file = wasmFiles[p];
  if (!file) throw new Error(`unexpected fetch ${p}`);
  return new Response(readFileSync(file), {
    headers: { "content-type": "application/wasm" },
  });
};

const pending = new Map();
let nextId = 0;
sandbox.postMessage = (msg) => {
  const slot = pending.get(msg.id);
  pending.delete(msg.id);
  if (msg.error !== undefined) slot.reject(new Error(msg.error));
  else slot.resolve(msg.result);
};

runInContext(readFileSync(workerPath, "utf8"), sandbox, {
  filename: "core.worker.js",
});

const send = (op, payload) => {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    sandbox.onmessage({ data: { id, op, payload } });
  });
};

const C = sandbox.tessarium;

// ------------------------------------------------------- which core answers

check(
  "the worker asked for no wasm module before it was used",
  fetched.length === 0,
);

// ------------------------------------------------------------------ unlock

const vectors = JSON.parse(readFileSync(vectorsPath, "utf8"));
const vector = vectors.addresses[0];
const seed = vectors.key_derivation.find((k) => k.name === vector.mnemonic);
const keyHex = seed.key;

const unlocked = await send("unlock", {
  mnemonic: seed.mnemonic,
  passphrase: seed.passphrase ?? "",
});
check("the worker unlocks with a committed vector phrase", unlocked.ok === true);

/* The end-to-end claim, in one line: the address the vectors say this point
   has is the address the browser produces. Nothing but agreement across the
   KDF, the wordlist codec and the wasm core makes that come out right. */
{
  const lat = Number(vector.lat_ns) / 1e9, lon = Number(vector.lon_ns) / 1e9;
  const got = await send("encode", { lat, lon });
  check(
    `the worker reproduces the vector address (${got.address} = ${vector.address})`,
    got.address === vector.address,
  );
}

check(
  "the worker loaded BOTH wasm modules, and answered from the map core",
  fetched.includes("/argon2.wasm") && fetched.includes("/core.wasm"),
);

/* The one that catches a silent revert. If encode came from the js_of_ocaml
   bundle, /core.wasm would never have been requested at all. */
check(
  "encode reached wasm/core.wasm rather than the js_of_ocaml core",
  fetched.filter((p) => p === "/core.wasm").length === 1,
);

// -------------------------------------------------------- encode and decode

/* A deterministic spread rather than a random one: this runs on every build,
   and a wall that tests something different each time cannot be bisected. */
const points = [];
for (let i = 0; i < 400; i++) {
  const t = i / 400;
  points.push([
    -85 + 170 * ((i * 37) % 400) / 400,
    -180 + 360 * t,
  ]);
}
// Signs, zero, and the poles and antimeridian the map can actually reach.
points.push([0, 0], [-0.000000001, -0.000000001], [85.05, 179.999999999],
  [-85.05, -180], [51.5074, -0.1278], [-33.8688, 151.2093]);

let encodeMismatch = null, decodeMismatch = null;
for (const [lat, lon] of points) {
  const mine = (await send("encode", { lat, lon })).address;
  const theirs = C.encodeDeg(keyHex, lat, lon);
  if (mine !== theirs && encodeMismatch === null) {
    encodeMismatch = `${lat},${lon}: wasm ${mine} vs extracted ${theirs}`;
  }
  const back = await send("decode", { address: mine });
  const ref = C.decodeDeg(keyHex, theirs);
  if (
    decodeMismatch === null
    && (ref === null || back.lat !== ref.lat || back.lon !== ref.lon)
  ) {
    decodeMismatch = `${mine}: wasm ${back.lat},${back.lon} vs extracted ${
      ref === null ? "rejected" : `${ref.lat},${ref.lon}`
    }`;
  }
}
check(
  `encode agrees with the extracted core over ${points.length} points`
    + (encodeMismatch ? ` (${encodeMismatch})` : ""),
  encodeMismatch === null,
);
check(
  `decode agrees with the extracted core over ${points.length} addresses`
    + (decodeMismatch ? ` (${decodeMismatch})` : ""),
  decodeMismatch === null,
);

/* Rejections must agree too, and they are the majority of the address space.
   Taken from the vectors, where which combinations are invalid is decided by
   the permutation and changes completely with the grid version. */
let rejectMismatch = null;
for (const addr of vectors.invalid_addresses) {
  let refused = false;
  try {
    await send("decode", { address: addr });
  } catch {
    refused = true;
  }
  const ref = C.decodeDeg(keyHex, addr);
  if (!(refused && ref === null) && rejectMismatch === null) {
    rejectMismatch = addr;
  }
}
check(
  `both cores refuse the same ${vectors.invalid_addresses.length} addresses`
    + (rejectMismatch ? ` (${rejectMismatch})` : ""),
  rejectMismatch === null,
);

// ------------------------------------------------------------- the cell walk

/* The corners, named. Each one broke or diverged at some point: the limit
   scaling, the tie-break in the degree conversion, truncation inside the last
   row, and the degenerate row at the pole where a cell's upper edge cannot
   advance. `gridForBounds` is the OCaml walk (Tessarium.cells_in_bounds)
   through js_of_ocaml; `grid` is the worker's BigInt transcription over the
   wasm core's proved `bounds`. They must agree in all three fields. */
const d = 0.0004; // roughly 45 m: a few dozen cells across
const viewports = [
  ["London, generous limit", 51.5074, -0.1278, 51.5074 + d, -0.1278 + d, 20000],
  ["London, limit 10", 51.5074, -0.1278, 51.5074 + d, -0.1278 + d, 10],
  ["London, limit 1", 51.5074, -0.1278, 51.5074 + d, -0.1278 + d, 1],
  ["London, limit 0", 51.5074, -0.1278, 51.5074 + d, -0.1278 + d, 0],
  ["a realistic viewport", 51.5, -0.13, 51.5 + 0.002, -0.13 + 0.004, 12000],
  ["truncating a realistic viewport", 51.5, -0.13, 51.5 + 0.002, -0.13 + 0.004, 3000],
  ["southern hemisphere", -33.8688, 151.2093, -33.8688 + d, 151.2093 + d, 20000],
  ["straddling the equator", -0.0002, -0.0002, 0.0002, 0.0002, 20000],
  ["straddling the antimeridian", -0.0002, 179.9998, 0.0002, 180, 20000],
  ["zero area", 51.5074, -0.1278, 51.5074, -0.1278, 20000],
  ["inverted latitude", 51.6, -0.1278, 51.5, -0.1278 + d, 20000],
  ["inverted longitude", 51.5074, -0.1, 51.5074 + d, -0.2, 20000],
  ["one row tall, wide, tight limit", 51.5074, -0.1278, 51.5074, -0.1278 + d, 3],
  ["at the north pole", 89.9999, -0.1278, 90, -0.1278 + d, 20000],
  ["past the north pole", 89.9999, -0.1278, 95, -0.1278 + d, 20000],
  ["at the south pole", -90, -0.1278, -89.9999, -0.1278 + d, 20000],
  ["the whole world", -90, -180, 90, 180, 500],
  ["larger than the world", -100, -200, 100, 200, 500],
  ["negative half-unit corner", -51.5, -0.0009742885, -51.5 + d / 10, -0.0009, 20000],
];

for (const [name, latLo, lonLo, latHi, lonHi, limit] of viewports) {
  const mine = await send("grid", { latLo, lonLo, latHi, lonHi, limit });
  const theirs = C.gridForBounds(latLo, lonLo, latHi, lonHi, limit);
  check(
    `${name}: cell count agrees (${mine.count} vs ${theirs.count})`,
    mine.count === theirs.count,
  );
  check(
    `${name}: truncation agrees (${mine.truncated} vs ${theirs.truncated})`,
    mine.truncated === theirs.truncated,
  );
  check(
    `${name}: the flat array is four numbers per cell`,
    mine.cells.length === mine.count * 4,
  );
  let cellMismatch = null;
  for (let i = 0; i < Math.min(mine.cells.length, theirs.cells.length); i++) {
    if (mine.cells[i] !== theirs.cells[i]) {
      cellMismatch = `slot ${i}: ${mine.cells[i]} vs ${theirs.cells[i]}`;
      break;
    }
  }
  check(
    `${name}: every corner agrees exactly`
      + (cellMismatch ? ` (${cellMismatch})` : ""),
    cellMismatch === null,
  );
  check(
    `${name}: the limit is a cell count, not an array length`,
    mine.count <= limit,
  );
}

// ------------------------------------------------------------------- locking

await send("lock", {});
let lockedRefusal = null;
try {
  await send("encode", { lat: 51.5074, lon: -0.1278 });
} catch (e) {
  lockedRefusal = e.message;
}
check(
  `a locked worker refuses to encode, in words (${lockedRefusal})`,
  lockedRefusal === "locked",
);

console.log(
  `\nworker differential: ${checks} checks, ${failures} failures`,
);
if (failures > 0) process.exit(1);
