// Do the documents still say what the code does?
//
// The message the round function signs has a length, and that length is
// TRANSCRIBED by hand into fstar/low/Tessarium.Low.Blake2s.fst as literal
// words and a byte counter. No test can catch a stale prose copy of it, and
// the prose is what a maintainer reads before touching a constant. It has
// gone stale once already: after the project rename the count read 43 in
// three files and 47 in two, in the one place where that number is the whole
// load-bearing fact.
//
// So the numbers are derived here from the constants themselves, and every
// claim about them anywhere in the tracked tree has to agree.
//
// Deliberately NOT run over roadmap-progress.md: a ledger entry records what
// was true on its date, and 47 was true when it was written. Rewriting that
// to match today is how a ledger stops being a record.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const root = new URL("..", import.meta.url).pathname;
const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

/* ---- the truth, taken from the constants rather than from any prose ---- */

const literal = (text, re, what) => {
  const m = text.match(re);
  if (!m) throw new Error(`cannot find ${what} -- this check is out of date`);
  return m[1];
};

const prefix = literal(
  read("../ocaml/lib/crypto.ml"),
  /^let domain_prefix = "([^"]*)"/m,
  "the domain prefix in ocaml/lib/crypto.ml",
);
const tweak = literal(
  read("../design/grid_design.py"),
  /^GRID_VERSION = "([^"]*)"/m,
  "GRID_VERSION in design/grid_design.py",
);

// prefix | 2-byte tweak length | tweak | round index | 8-byte block
const messageLen = prefix.length + 2 + tweak.length + 1 + 8;
// One 64-byte key block precedes it, and BLAKE2s counts bytes compressed.
const counter = 64 + messageLen;

/* ------------------------------ the claims ----------------------------- */

const claims = [
  {
    // The fixed-shape function is named for the length of the message it
    // transcribes, so its name is a claim about that length. blake2s256 in
    // the C harness is not: that one is named for its DIGEST size, is the
    // general chaining, and takes a message of any length. Excluded by
    // number rather than by file, because the name is what identifies it.
    what: "the transcribed function's name",
    re: /blake2s(\d+)\b/g,
    ok: (n) => n === messageLen || n === 256,
    expect: `blake2s${messageLen}`,
  },
  {
    what: "a stated message length",
    re: /(\d+)-byte message/g,
    ok: (n) => n === messageLen,
    expect: `${messageLen}-byte message`,
  },
  {
    what: "a stated byte counter",
    re: /counter of (\d+)/g,
    ok: (n) => n === counter,
    expect: `counter of ${counter}`,
  },
  {
    // "key block at t=64, the fixed message block at t=107"
    what: "a stated compression counter",
    re: /\bat t=(\d+)/g,
    ok: (n) => n === 64 || n === counter,
    expect: `at t=64 or at t=${counter}`,
  },
];

const skip = [
  "roadmap-progress.md", // a ledger records what was true on its date
];

const files = execFileSync("git", ["ls-files", "-z"], { cwd: root })
  .toString()
  .split("\0")
  .filter(Boolean)
  .filter((f) => !skip.includes(f))
  .filter((f) => /\.(md|ml|mli|mjs|js|ts|tsx|fst|fsti|c|h|py|sh|yml|dune)$/.test(f)
    || f === "dune" || f.endsWith("/dune"));

let bad = 0;
const found = new Map(claims.map((c) => [c.what, 0]));

for (const f of files) {
  let text;
  try {
    text = readFileSync(`${root}/${f}`, "utf8");
  } catch {
    continue; // not text
  }
  for (const claim of claims) {
    for (const m of text.matchAll(claim.re)) {
      found.set(claim.what, found.get(claim.what) + 1);
      if (claim.ok(Number(m[1]))) continue;
      const line = text.slice(0, m.index).split("\n").length;
      console.log(`  FAIL  ${f}:${line}  ${claim.what} says ${m[0]}, code says ${claim.expect}`);
      bad++;
    }
  }
}

/* A check that matches nothing passes for the wrong reason -- the same
   failure tools/check-suites.sh exists to catch one level up. */
for (const [what, n] of found) {
  if (n === 0) {
    console.log(`  FAIL  no ${what} found anywhere -- this check has stopped checking`);
    bad++;
  }
}

console.log(
  `doc constants: prefix ${prefix.length}B, tweak ${tweak.length}B, message ${messageLen}B, counter ${counter}; `
    + `${files.length} files, ${bad} disagreements`,
);
process.exit(bad ? 1 : 0);
