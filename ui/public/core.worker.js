/* The verified core, running off the main thread.

   This worker owns the derived key. Nothing else in the application ever holds
   it: the main thread sends coordinates and receives addresses, and the key
   itself never crosses back. That is a real boundary rather than a stylistic
   one -- the main thread has the DOM, and the DOM is where any injected script
   would be looking.

   It is also where the KDF belongs. Argon2id at 64 MiB is deliberately
   expensive, and running it on the main thread would freeze the map for the
   length of the derivation.

   A classic worker, not a module worker, so the js_of_ocaml artifact can be
   pulled in with importScripts. js_of_ocaml picks its export target at load
   time: `module.exports` when CommonJS is present, `globalThis` otherwise.
   There is no `module` here, so the core lands on `self.tessarium`. */

importScripts("/tessarium.js");

const core = self.tessarium;

/* The key lives here and only here. `lock` is not decoration: a user who
   walks away should be able to make the tab useless without closing it. */
let key = null;

/* Two kinds of failure, kept apart deliberately.

   A handler THROWS when the request could not be answered -- locked, malformed
   address, no such location. Those surface as a rejected promise on the main
   thread, so a caller that forgets to check cannot mistake one for an answer.

   A handler RETURNS `{ok: false, error}` when not-valid is itself the answer,
   which is only `validate` and `unlock`. A phrase failing its checksum is a
   result to display, not an exception to handle. */
class Refused extends Error {}

/* Key derivation runs on the Argon2id wasm module (argon2.wasm) -- the
   SAME vendored reference C the server links, zig-compiled, so the browser
   and the server run one implementation of the primitive. (The old
   WebCrypto-PBKDF2 split existed because pure-OCaml Argon2id cost 21 s in a
   browser and a wasm build was rejected as a second implementation; the
   C-core pipeline made the wasm THE implementation, and the objection with
   it. Measured here: ~150 ms.)

   The KDF's inputs are not built in this file: kdfInputs on the js_of_ocaml
   core builds password and salt -- validation, NFKD, version prefix -- so
   the normalisation rules have exactly one home. What keeps the whole chain
   honest is the committed vectors: the end-to-end test unlocks with a
   vector phrase and checks a known square yields the vector's address,
   which it cannot unless this derivation agrees with the server's byte for
   byte. js/argon2-differential.mjs additionally pins the wasm against an
   independent implementation on every `make test`. */
const hex = (bytes) =>
  Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

const bytesOfHex = (h) =>
  Uint8Array.from(
    { length: h.length / 2 },
    (_, i) => parseInt(h.slice(2 * i, 2 * i + 2), 16),
  );

/* Both wasm modules are built the same way and load the same way. Their
   single import is wasi random_get, wanted by the prebuilt libc's stack
   guard; deterministic zeros are fine for it, and anything MORE appearing
   in the import list is refused -- the same allow-list discipline as the
   differential walls, which is what makes "this module computes and does
   not reach anywhere" checkable rather than asserted. */
async function loadWasm(path) {
  const mod = await WebAssembly.compileStreaming(fetch(path));
  for (const imp of WebAssembly.Module.imports(mod)) {
    if (imp.module !== "wasi_snapshot_preview1" || imp.name !== "random_get") {
      throw new Refused(`unexpected wasm import ${imp.module}.${imp.name}`);
    }
  }
  const instance = await WebAssembly.instantiate(mod, {
    wasi_snapshot_preview1: { random_get: () => 0 },
  });
  instance.exports._initialize();
  return instance.exports;
}

/* The KDF. Instantiated once, on first unlock. */
let argon2 = null;
async function loadArgon2() {
  if (argon2) return argon2;
  argon2 = await loadWasm("/argon2.wasm");
  return argon2;
}

/* The map core: the same F* the server's HTTP API answers from, compiled to
   wasm instead of to native C. It arrives knowing no geography -- the band
   table crosses from the js_of_ocaml bundle, which holds the table the
   proofs were discharged against, and `seal_cum` re-checks its whole shape
   (base, monotonicity, step bound, grand total) before the module will
   answer anything. A table that fails that check leaves the core unusable
   rather than quietly wrong. */
let mapCore = null;
async function loadMapCore() {
  if (mapCore) return mapCore;
  const exports = await loadWasm("/core.wasm");
  /* A method on the bundle, not a property: js_of_ocaml exposes `val` as a
     field and `method` as a callable, and reading the callable hands
     seal_cum a function instead of a table. */
  const table = core.cumTable();
  for (let i = 0; i < table.length; i++) {
    if (!exports.set_cum(i, BigInt(table[i]))) {
      throw new Refused(`the band table was refused at entry ${i}`);
    }
  }
  if (!exports.seal_cum()) {
    throw new Refused("the band table failed the core's shape check");
  }
  mapCore = exports;
  return mapCore;
}

/* Integer nanodegrees, as the whole design requires: the only float here is
   the degree the UI speaks, converted once at this boundary. 1.8e11 is far
   below 2^53, so the multiply is exact and the rounding is the same one the
   OCaml boundary does. */
const LAT_MIN = -90000000000n;
const LON_MIN = -180000000000n;
const nsOfDeg = (d) => BigInt(Math.round(d * 1e9));
const degOfNs = (ns) => Number(ns) / 1e9;

/* The key as the eight little-endian words the core's ABI takes -- BLAKE2s's
   own byte order, the same packing the FFI stubs do natively. */
const keyWords = (hex) =>
  Array.from({ length: 8 }, (_, i) => {
    const w = hex.slice(i * 8, i * 8 + 8);
    return BigInt(
      "0x" + w.slice(6, 8) + w.slice(4, 6) + w.slice(2, 4) + w.slice(0, 2),
    );
  });

const outWords = (m, n) =>
  Array.from(
    new BigUint64Array(m.memory.buffer, m.out_ptr(), n),
  );

async function deriveKey(mnemonic, passphrase) {
  const inputs = core.kdfInputs(mnemonic, passphrase);
  if (inputs.error !== null) throw new Refused(inputs.error);
  const password = bytesOfHex(inputs.password);
  const salt = bytesOfHex(inputs.salt);
  /* The core already bounds both inputs (max_passphrase_bytes), so these
     can only trip on a drift between its limit and the glue's buffers --
     checked BEFORE anything is written, because the glue's own check runs
     after the write and cannot protect the memory around the buffers. */
  if (password.length > 1024 || salt.length > 1024) {
    throw new Refused("KDF input exceeds the wasm buffers");
  }
  const a = await loadArgon2();
  new Uint8Array(a.memory.buffer, a.password_ptr(), password.length)
    .set(password);
  new Uint8Array(a.memory.buffer, a.salt_ptr(), salt.length).set(salt);
  const rc = a.kdf(password.length, salt.length);
  if (rc !== 0) throw new Refused(`argon2 failed with code ${rc}`);
  return hex(new Uint8Array(a.memory.buffer, a.out_ptr(), 32));
}

const ops = {
  validate({ mnemonic }) {
    const error = core.validateMnemonic(mnemonic);
    return { ok: error === null, error };
  },

  /* A phrase the user did not invent.

     This is the highest-value security control in the application, and it is
     three lines long. A phrase a person composed is worth perhaps 40 bits of
     guessing effort; these 32 bytes are worth 256. The checksum rejects most
     hand-assembled phrases, but it is typo detection, not an entropy test --
     a low-entropy phrase that satisfies it is accepted like any other. The
     round count and the cost of key derivation only decide anything in the
     case where this step was skipped.

     `crypto.getRandomValues` is the platform CSPRNG. The core does the BIP-39
     encoding and nothing else: it never generates the bytes, which keeps the
     one decision that matters at this edge, in sight. */
  generate() {
    const entropy = new Uint8Array(core.entropyBytes);
    crypto.getRandomValues(entropy);
    const hex = Array.from(entropy, (b) => b.toString(16).padStart(2, "0"))
      .join("");
    return { mnemonic: core.mnemonicOfEntropy(hex) };
  },

  async unlock({ mnemonic, passphrase }) {
    const invalid = core.validateMnemonic(mnemonic);
    if (invalid) return { ok: false, error: invalid };
    /* The wasm KDF would happily run over plain HTTP -- unlike the old
       WebCrypto path, nothing technical stops it. The refusal is kept as
       POLICY: a seed-phrase form served over plain HTTP is a mistake, and
       saying so plainly beats deriving anyway. Loopback counts as secure,
       so the desktop app and `make run` are fine. */
    if (!self.isSecureContext) {
      return {
        ok: false,
        error: "This page is not in a secure context, so it will not "
          + "derive a key. Serve it over HTTPS or from localhost.",
      };
    }
    /* A refused derivation -- over-long passphrase, wasm trouble -- is a
       result to display like a failed checksum, not a rejected promise. */
    try {
      key = await deriveKey(mnemonic, passphrase ?? "");
    } catch (e) {
      if (e instanceof Refused) return { ok: false, error: e.message };
      throw e;
    }
    return { ok: true, error: null };
  },

  lock() {
    key = null;
    return { ok: true };
  },

  status() {
    return {
      unlocked: key !== null,
      gridVersion: core.gridVersion,
      derivationVersion: core.derivationVersion,
      totalCells: core.totalCells,
    };
  },

  /* Arithmetic from the wasm core; words from the js_of_ocaml bundle. The
     split is the honest one: the proved code computes an index, and turning
     an index into three words is a wordlist lookup, not arithmetic. */
  async encode({ lat, lon }) {
    if (key === null) throw new Refused("locked");
    const m = await loadMapCore();
    if (
      !m.encode(
        ...keyWords(key),
        nsOfDeg(lat) - LAT_MIN,
        nsOfDeg(lon) - LON_MIN,
      )
    ) {
      throw new Refused("that point is outside the mapped range");
    }
    const [w1, w2, w3, n] = outWords(m, 4).map(Number);
    return { address: core.addressOfIndices(w1, w2, w3, n) };
  },

  async decode({ address }) {
    if (key === null) throw new Refused("locked");
    let idx;
    try {
      idx = core.indicesOfAddress(address);
    } catch (e) {
      /* A malformed address is a typo, not a fault. The core's message names
         the specific problem -- which word, which part -- so it is passed
         through rather than replaced with something generic. */
      throw new Refused(String(e.message ?? e));
    }
    const m = await loadMapCore();
    const rc = m.decode(
      ...keyWords(key),
      BigInt(idx.w1),
      BigInt(idx.w2),
      BigInt(idx.w3),
      BigInt(idx.n),
    );
    if (rc === -1) {
      throw new Refused("that address is outside the address space");
    }
    if (rc === 0) {
      throw new Refused(
        "That address does not correspond to any location. About 35% of "
          + "word combinations do not, which is what makes a typo obvious.",
      );
    }
    const [dlat, dlon] = outWords(m, 2);
    return { lat: degOfNs(dlat + LAT_MIN), lon: degOfNs(dlon + LON_MIN) };
  },

  /* The grid overlay. Needs no key -- it is pure geometry -- and every cell
     corner comes from the proved `bounds`; this walk only decides which
     cells to ask about. It steps by taking each cell's upper edge as the
     next cell's lower edge, which is exact because the bounds are half-open
     at the high edge, and it steps in BigInt nanodegrees because a boundary
     landing one unit out is the exact bug this project exists to rule out.
     Ported from Tessarium.cells_in_bounds, which drove the same proved
     function from OCaml and still does for the server. */
  async grid({ latLo, lonLo, latHi, lonHi, limit }) {
    const m = await loadMapCore();
    const clamp = (lo, hi, v) => (v < lo ? lo : v > hi ? hi : v);
    const latLoNs = clamp(LAT_MIN, -LAT_MIN, nsOfDeg(latLo));
    const latHiNs = clamp(LAT_MIN, -LAT_MIN, nsOfDeg(latHi));
    const lonLoNs = clamp(LON_MIN, -LON_MIN, nsOfDeg(lonLo));
    const lonHiNs = clamp(LON_MIN, -LON_MIN, nsOfDeg(lonHi));
    const cells = [];
    let truncated = false;
    if (latLoNs <= latHiNs && lonLoNs <= lonHiNs) {
      let lat = latLoNs;
      walk: while (lat <= latHiNs) {
        if (cells.length >= limit) {
          truncated = true;
          break;
        }
        /* Within one row every cell shares the row's latitude bounds, so the
           row's upper edge comes out of the first cell in it. */
        let rowTop = lat + 1n;
        for (let lon = lonLoNs; lon <= lonHiNs;) {
          if (cells.length >= limit) {
            truncated = true;
            break walk;
          }
          if (!m.bounds(lat - LAT_MIN, lon - LON_MIN)) {
            throw new Refused("the grid walk left the mapped range");
          }
          const [a, b, c, d] = outWords(m, 4);
          const latLoC = a + LAT_MIN, latHiC = b + LAT_MIN;
          const lonLoC = c + LON_MIN, lonHiC = d + LON_MIN;
          rowTop = latHiC;
          /* A cell whose upper edge does not advance would loop forever. It
             cannot happen -- widths are positive -- but the guard costs
             nothing and a hung tab costs a lot. */
          if (lonHiC <= lon) break;
          cells.push(latLoC, latHiC, lonLoC, lonHiC);
          lon = lonHiC;
        }
        if (rowTop <= lat) break;
        lat = rowTop;
      }
      if (lat <= latHiNs && !truncated) truncated = cells.length >= limit;
    }
    const flat = new Float64Array(cells.length);
    for (let i = 0; i < cells.length; i++) flat[i] = degOfNs(cells[i]);
    return { cells: flat, count: cells.length / 4, truncated };
  },
  /* There is deliberately no bulk-address operation here.

     One existed: it encoded every cell in the viewport at once, to draw an
     address inside each square. It is gone, and the absence is the feature.
     An attacker's problem is finding a phrase that maps a known address to a
     known place, and every (address, place) pair they hold is material for
     that search. A screenshot of a labelled grid hands over fifty pairs in
     one image, from a user who thought they were sharing a picture of a
     street. Addresses are now produced one at a time, for the square the user
     actually asked about. */
};

self.onmessage = async (event) => {
  const { id, op, payload } = event.data;
  const handler = ops[op];
  if (!handler) {
    self.postMessage({ id, error: `unknown op ${op}` });
    return;
  }
  try {
    /* `unlock` is async because the wasm KDF is; the rest are synchronous and
       await passes them straight through. */
    const result = await handler(payload ?? {});
    /* Hand the cell array over rather than copying it. A z20 viewport is a few
       thousand cells; copying that on every map movement is a frame budget
       spent on nothing. */
    const transfer = result.cells ? [result.cells.buffer] : [];
    self.postMessage({ id, result }, transfer);
  } catch (e) {
    self.postMessage({ id, error: String(e?.message ?? e) });
  }
};
