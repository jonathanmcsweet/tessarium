import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The dev server proxies to the OCaml server so that `npm run dev` and the
// built app see the same origin layout. Without this the basemap would be
// cross-origin in development and same-origin in production, which is exactly
// the kind of difference that only shows up after a release.
const backend = process.env.TESSARIUM_SERVER ?? "http://127.0.0.1:7373";

export default defineConfig({
  plugins: [react()],
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
    },
  },
});
