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
/* Every refusal carries a stable CODE, and the English sentence is a
   fallback rather than the thing a user reads.

   This file cannot translate: it has no access to the message catalogue, it
   runs before any locale is chosen, and it is plain JavaScript in public/
   that no bundler touches. So it names the failure and the display edge says
   it -- ui/src/core/refusal.ts maps a code to m.*(), and MapView and
   AddressPanel call that instead of reading `.message`.

   `arg` is the one value that varies (a word, a count), passed separately so
   the catalogue entry can put it where its own grammar wants it rather than
   where English does.

   Adding a refusal here means adding its code to ui/src/core/refusal.ts and
   its text to all six files in ui/messages/. ui/test/messages.mjs enforces
   both: it reads the codes back out of this file and asserts each one has an
   entry. A code that slipped through would fall back to the English sentence
   written here, which is why one is always written. */
class Refused extends Error {
  constructor(code, message, arg = "") {
    super(message);
    this.code = code;
    this.arg = arg;
  }
}

/* Not a refusal: the core, the wasm modules or the glue is broken, and no
   wording a user reads will help. One code covers all of them and the
   English detail rides along as `arg`, so a bug report still carries the
   specific sentence. */
const broken = (detail) => new Refused("core_failed", detail, detail);

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
      throw broken(`unexpected wasm import ${imp.module}.${imp.name}`);
    }
  }
  const instance = await WebAssembly.instantiate(mod, {
    wasi_snapshot_preview1: { random_get: () => 0 },
  });
  instance.exports._initialize();
  return instance.exports;
}

/* Both modules are memoised as PROMISES rather than as results. Memoising the
   result looks equivalent and is not: nothing is assigned until two awaits
   have resolved, so two messages arriving before the first load finishes each
   compile a module and each reserve its own linear memory. The map core is
   257 pages, and `queries.ts` issues encode and grid together, so the cold
   first click hit that race every time. The `catch` reset is what keeps a
   failed load retryable -- without it one 404 would poison the cache for the
   life of the tab. */
const once = (load) => {
  let pending = null;
  return () => {
    if (!pending) {
      pending = load().catch((e) => {
        pending = null;
        throw e;
      });
    }
    return pending;
  };
};

/* The KDF. Instantiated once, on first unlock. */
const loadArgon2 = once(() => loadWasm("/argon2.wasm"));

/* The map core: the same F* the server's HTTP API answers from, compiled to
   wasm instead of to native C. It arrives knowing no geography -- the band
   table crosses from the js_of_ocaml bundle, which holds the table the
   proofs were discharged against, and `seal_cum` re-checks its whole shape
   (base, monotonicity, step bound, grand total) before the module will
   answer anything. A table that fails that check leaves the core unusable
   rather than quietly wrong. */
const loadMapCore = once(async () => {
  /* `make ui` does not depend on `make build`, so a stale `_build` ships a
     bundle that predates these three exports. Without this the first symptom
     is `core.cumTable is not a function` from inside a grid refresh, which
     MapView swallows -- the grid just never appears and nothing says why. */
  if (typeof core.cumTable !== "function") {
    throw broken(
      "the js_of_ocaml bundle predates the wasm core -- run `make build`, "
        + "then `make ui`",
    );
  }
  const exports = await loadWasm("/core.wasm");
  /* A method on the bundle, not a property: js_of_ocaml exposes `val` as a
     field and `method` as a callable, and reading the callable hands
     seal_cum a function instead of a table. */
  const table = core.cumTable();
  for (let i = 0; i < table.length; i++) {
    if (!exports.set_cum(i, BigInt(table[i]))) {
      throw broken(`the band table was refused at entry ${i}`);
    }
  }
  if (!exports.seal_cum()) {
    throw broken("the band table failed the core's shape check");
  }
  return exports;
});

/* Integer nanodegrees, as the whole design requires: the only float here is
   the degree the UI speaks, converted once at this boundary.

   `d * 1e9` is a correctly-rounded double, NOT the exact decimal product --
   51.5074 * 1e9 is a hair under 51507400000 in exact arithmetic and lands on
   it only because the double rounds there. What matters is the tie-break, and
   Math.round alone gets it wrong: it breaks ties toward +Infinity, while
   OCaml's Float.round -- which is what this boundary used to run, through
   js_of_ocaml -- breaks them away from zero. They disagree on exactly the
   negative halves, so a coordinate whose product is k + 0.5 AND which sits on
   a cell boundary would have landed in a different cell and produced a
   different address on the two paths. Rare, unreachable from a map click, and
   precisely the class of one-unit boundary error this project exists to rule
   out. */
const LAT_MIN = -90000000000n;
const LON_MIN = -180000000000n;
const nsOfDeg = (d) => {
  const p = d * 1e9;
  return BigInt(p >= 0 ? Math.round(p) : -Math.round(-p));
};
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

/* The core's four-word out block, read through a view that is rebuilt only
   when the underlying buffer is replaced. Nothing on these paths grows the
   memory, so in practice it is built once -- but a detached view throws
   rather than reading stale bytes, so the identity check is the cheap way to
   stay correct if that ever changes. A fresh view per call is what the grid
   walk made expensive: 12,000 cells a viewport, two allocations each. */
let outCache = null;
let outBuffer = null;
const outWords = (m) => {
  if (outBuffer !== m.memory.buffer) {
    outBuffer = m.memory.buffer;
    outCache = new BigUint64Array(outBuffer, m.out_ptr(), 4);
  }
  return outCache;
};

/* A refusal from the bundle, copied into a plain object.

   What js_of_ocaml hands back is its own object, and every refusal here
   either crosses postMessage -- which structure-clones whatever it is given
   -- or is read by name on the main thread. Three known fields is a
   contract; the bundle's representation of an object is not, and it changed
   once already. `String()` on each because Js.string values are JS strings
   in practice and this does not want to depend on that.

   This replaced a helper that dug messages out of OCaml exception arrays.
   Nothing raises across that boundary any more: the two bundle calls that
   could -- validateMnemonic and indicesOfAddress -- answer with a refusal. */
const refusalOf = (r) =>
  r === null || r === undefined ? null : {
    code: String(r.code),
    arg: String(r.arg),
    message: String(r.message),
  };

async function deriveKey(mnemonic, passphrase) {
  const inputs = core.kdfInputs(mnemonic, passphrase);
  /* A refusal from the core, carrying its own code: a bad phrase or an
     over-long passphrase. Rethrown rather than reworded -- the core is where
     the rule lives, so it is where the name of the failure belongs. */
  const refused = refusalOf(inputs.error);
  if (refused !== null) {
    throw new Refused(refused.code, refused.message, refused.arg);
  }
  const password = bytesOfHex(inputs.password);
  const salt = bytesOfHex(inputs.salt);
  /* The core already bounds both inputs (max_passphrase_bytes), so these
     can only trip on a drift between its limit and the glue's buffers --
     checked BEFORE anything is written, because the glue's own check runs
     after the write and cannot protect the memory around the buffers. */
  if (password.length > 1024 || salt.length > 1024) {
    throw broken("KDF input exceeds the wasm buffers");
  }
  const a = await loadArgon2();
  new Uint8Array(a.memory.buffer, a.password_ptr(), password.length)
    .set(password);
  new Uint8Array(a.memory.buffer, a.salt_ptr(), salt.length).set(salt);
  const rc = a.kdf(password.length, salt.length);
  if (rc !== 0) throw broken(`argon2 failed with code ${rc}`);
  return hex(new Uint8Array(a.memory.buffer, a.out_ptr(), 32));
}

const ops = {
  /* Is this text an address, text on its way to being one, or a place name?
     Asked by the search box before it asks the server anything, because the
     one thing that must never happen is an address reaching the place index.
     Pure string work in the bundle -- no key, no wasm, safe on a keystroke.
     The answer's meaning lives in Tessarium.address_shape, beside the
     format, so this file does not get a second opinion about it. */
  addressShape({ text }) {
    return { shape: core.addressShape(text) };
  },

  validate({ mnemonic }) {
    const error = refusalOf(core.validateMnemonic(mnemonic));
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
    const invalid = refusalOf(core.validateMnemonic(mnemonic));
    if (invalid !== null) return { ok: false, error: invalid };
    /* The wasm KDF would happily run over plain HTTP -- unlike the old
       WebCrypto path, nothing technical stops it. The refusal is kept as
       POLICY: a seed-phrase form served over plain HTTP is a mistake, and
       saying so plainly beats deriving anyway. Loopback counts as secure,
       so the desktop app and `make run` are fine. */
    if (!self.isSecureContext) {
      return {
        ok: false,
        error: {
          code: "insecure_context",
          arg: "",
          message: "This page is not in a secure context, so it will not "
            + "derive a key. Serve it over HTTPS or from localhost.",
        },
      };
    }
    /* A refused derivation -- over-long passphrase, wasm trouble -- is a
       result to display like a failed checksum, not a rejected promise. */
    try {
      key = await deriveKey(mnemonic, passphrase ?? "");
    } catch (e) {
      if (e instanceof Refused) {
        return {
          ok: false,
          error: { code: e.code, arg: e.arg, message: e.message },
        };
      }
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
    if (key === null) throw new Refused("locked", "locked");
    const m = await loadMapCore();
    /* Re-read after the await, not before it. These ops were synchronous
       until the core moved to wasm; now a `lock` can land while the first
       call is still fetching and compiling, and `keyWords(null)` would put
       a TypeError in the user's toast instead of "locked". */
    const k = key;
    if (k === null) throw new Refused("locked", "locked");
    if (
      !m.encode(...keyWords(k), nsOfDeg(lat) - LAT_MIN, nsOfDeg(lon) - LON_MIN)
    ) {
      throw new Refused(
        "point_out_of_range",
        "that point is outside the mapped range",
      );
    }
    const out = outWords(m);
    return {
      address: core.addressOfIndices(
        Number(out[0]),
        Number(out[1]),
        Number(out[2]),
        Number(out[3]),
      ),
    };
  },

  async decode({ address }) {
    if (key === null) throw new Refused("locked", "locked");
    /* A malformed address is a typo, not a fault, and the core names the
       specific problem -- which word, which part. It answers with a refusal
       rather than raising, so there is no OCaml exception to unpick here. */
    const idx = core.indicesOfAddress(address);
    const bad = refusalOf(idx.error);
    if (bad !== null) throw new Refused(bad.code, bad.message, bad.arg);
    const m = await loadMapCore();
    const k = key;
    if (k === null) throw new Refused("locked", "locked");
    const rc = m.decode(
      ...keyWords(k),
      BigInt(idx.w1),
      BigInt(idx.w2),
      BigInt(idx.w3),
      BigInt(idx.n),
    );
    /* Not a refusal: -1 means an argument outside the core's domain, which
       `indicesOfAddress` cannot produce -- it resolves words through the
       wordlist (0..2047) and a four-digit number. So this is unreachable, and
       if an ABI change ever made it reachable it must not be dressed up as
       the user's typo. A plain Error, deliberately: Refused is the class for
       things the user did. */
    if (rc === -1) {
      throw new Error("the core refused an address the codec produced");
    }
    if (rc === 0) {
      throw new Refused(
        "address_no_location",
        "That address does not correspond to any location. About 35% of "
          + "word combinations do not, which is what makes a typo obvious.",
      );
    }
    const [dlat, dlon] = outWords(m, 2);
    return { lat: degOfNs(dlat + LAT_MIN), lon: degOfNs(dlon + LON_MIN) };
  },

  /* The grid overlay. Needs no key -- it is pure geometry -- and every cell
     corner comes from the proved `bounds`; this walk only decides which cells
     to ask about. It steps by taking each cell's upper edge as the next
     cell's lower edge, which is exact because the bounds are half-open at the
     high edge, and it steps in BigInt nanodegrees because a boundary landing
     one unit out is the exact bug this project exists to rule out.

     A transcription of Tessarium.cells_in_bounds, which still drives the
     server. Two drivers over one proved function is a real cost, so they are
     pinned to each other: js/worker-differential.mjs drives this worker and
     the OCaml walk in one process on every `make test`, over the corners
     where they used to disagree. `limit` counts CELLS, not the four numbers each one contributes
     to the flat array -- getting that wrong quartered the grid. */
  async grid({ latLo, lonLo, latHi, lonHi, limit }) {
    const m = await loadMapCore();
    const clamp = (lo, hi, v) => (v < lo ? lo : v > hi ? hi : v);
    const latLoNs = clamp(LAT_MIN, -LAT_MIN, nsOfDeg(latLo));
    const latHiNs = clamp(LAT_MIN, -LAT_MIN, nsOfDeg(latHi));
    const lonLoNs = clamp(LON_MIN, -LON_MIN, nsOfDeg(lonLo));
    const lonHiNs = clamp(LON_MIN, -LON_MIN, nsOfDeg(lonHi));
    const cells = [];
    let count = 0;
    let truncated = false;
    if (latLoNs <= latHiNs && lonLoNs <= lonHiNs) {
      let lat = latLoNs;
      for (;;) {
        if (lat > latHiNs) break;
        if (count >= limit) {
          truncated = true;
          break;
        }
        /* Within one row every cell shares the row's latitude bounds, so the
           row's upper edge comes out of the first cell in it. `cut` is the
           row reporting that it stopped with cells still owed. */
        let rowTop = lat + 1n;
        let cut = false;
        for (let lon = lonLoNs;;) {
          if (lon > lonHiNs) break;
          if (count >= limit) {
            cut = true;
            break;
          }
          if (!m.bounds(lat - LAT_MIN, lon - LON_MIN)) {
            throw broken("the grid walk left the mapped range");
          }
          const out = outWords(m);
          const latLoC = out[0] + LAT_MIN, latHiC = out[1] + LAT_MIN;
          const lonLoC = out[2] + LON_MIN, lonHiC = out[3] + LON_MIN;
          rowTop = latHiC;
          /* A cell whose upper edge does not advance would loop forever.
             This one DOES fire, at lon_max, where the last cell in a row is
             clamped to zero width -- so it ends the row and the walk carries
             on to the next one. Ending the walk here drew a single row for
             any viewport touching the antimeridian. Nothing is owed, so no
             truncation either. */
          if (lonHiC <= lon) break;
          cells.push(latLoC, latHiC, lonLoC, lonHiC);
          count += 1;
          lon = lonHiC;
        }
        if (cut || rowTop <= lat) {
          truncated = true;
          break;
        }
        lat = rowTop;
      }
    }
    const flat = new Float64Array(cells.length);
    for (let i = 0; i < cells.length; i++) flat[i] = degOfNs(cells[i]);
    return { cells: flat, count, truncated };
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
    self.postMessage({ id, error: `unknown op ${op}`, code: null, arg: "" });
    return;
  }
  try {
    /* `unlock`, `encode`, `decode` and `grid` are async: the KDF and the map
       core are both wasm modules, loaded on first use. `validate`, `generate`,
       `lock` and `status` stay synchronous and await passes them straight
       through. The consequence for anything added here: an op that reads
       `key` must re-read it AFTER every await, because `lock` can land in
       between. */
    const result = await handler(payload ?? {});
    /* Hand the cell array over rather than copying it. A z20 viewport is a few
       thousand cells; copying that on every map movement is a frame budget
       spent on nothing. */
    const transfer = result.cells ? [result.cells.buffer] : [];
    self.postMessage({ id, result }, transfer);
  } catch (e) {
    /* The code travels beside the message. Anything without one is not a
       Refused -- a genuine bug in here -- and the edge shows it as such
       rather than pretending it is something the user did. */
    self.postMessage({
      id,
      error: String(e?.message ?? e),
      code: typeof e?.code === "string" ? e.code : null,
      arg: typeof e?.arg === "string" ? e.arg : "",
    });
  }
};
