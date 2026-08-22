/* The two browser artifacts this project builds itself, held to a size
   budget.

   This exists because of a real regression that nothing caught: dune's dev
   profile tells js_of_ocaml to inline a source map, and it linked every
   library separately, so the bundle was 5,106 KB -- 2,924 KB of it source map,
   and most of the rest modules nothing in the browser calls. The server sent
   1,058 KB of that, gzipped, on every first visit, and no test said a word,
   because the bundle was correct. It was just enormous.

   Size is not a property any suite here would otherwise look at, and the two
   dune settings that fix it (ocaml/js/dune: `sourcemap no`,
   `compilation_mode whole_program`) are one careless edit from being lost.
   Both are held below: dropping either one blows the budget on its own.

   What this does NOT cover: `assets/index-*.js`, the Vite chunk, which is
   larger than both files here put together. It does not exist until a full
   UI build has run, and it is bounded by its dependencies rather than by
   anything in this repository. roadmap.md carries that one.

   The bundle is measured where dune writes it. `npm run sync-core` copies
   that file to public/ byte for byte and Vite copies public/ into dist/ the
   same way, so this is the artifact that ships, one step earlier -- and
   reading it here rather than the copy means this check cannot grade a stale
   copy, and cannot leave one behind either.

   Node's zlib is the compressor and the server's is not: `ocaml/gzip` emits
   7% more on the bundle -- 181,447 bytes against 169,561 -- so every figure
   below runs under what actually goes on the wire, and the budgets are set
   with that gap already spent. The bundle's is close to the real figure on
   purpose, meant to fail on a regression rather than leave room for one; the
   worker's is looser because it is a hand-written file that no build setting
   governs, and it is here to catch someone pasting a library into it. Raise
   either only with a measurement saying why. */

import { readFileSync } from "node:fs";
import { gzipSync } from "node:zlib";

let checks = 0;
let failures = 0;
const check = (name, ok) => {
  checks++;
  if (!ok) {
    failures++;
    console.log(`  FAIL  ${name}`);
  }
};

const kb = (n) => `${(n / 1000).toFixed(1)} KB`;
const at = (p) => new URL(p, import.meta.url);

/* file, what it is, gzipped budget in bytes. */
const budgets = [
  [
    at("../../_build/default/ocaml/js/tessarium_js.bc.js"),
    "the js_of_ocaml bundle",
    200_000,
  ],
  [at("../public/core.worker.js"), "the worker", 12_000],
];

const measured = [];
for (const [file, what, budget] of budgets) {
  let raw;
  try {
    raw = readFileSync(file);
  } catch {
    console.log(
      `  FAIL  ${what} is not built -- run \`dune build\` first (${file.pathname})`,
    );
    checks++;
    failures++;
    continue;
  }
  const gz = gzipSync(raw, { level: 9 }).length;
  measured.push(what);
  /* Printed rather than only asserted, as ui/test/e2e.mjs does with its own
     figures: a threshold that passes says nothing about how much room is
     left under it, and these are numbers the project makes a claim about. */
  console.log(
    `  ${what}: ${kb(gz)} gzipped of ${kb(budget)} allowed, ${
      kb(raw.length)
    } raw`,
  );
  check(
    `${what} is within budget: ${kb(gz)} gzipped of ${kb(budget)} (${
      kb(raw.length)
    } raw)`,
    gz <= budget,
  );
}

/* The bundle only. core.worker.js is hand-written and copied verbatim, so
   there is no build step that could attach a map to it, and asserting it
   would assert nothing.

   Read again rather than kept from the loop above, and guarded, because the
   loop reports a missing bundle as a failure and carries on -- an unguarded
   read here would take the process down before the summary and the
   did-this-run guard below, which is the state `make test-static` finds on a
   cold _build. */
let bundle = "";
try {
  bundle = readFileSync(budgets[0][0], "utf8");
} catch { /* already reported as a failure above. */ }
check(
  "the bundle ships no source map",
  bundle !== "" && !bundle.includes("sourceMappingURL"),
);

/* An empty budget list would otherwise pass in silence, which is the failure
   tools/check-suites.sh exists because of. */
check(
  `both artifacts were measured (${measured.length})`,
  measured.length === 2,
);

console.log(`\nbrowser payload: ${checks} checks, ${failures} failures`);
if (failures > 0) process.exit(1);
