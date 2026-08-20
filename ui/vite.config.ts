import { paraglideVitePlugin } from "@inlang/paraglide-js";
import react from "@vitejs/plugin-react";
import { readFileSync } from "node:fs";
import { defineConfig } from "vite";

// The dev server proxies to the OCaml server so that `npm run dev` and the
// built app see the same origin layout. Without this the basemap would be
// cross-origin in development and same-origin in production, which is exactly
// the kind of difference that only shows up after a release.
const backend = process.env.TESSARIUM_SERVER ?? "http://127.0.0.1:7373";

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
    sourcemap: true,
    // The core is a 4.4 MB generated artifact served from public/ and loaded
    // by the worker with importScripts. Keeping it out of the bundler means
    // it is cached separately and never re-chunked by a UI change.
    chunkSizeWarningLimit: 1024,
  },
  server: {
    proxy: {
      "/basemap": backend,
      "/api": backend,
      "/healthz": backend,
      // The worker's KDF module is embedded in the backend, not in public/.
      "/argon2.wasm": backend,
    },
  },
});
