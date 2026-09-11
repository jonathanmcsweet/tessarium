import { paraglideVitePlugin } from "@inlang/paraglide-js";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { readFileSync } from "node:fs";
import { defineConfig } from "vite";

// The dev server proxies to the OCaml server so `npm run dev` and the built
// app see the same origin layout. Without it the basemap is cross-origin in
// development and same-origin in production -- a difference that only shows
// up after a release.
const backend = process.env.TESSARIUM_SERVER ?? "http://127.0.0.1:7373";

// Vite's default is 5173, the port every other Vite project also wants. This
// one sits in the block the project already uses: 7373 is the app, 7374-7379
// are the servers the end-to-end suite starts. TESSARIUM_UI_PORT overrides
// it, as TESSARIUM_SERVER overrides the backend above.
const uiPort = Number(process.env.TESSARIUM_UI_PORT ?? 7380);

// Baked in at build time from package.json -- the one version field npm
// already requires -- so the footer cannot disagree with the package.
const { version } = JSON.parse(readFileSync("./package.json", "utf8"));

export default defineConfig({
  define: { __APP_VERSION__: JSON.stringify(version) },
  plugins: [
    react(),
    // Tailwind compiles at build time and emits a plain stylesheet, so the
    // shipped app reaches no third party: no CDN, no runtime, no font off
    // somebody else's origin. The one typeface it does not find on the
    // machine -- the pixel face the cyberpunk wordmark wears -- ships in
    // public/fonts and is served from here like everything else. Only the
    // utilities the source actually mentions survive into that file, which is
    // why the design scale can be large without the download being.
    tailwindcss(),
    // Messages compile into typed functions rather than a runtime dictionary
    // lookup, so a missing key is a build error and an unused message is
    // tree-shaken out.
    // The message-format plugin is a pinned npm dependency, referenced by
    // path in project.inlang/settings.json rather than fetched from a CDN, so
    // a clean checkout builds with no network. That path is resolved from the
    // working directory, which is this one for every way the UI is built
    // (`make ui`, `npm run build`, `npm run paraglide`).
    paraglideVitePlugin({
      project: "./project.inlang",
      outdir: "./src/paraglide",
      // No cookie and no localStorage: this application persists nothing
      // about the user, and the end-to-end test asserts empty storage and no
      // cookies. `globalVariable` is the in-memory switch the language menu
      // sets; `preferredLanguage` reads the browser's Accept-Language.
      strategy: ["globalVariable", "preferredLanguage", "baseLocale"],
    }),
  ],
  build: {
    target: "es2022",
    /* Off. A browser fetches a source map only with developer tools open, so
       this was never a cost on load -- it was a cost on every package. The
       maps were 6.1 MB of the 8.1 MB of assets compiled into the server
       binary, and travelled in the tarball, the .deb and the AppImage.

       `vite dev` emits maps regardless of this setting, which is where
       debugging happens. */
    sourcemap: false,
    // The core is a generated artifact served from public/ and loaded by the
    // worker with importScripts. Out of the bundler, it is cached separately
    // and never re-chunked by a UI change. Its size is held to a budget by
    // test/payload.mjs, not by the warning below.
    chunkSizeWarningLimit: 1024,
  },
  server: {
    port: uiPort,
    // Fail rather than drift. Vite's default is to take the next free port
    // when the one it asked for is busy, which lands the dev server somewhere
    // other than where the person running it is looking.
    strictPort: true,
    /* Everything the app asks its own origin for that this server does not
       hold. test/dev-proxy.mjs walks the source for those paths and fails
       when one is not covered here. A missing entry breaks nothing and logs
       nothing -- it just serves index.html for a JSON request, which is how
       the dev server spent a long while showing the grid over no
       cartography: the style's two TileJSON URLs were never on this list. */
    proxy: {
      "/basemap": backend,
      "/api": backend,
      "/healthz": backend,
      /* The style's two sources. Vite matches by prefix, so `/tiles` covers
         both the TileJSON at /tiles.json and the tiles at
         /tiles/{z}/{x}/{y}.mvt that it points at.

         `changeOrigin: false` is load-bearing. A TileJSON hands back
         absolute tile URLs, built from the request's own Host header. Vite's
         shorthand turns changeOrigin ON, rewriting Host to the backend -- so
         a document served at :7380 gets tile URLs on :7373, fetches them
         cross-origin, and every one is refused. */
      "/tiles": { target: backend, changeOrigin: false },
      "/world.json": { target: backend, changeOrigin: false },
      // The worker's two wasm modules -- the KDF and the map core -- are
      // embedded in the backend rather than public/, so in dev they come from
      // the last `make ui` and can lag wasm/*.wasm. Rerun it after
      // `make sync-wasm`, or the browser keeps using the old module.
      "/argon2.wasm": backend,
      "/core.wasm": backend,
    },
  },
  // `vite preview` defaults to 4173, the same story as 5173. It proxies
  // nothing: a preview checks what the build produced, and the built app is
  // served by the OCaml binary.
  preview: {
    port: uiPort + 1,
    strictPort: true,
  },
});
