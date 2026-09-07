/* Reads this app's own source, for the audits that read the code instead of
   running it.

   The proxy, contrast and icon audits all walk this tree. They used to keep
   three copies of the walk, and the copies had drifted: two skipped
   `src/paraglide` in a filter, one in a loop, and only one read `.js`. One
   walk means a new generated directory is excluded everywhere at once,
   instead of in some audits and not others.

   Callers still choose which extensions to read and what to do with each
   file. */

import { readdirSync, readFileSync } from "node:fs";

/* Generated, not source. `paraglide` is the message catalogue compiled at
   every build; `tessarium.js` is the js_of_ocaml bundle `pnpm run sync-core`
   copies into public/. The bundle is the bigger trap: a megabyte of emitted
   JavaScript whose string constants read like paths this app asks for. */
const GENERATED = new Set(["paraglide", "tessarium.js"]);

/* Every source file under `dir`, depth first. `path` is relative to `dir`,
   because that is what a failure has to name. */
export const sourceFiles = (dir, extensions = /\.tsx?$/, prefix = "") =>
  readdirSync(dir, { withFileTypes: true })
    .filter((e) => !GENERATED.has(e.name))
    .flatMap((e) => {
      const child = new URL(`${e.name}${e.isDirectory() ? "/" : ""}`, dir);
      if (e.isDirectory()) {
        return sourceFiles(child, extensions, `${prefix}${e.name}/`);
      }
      return extensions.test(e.name)
        ? [{ path: `${prefix}${e.name}`, text: readFileSync(child, "utf8") }]
        : [];
    });

/* The index just past the brace closing the block that opens at `open`. Two
   audits slice a block out of a file they cannot parse: the palette out of a
   stylesheet, the proxy table out of vite.config.ts. */
export const blockEnd = (text, open) =>
  [...text.slice(open)].reduce(
    (state, c, i) =>
      state.end >= 0
        ? state
        : c === "{"
        ? { depth: state.depth + 1, end: -1 }
        : c === "}" && state.depth === 1
        ? { depth: 0, end: open + i }
        : c === "}"
        ? { depth: state.depth - 1, end: -1 }
        : state,
    { depth: 0, end: -1 },
  ).end;
