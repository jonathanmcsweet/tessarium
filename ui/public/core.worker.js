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

/* Instantiated once, on first unlock. The module's single import is wasi
   random_get, wanted by the prebuilt libc's stack guard; deterministic
   zeros are fine for it, and anything MORE appearing in the import list is
   refused -- the same allow-list discipline as the differential wall. */
let argon2 = null;
async function loadArgon2() {
  if (argon2) return argon2;
  const mod = await WebAssembly.compileStreaming(fetch("/argon2.wasm"));
  for (const imp of WebAssembly.Module.imports(mod)) {
    if (imp.module !== "wasi_snapshot_preview1" || imp.name !== "random_get") {
      throw new Refused(`unexpected wasm import ${imp.module}.${imp.name}`);
    }
  }
  const instance = await WebAssembly.instantiate(mod, {
    wasi_snapshot_preview1: { random_get: () => 0 },
  });
  instance.exports._initialize();
  argon2 = instance.exports;
  return argon2;
}

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

  encode({ lat, lon }) {
    if (key === null) throw new Refused("locked");
    return { address: core.encodeDeg(key, lat, lon) };
  },

  decode({ address }) {
    if (key === null) throw new Refused("locked");
    let point;
    try {
      point = core.decodeDeg(key, address);
    } catch (e) {
      /* A malformed address is a typo, not a fault. The core's message names
         the specific problem -- which word, which part -- so it is passed
         through rather than replaced with something generic. */
      throw new Refused(String(e.message ?? e));
    }
    if (point === null) {
      throw new Refused(
        "That address does not correspond to any location. About 35% of "
          + "word combinations do not, which is what makes a typo obvious.",
      );
    }
    return { lat: point.lat, lon: point.lon };
  },

  /* The grid overlay. Needs no key -- it is pure geometry -- but is served
     from here so there is one copy of the core in the process rather than
     two, and because the walk itself must happen in the core's integer
     arithmetic rather than in JavaScript floats. */
  grid({ latLo, lonLo, latHi, lonHi, limit }) {
    const g = core.gridForBounds(latLo, lonLo, latHi, lonHi, limit);
    return { cells: g.cells, count: g.count, truncated: g.truncated };
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
