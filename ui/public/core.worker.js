/* The verified core, running off the main thread.

   This worker owns the derived key. Nothing else in the application ever holds
   it: the main thread sends coordinates and receives addresses, and the key
   itself never crosses back. That is a real boundary rather than a stylistic
   one -- the main thread has the DOM, and the DOM is where any injected script
   would be looking.

   It is also where PBKDF2 belongs. 2048 iterations of HMAC-SHA512 is
   deliberately slow, and running it on the main thread would freeze the map
   for the length of the derivation.

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

const ops = {
  validate({ mnemonic }) {
    const error = core.validateMnemonic(mnemonic);
    return { ok: error === null, error };
  },

  /* A phrase the user did not invent.

     This is the highest-value security control in the application, and it is
     three lines long. A phrase a person makes up -- favourite words, a
     sentence rewritten into wordlist words -- is worth perhaps 40 bits of
     guessing effort and passes every check the app makes. These 32 bytes are
     worth 256. The round count and the cost of key derivation only decide
     anything in the case where this step was skipped.

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

  unlock({ mnemonic, passphrase }) {
    const r = core.deriveKey(mnemonic, passphrase ?? "");
    if (r.error) return { ok: false, error: r.error };
    key = r.key;
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

self.onmessage = (event) => {
  const { id, op, payload } = event.data;
  const handler = ops[op];
  if (!handler) {
    self.postMessage({ id, error: `unknown op ${op}` });
    return;
  }
  try {
    const result = handler(payload ?? {});
    /* Hand the cell array over rather than copying it. A z20 viewport is a few
       thousand cells; copying that on every map movement is a frame budget
       spent on nothing. */
    const transfer = result.cells ? [result.cells.buffer] : [];
    self.postMessage({ id, result }, transfer);
  } catch (e) {
    self.postMessage({ id, error: String(e?.message ?? e) });
  }
};
