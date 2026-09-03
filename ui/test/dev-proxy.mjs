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

let checks = 0;
let failures = 0;
const check = (name, ok) => {
  checks++;
  if (!ok) {
    failures++;
    console.log(`  FAIL  ${name}`);
  }
};

const config = readFileSync(
  new URL("../vite.config.ts", import.meta.url),
  "utf8",
);

/* The proxy keys, read out of the `proxy: { ... }` block. Both spellings are
   in use -- a bare target and an options object -- and only the key matters
   for coverage. */
const proxyBlock = (() => {
  const at = config.indexOf("proxy: {");
  if (at < 0) return "";
  const open = config.indexOf("{", at);
  let depth = 0;
  for (let i = open; i < config.length; i++) {
    if (config[i] === "{") depth++;
    else if (config[i] === "}" && --depth === 0) return config.slice(open, i);
  }
  return "";
})();
const prefixes = [...proxyBlock.matchAll(/"(\/[^"]*)":/g)].map((m) => m[1]);

check("the dev server has a proxy table", prefixes.length > 0);

/* Every path this application asks its OWN origin for. Collected from the
   places a path can be written: a fetch, a MapLibre style field, and the
   worker's importScripts. Paths built from `${...origin}` count -- that is
   the same origin spelled the long way. */
const sources = [];
const walk = (dir) => {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (e.name === "paraglide") continue;
    const child = new URL(`${e.name}${e.isDirectory() ? "/" : ""}`, dir);
    if (e.isDirectory()) walk(child);
    else if (/\.(tsx?|js)$/.test(e.name)) {
      sources.push(readFileSync(child, "utf8"));
    }
  }
};
walk(new URL("../src/", import.meta.url));
walk(new URL("../public/", import.meta.url));

const asked = new Set();
for (const text of sources) {
  const patterns = [
    /(?:fetch|importScripts)\(\s*[`"](\/[^`"]*)/g,
    /(?:url|glyphs|sprite):\s*[`"](\/[^`"]*)/g,
    /\$\{[^}]*origin[^}]*\}(\/[A-Za-z0-9_/.-]*)/g,
  ];
  for (const re of patterns) {
    for (const m of text.matchAll(re)) {
      /* Down to the first placeholder or query: what the proxy matches on is
         a literal prefix, and everything after `{` or `?` varies. */
      const path = m[1].split(/[?{]/)[0];
      if (path.length > 1) asked.add(path);
    }
  }
}

check("the app asks its origin for something", asked.size > 0);

/* Files this project serves itself are not the backend's to answer. They sit
   in public/ and are named here rather than detected, because "is it in
   public/" is a question about the build and this is a question about the
   list. */
const ownFiles = ["/tessarium.js"];

for (const path of [...asked].sort()) {
  if (ownFiles.includes(path)) continue;
  check(
    `the dev proxy forwards ${path}`,
    prefixes.some((p) => path === p || path.startsWith(p)),
  );
}

/* And the two TileJSON routes must keep the client's Host header.

   A TileJSON has to hand back an absolute URL for its tiles, and the server
   builds it from the Host of whoever asked. Vite's shorthand form turns
   `changeOrigin` on, which rewrites that header to the backend -- so the
   document served on the dev port receives tile URLs on the backend port,
   fetches them cross-origin, and every one is refused. Forwarding the path
   is therefore only half of it, and the half that is invisible: the request
   succeeds and the answer is unusable. */
for (const route of ["/tiles", "/world.json"]) {
  const entry = new RegExp(
    `"${route}":\\s*\\{[^}]*\\}`,
  ).exec(proxyBlock)?.[0] ?? "";
  check(
    `${route} keeps the caller's host, so its tile URLs are reachable`,
    /changeOrigin:\s*false/.test(entry),
  );
}

console.log(`\ndev proxy: ${checks} checks, ${failures} failures`);
if (failures > 0) process.exit(1);
