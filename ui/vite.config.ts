import { paraglideVitePlugin } from "@inlang/paraglide-js";
import react from "@vitejs/plugin-react";
import { readFileSync } from "node:fs";
import { defineConfig } from "vite";

// The dev server proxies to the OCaml server so that `npm run dev` and the
// built app see the same origin layout. Without this the basemap would be
// cross-origin in development and same-origin in production, which is exactly
// the kind of difference that only shows up after a release.
const backend = process.env.TESSARIUM_SERVER ?? "http://127.0.0.1:7373";

// Vite's own default is 5173, which is the port every other Vite project on a
// machine also wants. This one sits in the block the rest of the project
// already uses -- 7373 is the app, 7374-7379 are the servers the end-to-end
// suite starts -- so a second Vite service somewhere else is not a collision.
// TESSARIUM_UI_PORT overrides it, the same way TESSARIUM_SERVER overrides the
// backend above.
const uiPort = Number(process.env.TESSARIUM_UI_PORT ?? 7380);

// Baked in at build time from package.json -- the one version field npm
// already requires -- so the footer cannot disagree with the package.
const { version } = JSON.parse(readFileSync("./package.json", "utf8"));

export default defineConfig({
  define: { __APP_VERSION__: JSON.stringify(version) },
  plugins: [
    react(),
    // Messages are compiled into typed functions rather than looked up from a
    // dictionary at runtime, so a key that does not exist is a build error and
    // an unused message is tree-shaken out.
    // The message-format plugin is a normal pinned npm dependency, referenced
    // by path in project.inlang/settings.json rather than fetched from a CDN,
    // so a clean checkout builds with no network after `npm ci`. That path is
    // resolved from the working directory, which is this directory for every
    // way the UI is built (`make ui`, `npm run build`, `npm run paraglide`).
    paraglideVitePlugin({
      project: "./project.inlang",
      outdir: "./src/paraglide",
      // No cookie and no localStorage. This application persists nothing about
      // the user -- the end-to-end test asserts empty storage and no cookies --
      // and a language preference is not worth being the exception that makes
      // that sentence untrue. `globalVariable` is the in-memory switch the
      // language menu sets; `preferredLanguage` reads the browser's own
      // Accept-Language, which is where the answer already lives.
      strategy: ["globalVariable", "preferredLanguage", "baseLocale"],
    }),
  ],
  build: {
    target: "es2022",
    /* Off, and the reason is what a shipped build is for.

       Nobody downloads a source map: a browser fetches one only with
       developer tools open, so this was never a cost on load. It was a cost
       on every package. The maps are 6.1 MB of the 8.1 MB of assets compiled
       into the server binary, so they travelled in the tarball, the .deb and
       the AppImage — three quarters of the asset weight, to make a release
       build debuggable by whoever happens to open devtools on it.

       Debugging happens against a development build, where `vite dev` emits
       maps regardless of this setting. Anyone who wants a debuggable release
       has the source and one line to change. */
    sourcemap: false,
    // The core is a generated artifact served from public/ and loaded by the
    // worker with importScripts. Keeping it out of the bundler means it is
    // cached separately and never re-chunked by a UI change. Its size is held
    // to a budget by test/payload.mjs, not by the warning below.
    chunkSizeWarningLimit: 1024,
  },
  server: {
    port: uiPort,
    // Fail rather than drift. Vite's default is to take the next free port
    // when the one it asked for is busy, which is how a dev server ends up
    // somewhere other than where the person running it is looking -- exactly
    // the confusion this port exists to end.
    strictPort: true,
    proxy: {
      "/basemap": backend,
      "/api": backend,
      "/healthz": backend,
      // The worker's two wasm modules -- the KDF and the map core -- are
      // embedded in the backend, not in public/. So in dev they come from the
      // last `make ui` and can lag wasm/*.wasm; rerun it after `make sync-wasm`
      // or the browser keeps computing with the old module.
      "/argon2.wasm": backend,
      "/core.wasm": backend,
    },
  },
  // `vite preview` serves the built app and defaults to 4173, which is the
  // same story as 5173. It proxies nothing: a preview is checking what the
  // build produced, and the built app is served by the OCaml binary.
  preview: {
    port: uiPort + 1,
    strictPort: true,
  },
});
