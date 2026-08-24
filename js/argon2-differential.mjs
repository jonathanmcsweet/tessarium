// The Argon2id wasm module (the vendored reference C, zig-compiled -- the
// browser's KDF) against noble's independent implementation, on random
// inputs shaped like the real ones: version-prefixed salts, phrase-like
// passwords. The parameters are baked in the wasm glue; a drift there (or a
// miscompile) disagrees with noble here. Deterministic: seeded generator,
// no clock, no OS randomness.
//
// Usage: node argon2-differential.mjs <argon2.wasm>

import { readFileSync } from "node:fs";
import { argon2id } from "@noble/hashes/argon2.js";

const wasmPath = process.argv[2];
if (!wasmPath) throw new Error("usage: argon2-differential.mjs <argon2.wasm>");

// Lehmer, same constant family as the OCaml corpus generators.
let state = 20260821n;
const M61 = (1n << 61n) - 1n;
const next = (bound) => {
  state = (state * 381471956995469n) % M61;
  return Number(state % BigInt(bound));
};

const mod = await WebAssembly.compile(readFileSync(wasmPath));
const imports = WebAssembly.Module.imports(mod);
// The crt stack guard wants wasi random_get and nothing else may appear.
for (const imp of imports) {
  if (imp.module !== "wasi_snapshot_preview1" || imp.name !== "random_get")
    throw new Error(`unexpected wasm import ${imp.module}.${imp.name}`);
}
const instance = await WebAssembly.instantiate(mod, {
  wasi_snapshot_preview1: { random_get: () => 0 },
});
instance.exports._initialize();
const { memory, password_ptr, salt_ptr, out_ptr, kdf } = instance.exports;

const enc = new TextEncoder();
const words = ["abandon", "legal", "winner", "thank", "zoo", "letter",
               "advice", "cage", "absurd", "amount", "doctor", "art"];
let checked = 0;
for (let i = 0; i < 12; i++) {
  const phrase = Array.from({ length: 24 }, () => words[next(words.length)])
    .join(" ");
  const pass = enc.encode(phrase);
  const salt = enc.encode(
    "tessarium-kdf-4" + (i % 3 === 0 ? "" : `pp-${next(100000)}`),
  );
  new Uint8Array(memory.buffer, password_ptr(), pass.length).set(pass);
  new Uint8Array(memory.buffer, salt_ptr(), salt.length).set(salt);
  const rc = kdf(pass.length, salt.length);
  if (rc !== 0) throw new Error(`wasm argon2 rc ${rc} on case ${i}`);
  const got = Buffer.from(
    new Uint8Array(memory.buffer, out_ptr(), 32),
  ).toString("hex");
  const want = Buffer.from(
    argon2id(pass, salt, { t: 3, m: 65536, p: 1, dkLen: 32 }),
  ).toString("hex");
  if (got !== want) {
    console.error(`argon2 disagreement on case ${i}:\n  wasm  ${got}\n  noble ${want}`);
    process.exit(1);
  }
  checked++;
}
// A short salt must be refused, not truncated into a weak derivation.
new Uint8Array(memory.buffer, salt_ptr(), 5).set(enc.encode("short"));
if (kdf(8, 5) !== -101) {
  console.error("argon2: a 5-byte salt was not refused");
  process.exit(1);
}
console.log(
  `argon2 kdf: wasm and noble agree on ${checked} derivations (t=3, m=64MiB, p=1), short salt refused`,
);
