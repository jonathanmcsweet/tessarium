/* Reading this application's own source, for the checks that audit it
   instead of running it.

   Three of them walk the same tree for different reasons -- the proxy audit
   collects the paths the app asks its origin for, the contrast audit asks
   which colour tokens are actually spent, the icon audit asks who draws a
   glyph by hand -- and they used to carry three copies of the walk. The
   copies had already started to differ: two skipped `src/paraglide` in a
   filter and the third in a loop, and only one read `.js` at all. What a new
   generated directory would cost is the whole point of putting the walk
   here: added to one copy, it leaves the others either auditing generated
   code (failures nobody wrote) or skipping real components (a token or a
   proxy path silently unaudited).

   What genuinely differs between the callers -- which extensions they read,
   and what they do with a file -- stays with the callers, as an argument and
   as whatever they map the records to. */

import { readdirSync, readFileSync } from "node:fs";

/* Generated, and therefore not source. `paraglide` is the message catalogue
   compiled at every build; `tessarium.js` is the js_of_ocaml bundle
   `pnpm run sync-core` copies into public/. Auditing either holds a
   generator's output to rules written for people -- and the bundle is the
   larger trap of the two, because it is a megabyte of emitted JavaScript
   whose string constants read exactly like paths this application asks for. */
const GENERATED = new Set(["paraglide", "tessarium.js"]);

/* Every source file under `dir`, depth first, as { path, text } records.
   `path` is relative to `dir`, because that is what a failure has to name;
   callers that only want the text take it from the record. */
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

/* The index just past the brace closing the block that opens at `open` --
   a scan carried by reduce, the answer carried once found. Two audits slice a
   block out of a file they cannot parse properly: the palette out of a
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
