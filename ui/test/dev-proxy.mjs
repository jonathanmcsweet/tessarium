/* The dev server's proxy table, checked against what the app asks for.

   `vite dev` serves this app's own files and forwards everything else to the
   OCaml binary. Which paths get forwarded is a hand-written list. A path
   missing from it does not fail the build, warn or throw: Vite falls through
   to the SPA handler and answers with index.html, so a JSON fetch receives a
   page of HTML.

   That happened. The style's two TileJSON URLs -- /tiles.json and /world.json
   -- were never on the list, so the dev server's map had no cartography at
   all: the grid drew over empty ground, which reads as "nothing downloaded
   here" rather than as a broken proxy. Every other build was fine, because
   elsewhere the OCaml binary serves both halves.

   Checked statically. Standing up a dev server and a backend inside the suite
   would be a far larger machine for a smaller answer. */

import { readFileSync } from "node:fs";
import { blockEnd, sourceFiles } from "./source.mjs";

const check = (name, ok) => ({ name, ok });

const config = readFileSync(
  new URL("../vite.config.ts", import.meta.url),
  "utf8",
);

/* The proxy keys, out of the `proxy: { ... }` block. Both spellings are in
   use -- a bare target and an options object -- and only the key matters. */
const proxyBlock = (() => {
  const at = config.indexOf("proxy: {");
  if (at < 0) return "";
  const open = config.indexOf("{", at);
  return config.slice(open, blockEnd(config, open));
})();
const prefixes = [...proxyBlock.matchAll(/"(\/[^"]*)":/g)].map((m) => m[1]);

/* Every path this app asks its OWN origin for, from the .ts, .tsx and .js
   under src/ and public/. The walk skips generated code -- see
   test/source.mjs. */
const sources = [
  ...sourceFiles(new URL("../src/", import.meta.url), /\.(tsx?|js)$/),
  ...sourceFiles(new URL("../public/", import.meta.url), /\.(tsx?|js)$/),
].map((f) => f.text);

/* Where a path can be written. Matching only fetch and importScripts saw the
   CALL SITE rather than the path, so a literal handed to a local helper was
   invisible -- and both wasm modules are only written that way, as
   `loadWasm("/argon2.wasm")` in the worker. A missing entry for that one does
   not look like a proxy fault: the SPA fallback answers with index.html,
   compileStreaming refuses it, and the unlock fails complaining about the
   wasm.

   So: a literal path handed to any function, a MapLibre style field, and a
   template literal starting at the root -- href builders like
   `/basemap/export/${file}` construct their path, and the proxy matches the
   literal prefix before the first placeholder. `${...origin}/...` is the same
   origin spelled the long way. */
const patterns = [
  /\b[A-Za-z_$][\w$]*\s*\(\s*[`"](\/[^`"]*)/g,
  /(?:url|glyphs|sprite):\s*[`"](\/[^`"]*)/g,
  /`(\/[A-Za-z0-9_/.-]*)/g,
  /\$\{[^}]*origin[^}]*\}(\/[A-Za-z0-9_/.-]*)/g,
];
const asked = [
  ...new Set(
    sources.flatMap((text) => patterns.flatMap((re) => [...text.matchAll(re)]))
      /* Down to the first placeholder or query: the proxy matches a literal
         prefix, and everything after `$`, `{` or `?` varies. */
      .map((m) => m[1].split(/[?${]/)[0])
      .filter((path) => path.length > 1),
  ),
].sort();

/* Files this project serves itself, which the backend is not asked for. They
   sit in public/ and are named here rather than detected: "is it in public/"
   is a question about the build, and this is a question about the list. */
const ownFiles = ["/tessarium.js", "/core.worker.js"];

const coverage = asked
  .filter((path) => !ownFiles.includes(path))
  .map((path) =>
    check(
      `the dev proxy forwards ${path}`,
      prefixes.some((p) => path === p || path.startsWith(p)),
    )
  );

/* And the two TileJSON routes must keep the client's Host header.

   A TileJSON hands back absolute tile URLs, which the server builds from the
   Host of whoever asked. Vite's shorthand form turns `changeOrigin` on, which
   rewrites that header to the backend -- so the page on the dev port receives
   tile URLs on the backend port, fetches them cross-origin, and every one is
   refused. Forwarding the path is only half of it, and the invisible half:
   the request succeeds and the answer is unusable. */
const keepsHost = ["/tiles", "/world.json"].map((route) => {
  const entry = new RegExp(`"${route}":\\s*\\{[^}]*\\}`)
    .exec(proxyBlock)?.[0] ?? "";
  return check(
    `${route} keeps the caller's host, so its tile URLs are reachable`,
    /changeOrigin:\s*false/.test(entry),
  );
});

/* The collector's own floor: a path this file cannot SEE is a path it cannot
   fail on, so a blind spot in the patterns above reads as coverage. One of
   each shape -- handed to a helper, in a style field, built from a template.
   The wasm pair was the invisible shape, so `/argon2.wasm` and `/core.wasm`
   sat in vite.config.ts unguarded by the tool written to guard them. */
const collector = ["/argon2.wasm", "/core.wasm", "/tiles.json", "/basemap/"]
  .map((path) =>
    check(
      `the collector sees ${path}, however it is written`,
      asked.includes(path),
    )
  );

const results = [
  check("the dev server has a proxy table", prefixes.length > 0),
  check("the app asks its origin for something", asked.length > 0),
  ...collector,
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
