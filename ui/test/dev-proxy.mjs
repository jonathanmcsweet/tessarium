/* The development server's proxy table, checked against what the app asks for.

   `vite dev` serves this application's own files and forwards everything else
   to the OCaml binary. Which paths get forwarded is a hand-written list, and
   a path missing from it does not fail the build, log a warning, or throw:
   Vite falls through to the SPA handler and answers the request with
   index.html. A JSON fetch quietly receives a page of HTML.

   That is not hypothetical. The style's two TileJSON URLs -- /tiles.json and
   /world.json -- were never on the list, so on the dev server the map had no
   cartography at all for as long as the list existed: the grid drew over an
   empty ground, which reads as "nothing downloaded here" rather than as a
   broken proxy. Everywhere else, the same build was fine, because everywhere
   else the OCaml binary serves both halves.

   So the list is checked against the source rather than trusted. Static,
   because standing a dev server and a backend up inside the suite to ask
   them the same question would be a far larger machine for a smaller
   answer. */

import { readdirSync, readFileSync } from "node:fs";

const check = (name, ok) => ({ name, ok });

const config = readFileSync(
  new URL("../vite.config.ts", import.meta.url),
  "utf8",
);

/* The index just past the brace closing the block that opens at `open` --
   a scan carried by reduce, the answer carried once found. */
const blockEnd = (text, open) =>
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

/* The proxy keys, read out of the `proxy: { ... }` block. Both spellings are
   in use -- a bare target and an options object -- and only the key matters
   for coverage. */
const proxyBlock = (() => {
  const at = config.indexOf("proxy: {");
  if (at < 0) return "";
  const open = config.indexOf("{", at);
  return config.slice(open, blockEnd(config, open));
})();
const prefixes = [...proxyBlock.matchAll(/"(\/[^"]*)":/g)].map((m) => m[1]);

/* Every path this application asks its OWN origin for. Collected from the
   places a path can be written: a fetch, a MapLibre style field, and the
   worker's importScripts. Paths built from `${...origin}` count -- that is
   the same origin spelled the long way. */
const sourceFiles = (dir) =>
  readdirSync(dir, { withFileTypes: true })
    .filter((e) => e.name !== "paraglide")
    .flatMap((e) => {
      const child = new URL(`${e.name}${e.isDirectory() ? "/" : ""}`, dir);
      if (e.isDirectory()) return sourceFiles(child);
      return /\.(tsx?|js)$/.test(e.name) ? [readFileSync(child, "utf8")] : [];
    });
const sources = [
  ...sourceFiles(new URL("../src/", import.meta.url)),
  ...sourceFiles(new URL("../public/", import.meta.url)),
];

const patterns = [
  /(?:fetch|importScripts)\(\s*[`"](\/[^`"]*)/g,
  /(?:url|glyphs|sprite):\s*[`"](\/[^`"]*)/g,
  /\$\{[^}]*origin[^}]*\}(\/[A-Za-z0-9_/.-]*)/g,
];
const asked = [
  ...new Set(
    sources.flatMap((text) => patterns.flatMap((re) => [...text.matchAll(re)]))
      /* Down to the first placeholder or query: what the proxy matches on is
         a literal prefix, and everything after `{` or `?` varies. */
      .map((m) => m[1].split(/[?{]/)[0])
      .filter((path) => path.length > 1),
  ),
].sort();

/* Files this project serves itself are not the backend's to answer. They sit
   in public/ and are named here rather than detected, because "is it in
   public/" is a question about the build and this is a question about the
   list. */
const ownFiles = ["/tessarium.js"];

const coverage = asked
  .filter((path) => !ownFiles.includes(path))
  .map((path) =>
    check(
      `the dev proxy forwards ${path}`,
      prefixes.some((p) => path === p || path.startsWith(p)),
    )
  );

/* And the two TileJSON routes must keep the client's Host header.

   A TileJSON has to hand back an absolute URL for its tiles, and the server
   builds it from the Host of whoever asked. Vite's shorthand form turns
   `changeOrigin` on, which rewrites that header to the backend -- so the
   document served on the dev port receives tile URLs on the backend port,
   fetches them cross-origin, and every one is refused. Forwarding the path
   is therefore only half of it, and the half that is invisible: the request
   succeeds and the answer is unusable. */
const keepsHost = ["/tiles", "/world.json"].map((route) => {
  const entry = new RegExp(`"${route}":\\s*\\{[^}]*\\}`)
    .exec(proxyBlock)?.[0] ?? "";
  return check(
    `${route} keeps the caller's host, so its tile URLs are reachable`,
    /changeOrigin:\s*false/.test(entry),
  );
});

const results = [
  check("the dev server has a proxy table", prefixes.length > 0),
  check("the app asks its origin for something", asked.length > 0),
  ...coverage,
  ...keepsHost,
];
const failures = results.filter((r) => !r.ok);
failures.forEach((f) => {
  console.log(`  FAIL  ${f.name}`);
});
console.log(
  `\ndev proxy: ${results.length} checks, ${failures.length} failures`,
);
if (failures.length > 0) process.exit(1);
