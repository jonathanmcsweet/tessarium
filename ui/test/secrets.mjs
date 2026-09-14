/* What holds the seed phrase, and what forgets it.

   The phrase used to be wiped the moment the key existed. It is now kept, in
   the worker, so the two copy controls have something to copy -- and that is a
   trade, not an oversight, which means the shape of it has to be checked
   rather than remembered.

   Read as text, like icons.mjs and shell.mjs, because the one property that
   matters most cannot be observed from the page at all: a locked tab holding
   the words would look identical from outside to one that had forgotten them.
   That is the point of the boundary, and it is why this file exists. */

import { readFileSync } from "node:fs";

let checks = 0;
let failures = 0;
const check = (name, ok) => {
  checks++;
  if (!ok) {
    failures++;
    console.log(`  FAIL  ${name}`);
  }
};

const read = (path) =>
  readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

/* Comments say the words "phrase" and "storage" constantly. Every rule below
   reads code, so the prose comes out first -- the mistake the rejected grep
   made once already in this project. */
const strip = (text) =>
  text.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");

const worker = strip(read("public/core.worker.js"));
const client = strip(read("src/core/client.ts"));
const queries = strip(read("src/core/queries.ts"));
const gate = strip(read("src/components/PhraseEntry.tsx"));

check("there is a worker to read", worker.length > 0);

/* One binding, at module scope beside the key. A phrase parked on `self` or
   in a map keyed by anything would outlive `lock` without looking like it
   does. */
const held = worker.match(/^let phrase = null;$/m);
check(
  "the worker holds the phrase in one binding beside the key",
  held !== null,
);

/* And it is set only where the key is. A second assignment is a second
   lifetime, and the second one is the one nobody remembers to clear. */
const writes = [...worker.matchAll(/(?<!let )\bphrase = /g)].length;
check(
  `it is written in exactly two places, set and cleared (${writes})`,
  writes === 2,
);

/* Set AFTER the derivation, not before it: a phrase that failed to derive is
   a phrase this application was never given. */
const unlockBody = worker.slice(
  worker.indexOf("async unlock("),
  worker.indexOf("heldPhrase()"),
);
check(
  "the phrase is kept only once the key derived",
  unlockBody.indexOf("key = await deriveKey")
    < unlockBody.indexOf("phrase = mnemonic"),
);

/* Lock forgets both, in the same breath. This is the check that cannot be
   written against the running app. */
const lockBody = worker.slice(worker.indexOf("  lock() {"));
const lockEnd = lockBody.indexOf("\n  },");
check(
  "lock forgets the phrase with the key",
  /key = null;/.test(lockBody.slice(0, lockEnd))
    && /phrase = null;/.test(lockBody.slice(0, lockEnd)),
);

/* Nothing writes it anywhere that survives the tab. Storage is checkable
   because the worker touches none of it at all; the network is NOT, and the
   check that claimed to cover it was removed rather than weakened -- the
   worker fetches `argon2.wasm`, so "does this file call fetch" answers yes
   and says nothing about what is in the body. What holds that property is
   the server surface: no endpoint takes a phrase, and the one that used to
   is the opt-in scripting API, which this worker does not call. */
check(
  "the worker never hands the phrase to browser storage",
  !/localStorage|sessionStorage|indexedDB/.test(worker),
);
check(
  "and the only thing it fetches is the KDF module",
  [...worker.matchAll(/\bfetch\s*\(/g)].length === 1
    && /compileStreaming\(fetch\(/.test(worker),
);

/* The page asks for it and keeps nothing. A React Query hook would park the
   answer in a cache on this thread, which is the whole thing the worker
   boundary is for -- so `heldPhrase` deliberately has no hook. */
check(
  "the client exposes the phrase as a call, not a cached query",
  /heldPhrase\(\)/.test(client) && !/heldPhrase/.test(queries),
);

/* And the gate still drops its copy the moment it is no longer needed. The
   worker holding the phrase is not a reason for the form to hold it too. */
check(
  "the unlock form still clears its own copy on success",
  /setPhrase\(""\)/.test(gate) && /setGenerated\(null\)/.test(gate),
);

check(
  "the gate reveals the field only when the toggle is pressed",
  [...gate.matchAll(/setShown\(/g)].length === 1
    && /\[shown, setShown\] = useState\(false\)/.test(gate),
);

console.log(`\nsecrets: ${checks} checks, ${failures} failures`);
if (failures > 0) process.exit(1);
