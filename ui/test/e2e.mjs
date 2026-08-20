/* End-to-end check of the built UI against the built server.

   This is the test for the claim the whole project rests on: enter a phrase,
   click a square, get its address. It runs the real browser against the real
   binary, because the parts that break here -- Web Worker startup, the
   Content-Security-Policy, js_of_ocaml's export target in a worker -- are all
   things that look fine in a unit test and fail in a page.

   The addresses it expects come from `vectors/vectors.json`, so a UI that
   renders beautifully and computes the wrong answer still fails. */

import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { chromium } from "playwright";

const base = process.argv[2] ?? "http://127.0.0.1:7373";
const vectors = JSON.parse(
  readFileSync(new URL("../../vectors/vectors.json", import.meta.url), "utf8"),
);

let checks = 0;
let failures = 0;
const check = (name, ok) => {
  checks++;
  if (!ok) {
    failures++;
    console.log(`  FAIL  ${name}`);
  }
};

const mnemonic = vectors.key_derivation[0].mnemonic;
/* A vector whose address we can predict: same phrase, known point. */
const sample =
  vectors.addresses.find((a) => a.mnemonic === vectors.key_derivation[0].name)
    ?? vectors.addresses[0];
const sampleMnemonic =
  vectors.key_derivation.find((k) => k.name === sample.mnemonic)?.mnemonic
    ?? mnemonic;
const sampleLat = sample.lat_ns / 1e9;
const sampleLon = sample.lon_ns / 1e9;

/* A deliberately slow view of the fixture server.

   One test needs to cancel a download halfway, and against a local fixture
   there is normally no halfway to catch: the archive shares one tile blob,
   the reader fetches a megabyte at a time, and a whole region arrives in
   about three requests and under half a second -- measured. So the cancel
   server reads through this instead, which forwards every range request
   after a pause. Paired with map-slow.pmtiles, whose tiles each sit in
   their own 64 KiB slot so a read cannot be coalesced away, a download
   becomes seconds long and cancelling it is deliberate rather than lucky. */
const PROXY_DELAY_MS = 300;
const fixtureBase = process.env.E2E_FIXTURE ?? "http://127.0.0.1:7374";
const proxyPort = Number(process.env.E2E_PROXY_PORT ?? 7378);
const slowProxy = createServer((req, res) => {
  const headers = req.headers.range ? { range: req.headers.range } : {};
  fetch(`${fixtureBase}${req.url}`, { method: req.method, headers })
    .then(async (upstream) => {
      const body = Buffer.from(await upstream.arrayBuffer());
      await new Promise((done) => setTimeout(done, PROXY_DELAY_MS));
      const pass = {};
      for (const h of ["content-type", "content-range", "accept-ranges"]) {
        const v = upstream.headers.get(h);
        if (v) pass[h] = v;
      }
      res.writeHead(upstream.status, {
        ...pass,
        "content-length": body.length,
      });
      res.end(req.method === "HEAD" ? undefined : body);
    })
    .catch(() => {
      res.writeHead(502);
      res.end();
    });
});
await new Promise((listening) =>
  slowProxy.listen(proxyPort, "127.0.0.1", listening)
);

const browser = await chromium.launch();
const context = await browser.newContext({
  viewport: { width: 1280, height: 900 },
  /* The copy button is checked by reading the clipboard back, which Chromium
     gates behind both permissions. */
  permissions: ["clipboard-read", "clipboard-write"],
});
const page = await context.newPage();

/* Anything the browser refuses is a real failure here: a CSP violation, a
   worker that will not start, a script that 404s. Collect them rather than
   letting the test pass around them. */
const problems = [];

/* Missing basemap assets are expected until a .pmtiles has been fetched, and
   the UI reports that itself. Everything else is a real failure. */
const expected = (url) => url.includes("/basemap/");

/* Flipped once the in-app download completes. Before that, MapLibre reports
   the missing archive and sprites through its own console errors; after it,
   the same messages would mean the downloaded tiles are bad, which is
   exactly what this suite must fail on. */
let basemapReady = false;

page.on("console", (msg) => {
  if (msg.type() !== "error") return;
  const text = msg.text();
  /* A failed resource is already recorded from the response, with its URL
     attached; the console version has none and is pure noise. */
  if (text.includes("Failed to load resource")) return;
  if (
    !basemapReady
    && (text.includes("/basemap/") || text.includes("Bad response code"))
  ) return;
  problems.push(`console: ${text}`);
});
page.on("pageerror", (err) => problems.push(`pageerror: ${err.message}`));
page.on("requestfailed", (req) => {
  /* MapLibre aborts its own in-flight tile requests whenever a tile leaves
     the view or the style swaps; the client cancelling itself is not a
     failure. Anything else that dies on /tiles/ still is. */
  if (
    req.url().includes("/tiles/")
    && req.failure()?.errorText === "net::ERR_ABORTED"
  ) {
    return;
  }
  if (!expected(req.url())) {
    problems.push(`requestfailed: ${req.url()} ${req.failure()?.errorText}`);
  }
});
page.on("response", (res) => {
  if (res.status() >= 400 && !expected(res.url())) {
    problems.push(`http ${res.status()}: ${res.url()}`);
  }
});

await page.goto(base, { waitUntil: "networkidle" });

check(
  "gate renders",
  (await page.locator("h1").textContent()) === "Tessarium",
);

/* The 4.4 MB core has to load inside the worker before validation replies.
   If js_of_ocaml exported to the wrong global, this is where it hangs. */
await page.locator("#phrase").fill("abandon abandon abandon");
await page.waitForFunction(
  () =>
    document.querySelector(".phrase-status")?.textContent?.includes(
      "expected 24 words",
    ),
  { timeout: 30_000 },
);
check(
  "short phrase is rejected",
  (await page.locator(".phrase-status").textContent()).includes(
    "expected 24 words",
  ),
);

/* One wrong word must fail the checksum rather than silently producing a
   different map. This is the check that catches a typo. */
const words = sampleMnemonic.split(" ");
const typo = [...words];
typo[5] = typo[5] === "zoo" ? "zone" : "zoo";
await page.locator("#phrase").fill(typo.join(" "));
await page.waitForFunction(
  () => {
    const t = document.querySelector(".phrase-status")?.textContent ?? "";
    return t.includes("24/24")
      && (t.includes("checksum failed") || t.includes("checksum valid"));
  },
  { timeout: 30_000 },
);
check(
  "checksum catches a single wrong word",
  (await page.locator(".phrase-status").textContent()).includes(
    "checksum failed",
  ),
);

/* "Generate one for me" must produce a phrase this same application accepts.
   A generator whose output fails its own checksum would strand a user who had
   already written 24 words down. Two presses must also differ -- a generator
   wired to a constant would pass every other check here. */
/* Wait for the value to CHANGE, not merely to be 24 words: the typo phrase
   above is already 24 words, so a length check is satisfied before the click
   has done anything and leaves a request in flight to land later and
   overwrite whatever the test does next. */
const beforeGenerate = await page.locator("#phrase").inputValue();
await page.locator(".generate button").click();
await page.waitForFunction(
  (previous) => document.querySelector("#phrase")?.value !== previous,
  beforeGenerate,
  { timeout: 30_000 },
);
const firstGenerated = await page.locator("#phrase").inputValue();
check(
  "a generated phrase is 24 words",
  firstGenerated.split(/\s+/).filter(Boolean).length === 24,
);
await page.waitForSelector(".valid", { timeout: 30_000 });
check("a generated phrase is 24 words and passes its checksum", true);
check(
  "a generated phrase is all real BIP-39 words",
  (await page.locator(".phrase-status").count()) > 0
    && (await page.locator(".phrase-status").textContent()).includes("24/24"),
);
check(
  "the write-it-down warning appears",
  (await page.locator(".warning").allTextContents()).some((t) =>
    t.includes("Write these 24 words down")
  ),
);
await page.locator(".generate button").click();
await page.waitForFunction(
  (previous) => document.querySelector("#phrase")?.value !== previous,
  firstGenerated,
  { timeout: 30_000 },
);
check(
  "generating twice gives two different phrases",
  (await page.locator("#phrase").inputValue()) !== firstGenerated,
);

await page.locator("#phrase").fill(sampleMnemonic);
/* Waiting on `.valid` alone would return at once: the generated phrase was
   valid too, so the marker never went away. Wait for the field to hold what
   this test just put in it -- the render that does that is the same render
   that drops the write-it-down notice. */
await page.waitForFunction(
  (want) => document.querySelector("#phrase")?.value === want,
  sampleMnemonic,
  { timeout: 30_000 },
);
await page.waitForSelector(".valid", { timeout: 30_000 });
check("valid phrase reports a valid checksum", true);
check(
  "editing the phrase drops the write-it-down warning",
  !(await page.locator(".warning").allTextContents()).some((t) =>
    t.includes("Write these 24 words down")
  ),
);

await page.locator("button[type=submit]").click();

/* The Argon2id derivation runs here. Generous, because a cold worker on a
   loaded machine is slower than the number anyone quotes. */
await page.waitForSelector(".map-wrap", { timeout: 60_000 });
check("map opens after derivation", true);
check(
  "phrase is not left in the DOM",
  !(await page.content()).includes(`${words[0]} ${words[1]}`),
);

/* Nothing may have been persisted. This is a stated guarantee of the design,
   so it is asserted rather than assumed. */
const persisted = await page.evaluate(() => ({
  local: JSON.stringify(window.localStorage),
  session: JSON.stringify(window.sessionStorage),
  cookie: document.cookie,
  url: window.location.href,
}));
check("nothing in localStorage", persisted.local === "{}");
check("nothing in sessionStorage", persisted.session === "{}");
check("no cookies", persisted.cookie === "");
check("phrase not in the URL", !persisted.url.includes(words[0]));

/* The core is reachable only through the worker. Asserting the key is not on
   the main thread is the point of putting it there. */
const keyOnMainThread = await page.evaluate(
  () => typeof globalThis.tessarium !== "undefined",
);
check("core is not loaded on the main thread", !keyOnMainThread);

/* A freshly spawned worker has no key. That is what confining the key to one
   worker actually buys, so it is asserted rather than assumed. */
const strangerWorker = await page.evaluate(
  async ([lat, lon]) => {
    const worker = new Worker("/core.worker.js");
    return await new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error("worker timeout")),
        60000,
      );
      worker.onmessage = (e) => {
        clearTimeout(timer);
        resolve(e.data);
      };
      worker.postMessage({ id: 1, op: "encode", payload: { lat, lon } });
    });
  },
  [sampleLat, sampleLon],
);
check("a second worker has no key", strangerWorker?.error === "locked");

/* There must be no way to ask for every address in a viewport at once. One
   existed, to write an address inside each square; it was removed because a
   screenshot of a labelled grid hands over fifty (address, real place) pairs
   from a user who thought they were sharing a picture of a street, and each
   such pair is material for searching out their phrase. */
const bulk = await page.evaluate(async () => {
  const worker = new Worker("/core.worker.js");
  return await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("worker timeout")), 60000);
    worker.onmessage = (e) => {
      clearTimeout(timer);
      resolve(e.data);
    };
    worker.postMessage({
      id: 1,
      op: "gridWithAddresses",
      payload: {
        latLo: 51.5,
        lonLo: -0.13,
        latHi: 51.501,
        lonHi: -0.129,
        limit: 100,
      },
    });
  });
});
check(
  "there is no bulk address operation",
  typeof bulk?.error === "string" && bulk.error.includes("unknown op"),
);

/* ---------------------- the in-app region downloader ----------------------

   The server under test was started with an EMPTY basemap directory and its
   download source pointed at a second instance of this same server, which
   serves a generated fixture archive. So this drives the whole pipeline with
   no external network: the missing-basemap banner, the world-map-first offer,
   the estimate, our Range client against our own Range server, the extract,
   the assets tarball, the style swap without a page reload -- and then a
   SECOND download that must MERGE detail into the archive rather than
   replace it, which is what makes "world first, then detail" usable at all.

   The repeated status polls over one keep-alive connection are also the
   regression test for a real bug: a poll whose declared body was not drained
   left its bytes in the connection, and every later request on it failed. */

check(
  "the missing basemap is reported in a banner",
  (await page.locator(".banner").count()) === 1,
);
const bannerAction = page.locator(".banner-action");
check(
  "the banner offers a download action",
  (await bannerAction.count()) === 1,
);

const postJson = async (endpoint, body) =>
  await fetch(`${base}/api/${endpoint}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body ?? {}),
  });

/* Tiles are served through /tiles across the archives, and a tile nobody
   holds is a quiet 204 -- past the coverage edge the map must render
   nothing, not log an error per pan. */
check(
  "a tile with no archive behind it is 204, not an error",
  (await fetch(`${base}/tiles/0/0/0.mvt`)).status === 204,
);
check(
  "a malformed tile path is 404",
  (await fetch(`${base}/tiles/3/8/0.mvt`)).status === 404
    && (await fetch(`${base}/tiles/3/04/0.mvt`)).status === 404,
);

const idleStatus = await (await postJson("basemap-status")).json();
check(
  "the download job starts idle at generation zero",
  idleStatus.generation === 0 && idleStatus.job?.state === "idle",
);
const reversed = await postJson("basemap-estimate", {
  regions: [{ min_lon: 1, min_lat: 0, max_lon: 0, max_lat: 1, max_zoom: 15 }],
});
check("a reversed box is refused with a 400", reversed.status === 400);
const bare = await postJson("basemap-estimate", {
  min_lon: 0,
  min_lat: 0,
  max_lon: 1,
  max_lat: 1,
  max_zoom: 15,
});
check("a bare box without the regions wrapper is refused", bare.status === 400);

/* Polygon clipping, end to end: the same box estimated whole and clipped to
   a triangle covering only part of it must shrink, not vanish. The fixture
   holds London (-0.20..-0.05, 51.46..51.56); the triangle covers its west. */
const londonBox = {
  min_lon: -0.25,
  min_lat: 51.44,
  max_lon: 0.0,
  max_lat: 51.58,
  max_zoom: 15,
};
const wholeEst = await (await postJson("basemap-estimate", {
  regions: [londonBox],
})).json();
const clipEst = await (await postJson("basemap-estimate", {
  regions: [{
    ...londonBox,
    polygon: [[[-0.21, 51.45], [-0.13, 51.45], [-0.17, 51.57]]],
  }],
})).json();
check(
  "a polygon clips the plan to fewer tiles",
  clipEst.tiles > 0 && wholeEst.tiles > clipEst.tiles,
);

/* Wait until the named download completes, by generation: a tiny fixture
   download can run start-to-done entirely between two UI polls, and the
   generation in the status envelope is exactly what makes that visible. */
const awaitDone = async (generation) => {
  for (let i = 0; i < 120; i++) {
    const status = await (await postJson("basemap-status")).json();
    if (status.generation === generation && status.job?.state === "done") {
      return true;
    }
    if (status.job?.state === "failed") {
      console.log(`  download failed: ${status.job.reason}`);
      return false;
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  return false;
};

/* With nothing on disk, the card leads with the world map. */
await bannerAction.click();
await page.waitForSelector(".download-card", { timeout: 10_000 });
check("the download card opens from the banner", true);
const worldButton = page.locator(".download-world button");
await worldButton.waitFor({ state: "visible", timeout: 10_000 });
check("an empty basemap leads with the world map offer", true);
await page.waitForFunction(
  () => !document.querySelector(".download-world button")?.disabled,
  { timeout: 30_000 },
);
await worldButton.click();
check("the world download completes at generation one", await awaitDone(1));
await page.waitForFunction(
  () =>
    [...document.querySelectorAll("[data-sonner-toast]")].some((t) =>
      (t.textContent ?? "").includes("Maps downloaded")
    ),
  { timeout: 30_000 },
);
check("the download completes with a toast", true);
check(
  "and the toast carries a close button for keyboard users",
  (await page.locator("[data-sonner-toast] [data-close-button]").count()) >= 1,
);
await page.waitForFunction(() => !document.querySelector(".banner"), {
  timeout: 10_000,
});
check("the banner clears once maps exist", true);
await page.waitForFunction(() => !document.querySelector(".download-card"), {
  timeout: 10_000,
});
check("the card closes itself", true);

/* The grid overlay must survive the style swap that follows a completed
   download -- checked after the FIRST download, deliberately. It once did
   not: when MapLibre's style diff succeeds it fires style.load
   synchronously inside the setStyle call, and a listener registered after
   the call has already missed it, so the overlay was never re-added. Each
   missed listener stayed armed and repaired the NEXT swap, which made the
   loss invisible after a second download and total after a single one --
   the real-world case. */
const overlayAlive = await page.evaluate(() => {
  const map = window.__tessarium_map;
  return !!(map?.getSource("grid") && map.getLayer("grid-lines")
    && map.getSource("selection") && map.getLayer("selection-outline"));
});
check("the grid overlay survives the download's style swap", overlayAlive);
const gridRefilled = await page
  .waitForFunction(
    () =>
      (window.__tessarium_map?.querySourceFeatures("grid").length ?? 0) > 0,
    { timeout: 30_000 },
  )
  .then(() => true, () => false);
check("and the grid refills after the swap", gridRefilled);

/* The archive holds the world at z6 and the map sits at street zoom, so
   everything on screen is overzoomed -- and MapLibre only overzooms past
   the SOURCE's stated maxzoom. The source must therefore carry the archive
   header's depth, not a hardcoded number: a source pinned at 15 requested
   z15 tiles nobody held and rendered a blank basemap over data the archive
   had. (The fixture's tiles carry no styled layers, so this is asserted on
   the source itself rather than on rendered features.) */
const sourceDepth = await page
  .waitForFunction(
    () => window.__tessarium_map?.getSource("protomaps")?.maxzoom === 6,
    { timeout: 30_000 },
  )
  .then(() => true, () => false);
check("the map source takes its depth from the archive header", sourceDepth);

/* From here on, basemap errors are real: the tiles on disk came from the
   fixture and MapLibre must parse every one of them cleanly. */
basemapReady = true;

check(
  "the downloaded archive is served",
  (await fetch(`${base}/basemap/map.pmtiles`, { method: "HEAD" })).status
    === 200,
);
const worldTile = await fetch(`${base}/tiles/0/0/0.mvt`);
check(
  "the world tile serves through the tile endpoint after the download",
  worldTile.status === 200
    && worldTile.headers.get("content-encoding") === "gzip"
    && (await worldTile.arrayBuffer()).byteLength > 0,
);
const tilejson = await (await fetch(`${base}/tiles.json`)).json();
check(
  "tiles.json states the archive's real depth and bounds",
  tilejson.maxzoom === 6 && tilejson.minzoom === 0
    && Array.isArray(tilejson.bounds) && tilejson.bounds.length === 4,
);
check(
  "the sprite sheet arrived via the assets tarball",
  (await fetch(`${base}/basemap/sprites/v4/light.json`)).status === 200,
);
check(
  "still unlocked after the style swap -- no reload happened",
  (await page.locator(".panel").count()) === 1,
);

/* Second download: detail for the current view, MERGED over the world map.
   The card must no longer offer the world, and afterwards every tile from
   both downloads has to be in one archive. */
const openButton = page.locator(".map-actions .icon-button");
check(
  "the map carries its own download button",
  (await openButton.count()) === 1,
);
await openButton.click();
await page.waitForSelector(".download-card", { timeout: 10_000 });
check(
  "with maps on disk the world offer is gone",
  (await page.locator(".download-world").count()) === 0,
);
const viewButton = page.locator(".download-view button");
await page.waitForFunction(
  () => !document.querySelector(".download-view button")?.disabled,
  { timeout: 30_000 },
);
await viewButton.click();
check("the view download completes at generation two", await awaitDone(2));
await page.waitForFunction(() => !document.querySelector(".download-card"), {
  timeout: 10_000,
});

/* The loading bar, on real traffic, deterministically: wait for quiet,
   delay every tile past the tracker's 300 ms threshold, then tell the
   vector source to reload its tiles (same URLs plus a marker param --
   the app-visible way to force refetches without racing a download's
   style swap, which flaked). The bar must appear while tiles drip in
   and vanish at idle. */
await page.waitForFunction(() => !document.querySelector(".map-loading"), {
  timeout: 60_000,
});
await page.route("**/tiles/**", async (route) => {
  await new Promise((done) => setTimeout(done, 500));
  try {
    await route.continue();
  } catch {
    /* The request died mid-delay: MapLibre aborts tiles that leave the
       view, and unroute below can beat a sleeping handler to its route.
       Either way there is nothing left to slow down. */
  }
});
const barSeen = page
  .waitForSelector(".map-loading", { timeout: 30_000 })
  .then(() => true, () => false);
await page.evaluate(() => {
  const src = window.__tessarium_map.getSource("protomaps");
  src.setTiles(src.tiles.map((u) => `${u}&e2e_bar=1`));
});
check("slow tiles raise the loading bar", await barSeen);
check(
  "the bar names itself for the screen reader",
  await page.evaluate(() =>
    (document.querySelector(".map-loading")?.getAttribute("aria-label") ?? "")
        .length > 0
    /* Already gone means the drip finished; barSeen vouched it was up. */
    || document.querySelector(".map-loading") === null
  ),
);
await page.unroute("**/tiles/**");
await page.waitForFunction(() => !document.querySelector(".map-loading"), {
  timeout: 60_000,
});
check("the bar hides once the map settles", true);

/* Merged, not replaced: bytes 100-101 of a PMTiles header are its min and
   max zoom, and only the union of both downloads spans 0 to 15. */
const zoomBytes = await fetch(`${base}/basemap/map.pmtiles`, {
  headers: { range: "bytes=100-101" },
});
const zooms = new Uint8Array(await zoomBytes.arrayBuffer());
check(
  `the merged archive spans zoom 0 to 15 (got ${zooms[0]}-${zooms[1]})`,
  zooms[0] === 0 && zooms[1] === 15,
);
check(
  "tiles.json follows the archive's growth",
  (await (await fetch(`${base}/tiles.json`)).json()).maxzoom === 15,
);

/* Asking again for what is already on disk: the estimate must say "you have
   this" rather than re-quoting the price, and the download stays disabled. */
await openButton.click();
await page.waitForSelector(".download-card", { timeout: 10_000 });
await page.waitForFunction(
  () =>
    (document.querySelector(".download-view .hint")?.textContent ?? "")
      .includes("You already have"),
  { timeout: 30_000 },
);
check("re-asking for a held area says so instead of re-quoting", true);
check(
  "and its button turns into the record-only offer",
  !(await page.locator(".download-view button").isDisabled())
    && ((await page.locator(".download-view button").textContent()) ?? "")
      .includes("Keep track"),
);

/* Third download: places picked by name from the tree -- and several at
   once, riding in ONE download. The fixture's tiles sit inside the United
   Kingdom's box, so picking the UK estimates real bytes; adding the city of
   London on top must NOT change the price, because the server dedups
   overlapping picks by tile id. The country name comes from
   Intl.DisplayNames, so this also pins the catalogue's ISO codes to
   something the browser recognises. */
await page.locator("#region-filter").fill("United Kingdom");
const ukEntry = page
  .locator(".region-tree details")
  .filter({ hasText: "United Kingdom" });
await ukEntry
  .locator(".region-check")
  .filter({ hasText: "The whole country" })
  .locator("input")
  .check();
await page.waitForFunction(
  () => !document.querySelector(".download-region-offer button")?.disabled,
  { timeout: 30_000 },
);
check("picking a country by name yields a real estimate", true);
const priceOf = async () => {
  const hint = await page
    .locator(".download-region-offer .hint")
    .first()
    .textContent();
  return (hint?.match(/About (.+) in total/) ?? [])[1] ?? "";
};
const ukAlone = await priceOf();
check("the selection names its price", ukAlone !== "");
await ukEntry
  .locator(".region-check")
  .filter({ hasText: "London" })
  .locator("input")
  .check();
await page.waitForFunction(
  () =>
    (document.querySelector(".download-region-offer .hint")?.textContent ?? "")
      .includes("Places selected: 2"),
  { timeout: 30_000 },
);
check(
  "a city inside a picked country adds nothing to the price",
  (await priceOf()) === ukAlone,
);
await page.locator(".download-region-offer button").click();
check(
  "the two-place download completes at generation three",
  await awaitDone(3),
);
await page.waitForFunction(() => !document.querySelector(".download-card"), {
  timeout: 10_000,
});

/* And a federation exposes its states and cities as checkboxes: the United
   States entry must offer more than forty states, plus named cities. */
await openButton.click();
await page.waitForSelector(".download-card", { timeout: 10_000 });
await page.locator("#region-filter").fill("United States");
const usEntry = page
  .locator(".region-tree details")
  .filter({ hasText: "United States" });
check(
  "a federation exposes its states",
  (await usEntry.locator(".region-check").count()) > 40,
);
check(
  "and its cities",
  (await usEntry.locator(".region-check").filter({ hasText: "Chicago" })
    .count()) === 1,
);

/* Fiji straddles the antimeridian, so its whole-country pick is TWO boxes
   sharing one border polygon. (Not Russia: its clipped land now genuinely
   affords full depth, and honestly planning it takes minutes -- the fixture
   deserves the small antimeridian country.) Its only fixture tile is the
   world-spanning z0, already on disk from the world download, so the honest
   answer -- and the assertion -- is "covered": the two-box polygon request
   survived validation, planning and the merge arithmetic end to end. */
await page.locator("#region-filter").fill("Fiji");
await page
  .locator(".region-tree details")
  .filter({ hasText: "Fiji" })
  .locator(".region-check")
  .filter({ hasText: "The whole country" })
  .locator("input")
  .check();
await page.waitForFunction(
  () =>
    (document.querySelector(".download-region-offer .hint")?.textContent ?? "")
      .includes("already have"),
  { timeout: 30_000 },
);
check("a two-box antimeridian country estimates cleanly", true);
await page.locator(".download-card .icon-button").click();
await page.waitForFunction(() => !document.querySelector(".download-card"), {
  timeout: 10_000,
});

/* ----------------------------- place search --------------------------------

   The downloaded region carries its own names, and searching them must never
   leave the machine. Driven through the real box, because the claim is that a
   person can type a place and land on it. */
const searched = await (await postJson("basemap-search", { q: "fixtu" }))
  .json();
check(
  "the index built from the download finds a place in it",
  searched.results?.[0]?.name === "Fixtureville"
    && searched.results[0].layer === "places",
);
/* The coordinates have to be real, not merely present: a swapped axis or a
   dropped projection still returns a row, and the fixture's tiles are
   identical everywhere, so only a bounds check catches it. */
check(
  "and places it somewhere on Earth",
  Math.abs(searched.results[0].lon) <= 180
    && Math.abs(searched.results[0].lat) <= 85.06,
);
/* limit is the server's to enforce, and the scan stops early because of it. */
const limited =
  await (await postJson("basemap-search", { q: "fixtu", limit: 3 }))
    .json();
check("the result limit is honoured", limited.results?.length === 3);
check(
  "a limit outside 1..50 falls back to the default rather than being obeyed",
  (await (await postJson("basemap-search", { q: "fixtu", limit: 9999 })).json())
    .results?.length <= 10,
);
check(
  "a one-character query is refused rather than scanned",
  (await (await postJson("basemap-search", { q: "f" })).json()).results
    ?.length === 0,
);
check(
  "and carries what ranks it",
  searched.results[0].weight === 4242
    && searched.results[0].kind === "locality",
);
const searchedFolded =
  await (await postJson("basemap-search", { q: "FIXTUREVILLE" }))
    .json();
check(
  "case does not decide whether a place can be found",
  searchedFolded.results?.[0]?.name === "Fixtureville",
);
check(
  "a name that is not there returns nothing rather than everything",
  (await (await postJson("basemap-search", { q: "zzzznowhere" })).json())
    .results?.length === 0,
);
check(
  "an empty query is refused",
  (await postJson("basemap-search", { q: "" })).status === 400,
);

/* A place named the way people name places. "Fixtureville, ZZ" appears
   inside no name in any archive, and matching the query as one run of
   characters answered it with nothing found -- so being more specific made
   the search worse.

   The fixture holds one distinct name, so these prove the query SHAPE is
   accepted and nothing about ranking between names; the ordering rules are
   pinned in the server suite, where the corpus is written by the test. */
check(
  "a place named with a qualifier after a comma is still found",
  (await (await postJson("basemap-search", { q: "Fixtureville, ZZ" })).json())
    .results?.[0]?.name === "Fixtureville",
);
check(
  "and so is one named with a comma and nothing after it",
  (await (await postJson("basemap-search", { q: "Fixtureville," })).json())
    .results?.[0]?.name === "Fixtureville",
);
check(
  "a name given as separate words is found as well",
  (await (await postJson("basemap-search", { q: "fixture ville" })).json())
    .results?.[0]?.name === "Fixtureville",
);

/* Through the UI: type, pick the first result, and the map should move. */
const beforeSearch = await page.evaluate(() => {
  const map = window.__tessarium_map;
  return map ? [map.getCenter().lng, map.getCenter().lat] : null;
});
await page.locator("#place-search-input").fill("fixtu");
const offered = await page
  .waitForSelector(".place-option", { timeout: 10_000 })
  .then(() => true, () => false);
check("typing a place name offers it", offered);
/* The row must say where it goes, not just that it exists: the kind
   always, and -- whenever the map is not already there -- how far. The
   containment context depends on where the fixture pretends to be, so
   only the parts that are true everywhere are pinned here; the
   catalogue containment itself is unit-tested against real borders. */
const optionText = await page.locator(".place-option").first().textContent();
check("the result names its kind", /locality/.test(optionText ?? ""));
const farFromResult = beforeSearch
  && (Math.abs(searched.results[0].lon - beforeSearch[0]) > 0.05
    || Math.abs(searched.results[0].lat - beforeSearch[1]) > 0.05);
check(
  "and, from elsewhere, how far away it is",
  !farFromResult || /km/.test(optionText ?? ""),
);
await page.locator(".place-option").first().click();
/* Waited for rather than slept through: flying across the world takes as
   long as the distance says, and a fixed pause is a race either way. */
const flew = await page
  .waitForFunction(
    (from) => {
      const map = window.__tessarium_map;
      if (!map) return false;
      const c = map.getCenter();
      return Math.abs(c.lng - from[0]) > 0.0001
        || Math.abs(c.lat - from[1]) > 0.0001;
    },
    beforeSearch,
    { timeout: 15_000 },
  )
  .then(() => true, () => false);
check("choosing a result flies the map to it", flew);
/* The list must close on Escape, or a keyboard user is trapped in it. */
await page.locator("#place-search-input").fill("fixtu");
await page.waitForSelector(".place-option", { timeout: 10_000 });
await page.locator("#place-search-input").press("Escape");
check(
  "escape closes the result list",
  (await page.locator(".place-option").count()) === 0,
);

/* ------------------------------ coverage edge ------------------------------

   Where the basemap stops, said out loud instead of left as a blank screen.

   The claim under test is not that something grey appears -- it is that the
   grey lands exactly where the tile endpoint has nothing. So the mask is
   checked against the tiles themselves, cell by cell, rather than against
   the code that drew it: those two agreeing is the whole feature, and a
   mask that greys out ground the map is drawing would be worse than no
   mask at all. */
const straddle = {
  min_lon: -0.1,
  min_lat: 51.46,
  max_lon: 0.3,
  max_lat: 51.56,
  zoom: 12,
};
const cover = await (await postJson("basemap-coverage", straddle)).json();
check(
  "a viewport straddling the downloaded edge is partly covered",
  cover.present.includes("1") && cover.present.includes("0"),
);
check(
  "the answer is one character per tile of the rectangle it names",
  cover.present.length === cover.w * cover.h,
);

let agreed = true;
for (let row = 0; row < cover.h; row++) {
  for (let col = 0; col < cover.w; col++) {
    const res = await fetch(
      `${base}/tiles/${cover.zoom}/${cover.x + col}/${cover.y + row}.mvt`,
    );
    await res.arrayBuffer();
    const served = res.status === 200;
    if (served !== (cover.present[row * cover.w + col] === "1")) agreed = false;
  }
}
check("the mask agrees with the tile endpoint, cell for cell", agreed);

/* The other side of the world: nothing at street level, but the world
   overview underneath is still real, which is why the note there offers
   zooming out rather than claiming there is nothing at all. */
const antipode = await (await postJson("basemap-coverage", {
  min_lon: 139.6,
  min_lat: 35.6,
  max_lon: 139.8,
  max_lat: 35.8,
  zoom: 12,
})).json();
check(
  "a view nothing was downloaded near is blank at street zoom",
  !antipode.present.includes("1"),
);
check(
  "and the overview beneath it is reported as a depth",
  antipode.depth >= 0 && antipode.depth < 12,
);
check(
  "a query far larger than a viewport is refused rather than answered slowly",
  (await postJson("basemap-coverage", {
    min_lon: -10,
    min_lat: 40,
    max_lon: 10,
    max_lat: 55,
    zoom: 12,
  })).status === 400,
);

/* Through the map itself. Jumped rather than flown: the assertion is about
   what the app says once it has settled, and an animation only decides
   when that is. */
await page.evaluate(() =>
  window.__tessarium_map?.jumpTo({ center: [139.7, 35.68], zoom: 12 })
);
check(
  "panning off the downloaded region says so",
  await page.waitForSelector(".map-note.action", { timeout: 15_000 })
    .then(() => true, () => false),
);
check(
  "the blank ground is actually painted, not just described",
  await page.waitForFunction(
    () => {
      const map = window.__tessarium_map;
      return !!map
        && map.queryRenderedFeatures({ layers: ["coverage-blank"] }).length > 0;
    },
    undefined,
    { timeout: 15_000 },
  ).then(() => true, () => false),
);
/* The note is the one place on the map that offers the way out of a blank
   screen, so its button has to reach the downloader. */
await page.locator(".map-note.action .note-action").click();
check(
  "the note offers the download card",
  await page.waitForSelector(".download-card", { timeout: 10_000 })
    .then(() => true, () => false),
);
await page.locator(".map-actions button").click();
await page.waitForFunction(() => !document.querySelector(".download-card"), {
  timeout: 10_000,
});

/* An answer that arrives late must not paint over a newer one.

   React Query hands back a cached view in a microtask while a fresh
   request is still in flight, so returning to a place you left seconds ago
   resolves BEFORE the place you passed through. The older answer then
   landed last and won, which cleared the wash and the note while the
   camera sat on blank ground -- the app saying nothing at all, which is
   the state this feature exists to replace. Delayed here on purpose, but
   the ordering needs no help in the field. */
await page.route("**/api/basemap-coverage", async (route) => {
  await new Promise((done) => setTimeout(done, 2000));
  await route.continue();
});
await page.evaluate(() =>
  window.__tessarium_map?.jumpTo({ center: [139.7, 35.68], zoom: 12 })
);
await page.waitForSelector(".map-note.action", { timeout: 20_000 });
/* Out to covered ground, whose answer is now 2 s away. The pause is what
   makes this a race at all: two jumps back to back settle as one move, so
   the request being outrun would never be sent. */
await page.evaluate(() =>
  window.__tessarium_map?.jumpTo({ center: [-0.12, 51.5], zoom: 12 })
);
await new Promise((done) => setTimeout(done, 700));
/* And straight back, where the answer is already cached and returns at
   once -- so the older question is still in flight behind it. */
await page.evaluate(() =>
  window.__tessarium_map?.jumpTo({ center: [139.7, 35.68], zoom: 12 })
);
await new Promise((done) => setTimeout(done, 4000));
check(
  "an answer for a view already left cannot wipe the current one",
  await page.locator(".map-note.action").count() === 1,
);
await page.unroute("**/api/basemap-coverage");

/* Focused first: the note goes away on its own when tiles land or a
   fly-to settles, and if its button still had focus the page would drop
   to <body>, where the keyboard does nothing at all. */
await page.locator(".map-note.action .note-action").focus();
await page.evaluate(() =>
  window.__tessarium_map?.jumpTo({ center: [-0.12, 51.5], zoom: 12 })
);
check(
  "returning to downloaded ground takes the note away again",
  await page.waitForFunction(
    () => !document.querySelector(".map-note.action"),
    undefined,
    { timeout: 15_000 },
  ).then(() => true, () => false),
);
check(
  "and hands the keyboard back to the map rather than dropping it",
  await page.evaluate(() =>
    document.activeElement?.classList.contains("maplibregl-canvas") ?? false
  ),
);

/* ------------------------- the download ledger ----------------------------

   Every download above was recorded inside the archive itself -- name,
   date, size -- and the list, the reminder setting, and Remove are all
   driven through the real card. First, adoption: covered tiles with no
   entry (here, a patch inside the world download; in the field, an archive
   from before the ledger existed) are claimed by re-requesting them, and
   the entry lands with "age unknown", which counts as stale. */
await postJson("basemap-download", {
  name: "Adopted patch",
  regions: [{
    min_lon: -0.2,
    min_lat: 51.46,
    max_lon: -0.1,
    max_lat: 51.5,
    max_zoom: 6,
  }],
});
check(
  "re-requesting covered tiles records them instead of failing",
  await awaitDone(4),
);
const ledger1 = await (await postJson("basemap-ledger")).json();
check(
  "the archive records every download by name",
  ledger1.entries?.length === 4
    && [
      "World overview",
      "Map view",
      "United Kingdom and London",
      "Adopted patch",
    ]
      .every((n) => ledger1.entries.some((e) => e.name === n)),
);
const adoptedEntry = ledger1.entries?.find((e) => e.name === "Adopted patch");
check(
  "adopted tiles admit their age is unknown",
  adoptedEntry?.completed === 0 && adoptedEntry?.bytes === 0,
);
check(
  "real downloads record when and how much",
  ledger1.entries?.filter((e) => e.completed > 0 && e.bytes > 0).length === 3,
);

await openButton.click();
await page.waitForSelector(".download-ledger", { timeout: 10_000 });
/* The list refetches on mount; wait for the adoption to be visible rather
   than racing the request. */
const fourRows = await page
  .waitForFunction(
    () => document.querySelectorAll(".ledger-row").length === 4,
    { timeout: 30_000 },
  )
  .then(() => true, () => false);
check("the card lists the downloaded maps", fourRows);
check(
  "only the age-unknown entry is flagged for update",
  (await page.locator(".ledger-stale").count()) === 1
    && (await page.locator(".ledger-row").filter({ hasText: "Adopted patch" })
        .locator(".ledger-stale").count()) === 1,
);
check(
  "a fresh download names its date",
  ((await page.locator(".ledger-row").filter({ hasText: "World overview" })
    .locator(".hint").textContent()) ?? "").includes("updated"),
);

/* The reminder threshold lives on the server, next to the archive it
   describes -- localStorage stays empty, as asserted at the end -- so the
   choice must survive closing the card. */
const reminder = page.locator(".ledger-reminder select");
check(
  "the update reminder defaults to 90 days",
  (await reminder.inputValue()) === "90",
);
await reminder.selectOption("30");
/* The save is a request; let the server confirm it before the card closes,
   or the reopened card can read the old value in perfect honesty. */
let saved30 = false;
for (let i = 0; i < 40 && !saved30; i++) {
  const s = await (await postJson("basemap-settings")).json();
  saved30 = s.update_reminder_days === 30;
  if (!saved30) await new Promise((r) => setTimeout(r, 250));
}
check("the reminder write reaches the server", saved30);
await page.locator(".download-card .icon-button").click();
await page.waitForFunction(() => !document.querySelector(".download-card"), {
  timeout: 10_000,
});
await openButton.click();
await page.waitForSelector(".ledger-reminder select", { timeout: 10_000 });
check(
  "the reminder choice survives on the server",
  (await page.locator(".ledger-reminder select").inputValue()) === "30",
);

/* Remove is two presses of the same button, because it discards gigabytes.
   The view download's tiles sit inside the United Kingdom pick, so removing
   it must keep the archive intact -- entries own records, not tiles. */
const viewRow = page.locator(".ledger-row").filter({ hasText: "Map view" });
await viewRow.locator("button").nth(1).click();
check(
  "remove asks to be sure",
  ((await viewRow.locator("button").nth(1).textContent()) ?? "")
    .includes("Really"),
);
await viewRow.locator("button").nth(1).click();
const rowGone = await page
  .waitForFunction(
    () => document.querySelectorAll(".ledger-row").length === 3,
    { timeout: 30_000 },
  )
  .then(() => true, () => false);
check("the removed entry leaves the list", rowGone);
const removedToast = await page
  .waitForFunction(
    () =>
      [...document.querySelectorAll("[data-sonner-toast]")].some((t) => {
        const text = t.textContent ?? "";
        /* Either wording is correct: bytes freed, or all tiles shared. */
        return text.includes("Maps removed") || text.includes("Map removed");
      }),
    { timeout: 10_000 },
  )
  .then(() => true, () => false);
check("removal announces what it freed", removedToast);
const ledger2 = await (await postJson("basemap-ledger")).json();
check(
  "the archive agrees the entry is gone",
  ledger2.entries?.length === 3
    && !ledger2.entries.some((e) => e.name === "Map view"),
);
check(
  "the shared tiles survived the removal",
  (await fetch(`${base}/basemap/map.pmtiles`, { method: "HEAD" })).status
    === 200,
);

/* Update through the card, on the clipped country pick: the one deliberate
   way to refresh held tiles, exercised over a polygon region. The card
   closes itself when the job completes, like any download. */
await page
  .locator(".ledger-row")
  .filter({ hasText: "United Kingdom" })
  .locator("button")
  .nth(0)
  .click();
check("an update of a clipped region completes", await awaitDone(6));
await page.waitForFunction(() => !document.querySelector(".download-card"), {
  timeout: 10_000,
});

/* ------------------- multi-part downloads and resume ----------------------

   A third server instance runs with a deliberately tiny tile budget
   (--tile-budget 1024,256,8), so a request the production budget would
   swallow whole is forced down the giant path: split into parts, fetched
   one at a time, each merged and renamed atomically. Driven over the API
   because the interesting claims are the server's. */
const base3 = process.argv[3] ?? "http://127.0.0.1:7375";
const post3 = async (endpoint, body) =>
  await fetch(`${base3}/api/${endpoint}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body ?? {}),
  });
const world = {
  min_lon: -179.9,
  min_lat: -84,
  max_lon: 179.9,
  max_lat: 84,
  max_zoom: 6,
};
const est3 = await (await post3("basemap-estimate", { regions: [world] }))
  .json();
check(
  "a box over the budget splits instead of clamping",
  est3.max_zooms?.[0] === 6 && est3.covered === false && est3.tiles > 0,
);
const finalJob3 = async (generation) => {
  for (let i = 0; i < 120; i++) {
    const status = await (await post3("basemap-status")).json();
    if (
      status.generation === generation
      && !["planning", "fetching", "assets", "removing"].includes(
        status.job?.state,
      )
      && status.job?.state !== "idle"
    ) {
      return status.job;
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  return null;
};
await post3("basemap-download", { regions: [world] });
const done3 = await finalJob3(1);
check(
  "the split download completes in several parts",
  done3?.state === "done" && done3.parts >= 2,
);
const est3b = await (await post3("basemap-estimate", { regions: [world] }))
  .json();
check("re-asking after a split download says covered", est3b.covered === true);
/* The resume path: every part's tiles are already held, so each is planned,
   found covered, and skipped -- the download writes nothing and says so. */
await post3("basemap-download", { regions: [world] });
const again3 = await finalJob3(2);
check(
  "a re-download skips every held part and says so",
  again3?.state === "failed" && /already have/.test(again3.reason ?? ""),
);

/* The same ledger, driven over the API. The scripted download above carried
   no name, so the server coined one from its box. */
const led3 = await (await post3("basemap-ledger")).json();
check(
  "a scripted download is recorded under its box",
  led3.entries?.length === 1
    && led3.entries[0].name === "-179.90, -84.00 - 179.90, 84.00"
    && led3.entries[0].completed > 0,
);
/* The accuracy claim on bytes: the entry records what the network
   delivered, never archive-copy volume. For a multi-part download the
   quote deliberately double-counts seam tiles the later parts then skip,
   so fetched <= quoted; and the copy volume re-counts every earlier part,
   so fetched < Done's total. The old bug recorded the latter. */
check(
  "the recorded bytes are network bytes, not copy volume",
  led3.entries?.[0]?.bytes > 0
    && led3.entries[0].bytes <= est3.total_bytes
    && led3.entries[0].bytes < done3.total_bytes,
);
const id3 = led3.entries?.[0]?.id ?? "";
/* Update re-fetches the region tile for tile -- the one deliberate way to
   refresh stale tiles -- and, still over the tiny budget, in parts again. */
await post3("basemap-update", { id: id3 });
const upd3 = await finalJob3(3);
check(
  "an update re-downloads a recorded region in parts",
  upd3?.state === "done" && upd3.parts >= 2 && upd3.total_bytes > 0,
);
const led3b = await (await post3("basemap-ledger")).json();
check(
  "an update replaces its entry rather than duplicating it",
  led3b.entries?.length === 1 && led3b.entries[0].id === id3
    && led3b.entries[0].completed >= led3.entries[0].completed,
);
/* Settings live beside the archive they govern. */
const set3 = await (await post3("basemap-settings", {
  update_reminder_days: 180,
})).json();
const got3 = await (await post3("basemap-settings")).json();
check(
  "the reminder setting persists server-side",
  set3.update_reminder_days === 180 && got3.update_reminder_days === 180,
);
check(
  "an out-of-range reminder is refused",
  (await post3("basemap-settings", { update_reminder_days: 9999 })).status
    === 400,
);
/* Removing the only entry removes the archive itself: an empty archive and
   a missing one are the same state, spelled the honest way. */
await post3("basemap-remove", { id: id3 });
const rem3 = await finalJob3(4);
check(
  "removing the last region deletes the archive",
  rem3?.state === "removed"
    && (await fetch(`${base3}/basemap/map.pmtiles`, { method: "HEAD" }))
        .status === 404,
);
const led3c = await (await post3("basemap-ledger")).json();
check("and the ledger reads empty afterwards", led3c.entries?.length === 0);
await post3("basemap-remove", { id: "abcdef012345" });
const rem3b = await finalJob3(5);
check(
  "removing from a missing archive fails out loud",
  rem3b?.state === "failed",
);

/* A giant beyond even the split ceiling is clamped to a shallower granted
   depth -- and the ledger must record the depth that was FETCHED, not the
   one asked for, or Remove and Update would speak of tiles that never
   existed. */
const deepWorld = { ...world, max_zoom: 10 };
const estClamped = await (await post3("basemap-estimate", {
  regions: [deepWorld],
})).json();
check(
  "the tiny budget clamps a too-deep world",
  typeof estClamped.max_zooms?.[0] === "number"
    && estClamped.max_zooms[0] < 10,
);
await post3("basemap-download", {
  name: "Clamped world",
  regions: [deepWorld],
});
const clamped3 = await finalJob3(6);
check("the clamped download completes", clamped3?.state === "done");
const ledClamped = await (await post3("basemap-ledger")).json();
check(
  "the entry records the granted depth, not the request",
  ledClamped.entries?.length === 1
    && ledClamped.entries[0].max_zoom === estClamped.max_zooms[0],
);
check(
  "and its bytes are again exactly the quote",
  ledClamped.entries?.[0]?.bytes === estClamped.total_bytes,
);

/* ------------------------------ browse cache -------------------------------

   Opt in, look at a place, and its tiles are cached -- server-side gate,
   anonymous tiles, and (on this server's one-byte compaction threshold)
   folded straight into the main archive. */
const tileAt = (lon, lat, z) => {
  const n = 2 ** z;
  const x = Math.floor((lon + 180) / 360 * n);
  const r = lat * Math.PI / 180;
  const y = Math.floor(
    (1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2 * n,
  );
  return { x, y };
};
const lb = { min_lon: -0.2, min_lat: 51.46, max_lon: -0.05, max_lat: 51.56 };
const lt = tileAt(-0.12, 51.5, 15);
check(
  "browsing while the setting is off is refused server-side",
  (await post3("basemap-browse", { ...lb, zoom: 15 })).status === 403,
);
const setBrowse = await (await post3("basemap-settings", {
  browse_cache: true,
})).json();
check(
  "the browse toggle persists without touching the reminder",
  setBrowse.browse_cache === true && setBrowse.update_reminder_days === 180,
);
check(
  "a deep tile is absent before browsing",
  (await fetch(`${base3}/tiles/15/${lt.x}/${lt.y}.mvt`)).status === 204,
);
const browsed = await (await post3("basemap-browse", { ...lb, zoom: 15 }))
  .json();
check("a settled view fetches its missing tiles", browsed.fetched > 0);
/* The depth actually written travels back with it. The client compares
   this against what its map advertises to decide whether deeper tiles have
   arrived, so a wrong or missing number is a map that never fills in. */
check("the browse answers with the depth it wrote", browsed.zoom === 15);
/* The one-byte threshold compacts immediately; wait for the writer to rest. */
let compacted = false;
for (let i = 0; i < 120 && !compacted; i++) {
  const st = await (await post3("basemap-status")).json();
  if (
    !["planning", "fetching", "assets", "removing", "compacting"]
      .includes(st.job?.state)
  ) {
    compacted = (await fetch(`${base3}/basemap/cache.pmtiles`, {
      method: "HEAD",
    })).status === 404;
  }
  if (!compacted) await new Promise((r) => setTimeout(r, 250));
}
check("the cache folds into the main archive past the threshold", compacted);
check(
  "the browsed tile serves after compaction",
  (await fetch(`${base3}/tiles/15/${lt.x}/${lt.y}.mvt`)).status === 200,
);
const ledAfterBrowse = await (await post3("basemap-ledger")).json();
check(
  "browsed tiles stay anonymous -- no ledger entry",
  ledAfterBrowse.entries?.length === 1,
);
const browsedAgain = await (await post3("basemap-browse", { ...lb, zoom: 15 }))
  .json();
check("a second look fetches nothing", browsedAgain.fetched === 0);

/* The world offer must return for anyone who started with a region. A
   fresh page on this server (archive on disk) with the WORLD estimate
   answered by intercept: whether the server's estimate is right is the
   server tests' business; the card's rule under test is "maps present +
   world missing => the offer is back". The old rule -- offer only on an
   empty map -- is exactly how the Georgia-first user never saw it. */
const worldPage = await context.newPage();
await worldPage.route("**/api/basemap-estimate", async (route) => {
  let world = false;
  try {
    const body = JSON.parse(route.request().postData() ?? "{}");
    const r = body.regions?.[0];
    world = body.regions?.length === 1 && r?.min_lon === -180
      && r?.max_lon === 180 && r?.min_lat === -85 && r?.max_zoom === 6;
  } catch {
    /* not JSON: not ours */
  }
  if (world) {
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        total_bytes: 45_000_000,
        tiles: 5461,
        covered: false,
        max_zooms: [6],
      }),
    });
  } else await route.continue();
});
await worldPage.goto(base3, { waitUntil: "networkidle" });
await worldPage.locator("#phrase").fill(sampleMnemonic);
await worldPage.waitForSelector(".valid", { timeout: 30_000 });
await worldPage.locator("button[type=submit]").click();
await worldPage.waitForSelector(".map-wrap", { timeout: 60_000 });
await worldPage.locator(".map-actions .icon-button").click();
await worldPage.waitForSelector(".download-card", { timeout: 10_000 });
await worldPage.waitForSelector(".download-world", { timeout: 30_000 });
check("with maps on disk but no world overview, the offer is back", true);
check(
  "the returned offer explains itself with a size",
  ((await worldPage.locator(".download-world .hint").textContent()) ?? "")
    .length > 0,
);
check(
  "the view offer still leads the card",
  await worldPage.evaluate(() => {
    const view = document.querySelector(".download-view");
    const world = document.querySelector(".download-world");
    return view !== null && world !== null
      && (view.compareDocumentPosition(world)
          & Node.DOCUMENT_POSITION_FOLLOWING) !== 0;
  }),
);
await worldPage.close();

/* Let the swapped style fetch and render its tiles; anything it logs from
   here on fails the final console check. */
await page.waitForTimeout(2500);

/* The round trip the whole project is for, driven entirely through the UI:
   paste an address, fly to the square it names, click that square, and get
   the same address back.

   No test hook on the map. Going through the real controls is what makes this
   evidence that a person can do it. */
await page.locator(".lookup input").fill(sample.address);
await page.locator(".lookup button").click();
await page.waitForTimeout(3000); // decode, then a 1.2 s flight

const lookupFailed = await page.locator("[data-sonner-toast][data-type=error]")
  .count();
check(`looking up ${sample.address} succeeds`, lookupFailed === 0);

/* flyTo centres on the decoded point, so the centre pixel is inside the
   square that address names. Clicking it must name it the same way. */
const box = await page.locator(".map").boundingBox();
await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
await page.waitForTimeout(1500);

/* Reads the panel's latitude and longitude back as numbers.

   This is what pins the browser's KEY to the vectors, and nothing else in the
   suite does. Looking up an address and clicking the square it lands on is a
   round trip through decode-then-encode, which returns the address you started
   with under ANY key -- a wrong key simply decodes it to a different place on
   Earth and re-encodes that place back to the same words. The coordinates are
   the only output that differs. */
/* Coordinates start hidden, exactly like the address -- they name where
   someone is. The mask must be in the DOM in place of the value, not over
   it, and the eye reveals. */
const maskedCoords = await page.locator(".coords dd").allTextContents();
check(
  "coordinates are hidden by default -- mask instead of value, not over it",
  maskedCoords.length === 2
    && maskedCoords.every((t) => t.includes("•") && !/\d/.test(t)),
);
const coordsEye = page.locator(".coords-row .icon-button").first();
await coordsEye.click();
const shownCoords = await page.locator(".coords dd").allTextContents();
check(
  "the coordinates eye reveals them",
  shownCoords.length === 2 && shownCoords.every((t) => /\d/.test(t)),
);

/* Zoomed out, a ~3 m square is sub-pixel; a pin has to mark it or a fresh
   lookup shows an empty map. Checked by rendering, not by layer presence:
   the layer existing and drawing nothing was the failure mode. */
const pinVisible = await page.evaluate(async () => {
  const map = window.__tessarium_map;
  if (!map) return false;
  /* Bounded: a hang here should fail one check, not wedge the suite. */
  const settle = () =>
    Promise.race([
      new Promise((resolve) => map.once("idle", () => resolve(true))),
      new Promise((resolve) => setTimeout(() => resolve(false), 10_000)),
    ]);
  const zoomWas = map.getZoom();
  map.setZoom(12);
  if (!(await settle())) return false;
  const pins = map.queryRenderedFeatures(undefined, {
    layers: ["selection-pin"],
  }).length;
  map.setZoom(zoomWas);
  await settle();
  return pins > 0;
});
check("a pin marks the selected square when zoomed out", pinVisible);

const panelCoords = async () => {
  const cells = await page.locator(".coords dd").allTextContents();
  return cells.map((t) => Number.parseFloat(t.replace(/[^0-9.-]/g, "")));
};

/* A decoded point lands somewhere in the ~3 m cell, so this is generous
   against rounding and merciless against a wrong key, which would put the
   point on another continent. */
const nearly = (a, b) => Math.abs(a - b) < 0.0001;

const eye = page.locator(".address-row .icon-button").first();
const copyButton = page.locator(".address-row .icon-button").nth(1);

/* Privacy mode is ON by default, so the address is not on screen yet -- and
   "not on screen" has to mean absent from the document, not merely styled out
   of sight, because anything reading the page is what it is hidden from. */
check(
  "a newly selected address is concealed by default",
  !(await page.locator(".selected").innerHTML()).includes(sample.address),
);
check(
  "the concealed address is masked rather than blank",
  ((await page.locator(".address").textContent()) ?? "").includes("\u2022"),
);

/* Copying works while concealed: putting an address on the clipboard is not
   putting it on the screen. This is also how we learn the right address is
   there at all before revealing it. */
await copyButton.click();
const concealedClipboard = await page.evaluate(() =>
  navigator.clipboard.readText()
);
check(
  `copy works while concealed (got ${concealedClipboard})`,
  concealedClipboard === sample.address,
);

await eye.click();
const clicked = await page.locator(".address").textContent();
check(
  `clicking that square yields ${sample.address} (got ${clicked})`,
  clicked === sample.address,
);

/* Version-skew detection, against the worker rather than the DOM. The served
   worker, the served core and the committed vectors must agree on the grid
   and derivation versions; a server upgraded behind a surviving tab, or a
   worker rebuilt against a different core, breaks exactly this. The versions
   are deliberately not displayed -- this test is where they live. */
const versionStatus = await page.evaluate(async () => {
  const worker = new Worker("/core.worker.js");
  return await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("worker timeout")), 60000);
    worker.onmessage = (e) => {
      clearTimeout(timer);
      resolve(e.data);
    };
    worker.postMessage({ id: 1, op: "status" });
  });
});
check(
  `served worker has the vectors' grid version (${vectors.grid_version})`,
  versionStatus.result?.gridVersion === vectors.grid_version,
);
check(
  `served worker has the vectors' derivation version (${vectors.derivation_version})`,
  versionStatus.result?.derivationVersion === vectors.derivation_version,
);

/* The footer carries the app version, baked in from package.json. */
const pkgVersion = JSON.parse(
  readFileSync(new URL("../package.json", import.meta.url), "utf8"),
).version;
check(
  `the footer shows v${pkgVersion}`,
  ((await page.locator(".versions").textContent()) ?? "").includes(
    `v${pkgVersion}`,
  ),
);

const [gotLat, gotLon] = await panelCoords();
check(
  `the looked-up address decodes to the vector's point (got ${gotLat}, ${gotLon} want ${sampleLat}, ${sampleLon})`,
  nearly(gotLat, sampleLat) && nearly(gotLon, sampleLon),
);

/* The map itself never writes addresses onto the squares. Checked while the
   address IS revealed, so the check cannot pass merely because privacy mode
   is hiding it. This catches a DOM-based label; a label drawn into the WebGL
   canvas would not appear here either way, which is what the "no bulk address
   operation" check above is for -- between them they cover the mechanism and
   the result. */
check(
  "no address is rendered onto the map",
  !(await page.locator(".map-wrap").innerHTML()).includes(sample.address),
);

/* And the toggle goes back. */
await eye.click();
check(
  "the eye toggle conceals it again",
  !(await page.locator(".selected").innerHTML()).includes(sample.address),
);
await eye.click();
check(
  "the eye toggle reveals it again",
  (await page.locator(".address").textContent()) === sample.address,
);

/* Keyboard access. The map is the one control that cannot be reached with the
   lookup box, so Enter on the focused canvas must select the centre square --
   the same square flyTo just centred, and the same address as the click. */
await page.locator(".lookup input").fill(sample.address);
await page.locator(".lookup button").click();
await page.waitForTimeout(3000);
await page.evaluate(() => document.querySelector(".map canvas")?.focus());
check(
  "the map canvas is focusable",
  await page.evaluate(() => document.activeElement?.tagName === "CANVAS"),
);
check(
  "the map canvas has an accessible name",
  ((await page.getAttribute(".map canvas", "aria-label")) ?? "").length > 10,
);
await page.keyboard.press("Enter");
await page.waitForTimeout(1500);
check(
  "Enter on the map selects the centre square",
  (await page.locator(".address").textContent()) === sample.address,
);

/* Language. Switching must translate the interface, leave the address itself
   alone -- it is BIP-39 English in every locale -- and, because this
   application persists nothing, must not write a cookie or a storage key to
   remember the choice. */
const englishFooter = await page.locator(".panel-foot p").first().textContent();
await page.locator(".language select").selectOption("fr-FR");
await page.waitForTimeout(400);
const frenchFooter = await page.locator(".panel-foot p").first().textContent();
check(
  "switching to French translates the interface",
  frenchFooter !== englishFooter,
);
check(
  "French interface is actually French",
  (frenchFooter ?? "").includes("adresses"),
);
check(
  "the address is unchanged by the language",
  (await page.locator(".address").textContent()) === sample.address,
);
check(
  "the lookup example is not translated",
  (await page.getAttribute(".lookup input", "placeholder"))
    === "dream.tourist.creek.2703",
);
check(
  "the document language follows the choice",
  (await page.getAttribute("html", "lang")) === "fr-FR",
);
const afterSwitch = await page.evaluate(() => ({
  local: JSON.stringify(window.localStorage),
  session: JSON.stringify(window.sessionStorage),
  cookie: document.cookie,
}));
check("choosing a language writes no cookie", afterSwitch.cookie === "");
check("choosing a language writes no localStorage", afterSwitch.local === "{}");
check(
  "choosing a language writes no sessionStorage",
  afterSwitch.session === "{}",
);
await page.locator(".language select").selectOption("en-US");
await page.waitForTimeout(400);

/* NFKD across the whole stack.

   The browser derives keys with WebCrypto and normalises with JavaScript's
   String.normalize; the vectors were produced by OCaml and uunf. Nothing else
   in the suite compares those two. So: lock, then unlock with the DECOMPOSED
   form of a passphrase whose addresses were generated from the PRECOMPOSED
   form, and require the same address out. "café" typed on one keyboard and
   pasted from another are these two byte sequences; before NFKD they were two
   different maps and the user was told nothing. */
const nfkdSample = vectors.nfkd_addresses[0];
/* PRECOMPOSED here, deliberately. NFKD's *output* is the decomposed form, so
   unlocking with the decomposed passphrase yields the right key even when
   normalisation is skipped entirely — a test written that way passes whether
   or not the code under it works, which is how the first version of this
   check was written. Feeding the precomposed form is the direction that can
   actually fail: without NFKD those bytes go into the KDF unchanged and
   derive a different key. */
const nfkdEntry = vectors.key_derivation.find((k) => k.name === "pass-nfc");
const nfdEntry = vectors.key_derivation.find((k) => k.name === "pass-nfd");
check(
  "the two passphrase vectors really are different byte sequences",
  nfkdEntry.passphrase !== nfdEntry.passphrase,
);

await page.locator(".panel-head .lock").click();
await page.waitForSelector("#phrase", { timeout: 30_000 });
await page.locator("#phrase").fill(nfkdEntry.mnemonic);
await page.waitForSelector(".valid", { timeout: 30_000 });
await page.locator(".passphrase summary").click();
await page.locator("#passphrase").fill(nfkdEntry.passphrase);
await page.locator("button[type=submit]").click();
await page.waitForSelector(".map-wrap", { timeout: 60_000 });

await page.locator(".lookup input").fill(nfkdSample.address);
await page.locator(".lookup button").click();
await page.waitForTimeout(3000);
const nfkdBox = await page.locator(".map").boundingBox();
await page.mouse.click(
  nfkdBox.x + nfkdBox.width / 2,
  nfkdBox.y + nfkdBox.height / 2,
);
await page.waitForTimeout(1500);
await page.locator(".address-row .icon-button").first().click();
/* Locking must have hidden the coordinates again; assert it, or a broken
   reset would make this click CONCEAL them and fail later with a message
   about NFKD normalisation instead of this one. */
check(
  "locking hides the coordinates again",
  (await page.locator(".coords dd").allTextContents()).every((t) =>
    t.includes("•")
  ),
);
await page.locator(".coords-row .icon-button").first().click();
const [nfkdLat, nfkdLon] = await panelCoords();
check(
  `a precomposed passphrase is normalised before derivation (got ${nfkdLat}, ${nfkdLon} want ${
    nfkdSample.lat_ns / 1e9
  }, ${nfkdSample.lon_ns / 1e9})`,
  nearly(nfkdLat, nfkdSample.lat_ns / 1e9)
    && nearly(nfkdLon, nfkdSample.lon_ns / 1e9),
);

await browser.close();

/* ------------------ browse cache prune coherence (main) -------------------

   The rule the browse cache lives by: a completed download OWNS its region
   and prunes any browsed copy of the tiles it covers, because the tile
   endpoint consults the cache first and a stale browsed tile would shadow
   freshly downloaded bytes forever. Testable only HERE: this server runs
   the real compaction threshold, so the cache genuinely persists between
   operations; the multipart server's one-byte threshold folds it away the
   moment it exists. Driven over the API -- the page is gone, so nothing
   auto-browses underneath these steps. */
const awaitRemoved = async (generation) => {
  for (let i = 0; i < 120; i++) {
    const status = await (await postJson("basemap-status")).json();
    if (status.generation === generation && status.job?.state === "removed") {
      return true;
    }
    if (status.job?.state === "failed") return false;
    await new Promise((r) => setTimeout(r, 500));
  }
  return false;
};
const cacheStatus = async () =>
  (await fetch(`${base}/basemap/cache.pmtiles`, { method: "HEAD" })).status;
const deepTile = async () =>
  (await fetch(`${base}/tiles/15/${lt.x}/${lt.y}.mvt`)).status;

/* Open a hole: removing the UK entry drops the deep London tiles no kept
   entry fetched, which is exactly what a browse can then fill. */
const mainLedger = await (await postJson("basemap-ledger")).json();
const ukLedgerId = mainLedger.entries
  ?.find((e) => e.name === "United Kingdom and London")?.id;
await postJson("basemap-remove", { id: ukLedgerId });
check("removing the deep entry terminates", await awaitRemoved(7));
check("its deep tile is gone from the archive", (await deepTile()) === 204);

await postJson("basemap-settings", { browse_cache: true });
const mainBrowse = await (await postJson("basemap-browse", { ...lb, zoom: 15 }))
  .json();
check("a browse refills the hole into the cache", mainBrowse.fetched > 0);
check(
  "the cache persists below the real threshold",
  (await cacheStatus()) === 200,
);
check("the browsed tile serves from the cache", (await deepTile()) === 200);

/* Off means gone: the toggle is also the eraser. */
await postJson("basemap-settings", { browse_cache: false });
check("turning browsing off deletes the cache", (await cacheStatus()) === 404);
check(
  "and closes the endpoint again",
  (await postJson("basemap-browse", { ...lb, zoom: 15 })).status === 403,
);

/* Refill, then download the same region: completion must prune the cache
   -- emptied entirely here, so the file itself goes -- and the tile must
   keep serving, now from bytes the download fetched fresh. */
await postJson("basemap-settings", { browse_cache: true });
const refill = await (await postJson("basemap-browse", { ...lb, zoom: 15 }))
  .json();
check("the cleared cache re-fetches on the next browse", refill.fetched > 0);
check("and exists again", (await cacheStatus()) === 200);
await postJson("basemap-download", {
  name: "London borrowed back",
  regions: [{ ...lb, max_zoom: 15 }],
});
check("downloading the browsed region completes", await awaitDone(8));
check(
  "the download prunes its region out of the cache",
  (await cacheStatus()) === 404,
);
check(
  "the tile survives the prune, served from the archive",
  (await deepTile()) === 200,
);
const prunedLedger = await (await postJson("basemap-ledger")).json();
check(
  "the download is recorded; the browses never were",
  prunedLedger.entries?.some((e) => e.name === "London borrowed back")
    && prunedLedger.entries?.length === 3,
);
await postJson("basemap-settings", { browse_cache: false });

/* ------------- a download that stops early still owns its region ----------

   Every part renamed into the archive owns what it published from that
   moment on, so the browse cache must lose those tiles whether the run
   finished or not -- the tile endpoint reads the cache FIRST, and an older
   browsed copy would shadow the fresh bytes forever. The completed case is
   covered above; this is the cancelled one.

   Its server reads through the delaying proxy, which is what makes "halfway"
   a place that exists. */
const base5 = process.argv[5] ?? "http://127.0.0.1:7377";
const post5 = async (endpoint, body) =>
  await fetch(`${base5}/api/${endpoint}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body ?? {}),
  });
const cancelHas = async (file) =>
  (await fetch(`${base5}/basemap/${file}`, { method: "HEAD" })).status;

/* A corner of the slow fixture, cached by browsing it. */
const slowView = {
  min_lon: -0.2,
  min_lat: 51.46,
  max_lon: -0.05,
  max_lat: 51.56,
};
await post5("basemap-settings", { browse_cache: true });
const slowBrowse =
  await (await post5("basemap-browse", { ...slowView, zoom: 12 }))
    .json();
check("the cancel server caches a browsed view", slowBrowse.fetched > 0);
check(
  "and keeps it -- its threshold is the real one",
  (await cancelHas("cache.pmtiles")) === 200,
);

/* The whole fixture, which covers that corner, in pieces small enough that
   the first lands early and several remain. */
await post5("basemap-download", {
  name: "Cancelled halfway",
  regions: [{
    min_lon: -0.6,
    min_lat: 51.2,
    max_lon: 0.4,
    max_lat: 51.8,
    max_zoom: 12,
  }],
});
/* The archive file appearing IS a part having landed, which is the only
   thing that makes the run own a region. */
let landed = false;
for (let i = 0; i < 600 && !landed; i++) {
  landed = (await cancelHas("map.pmtiles")) === 200;
  if (!landed) await new Promise((r) => setTimeout(r, 25));
}
check("a part of the download reached the archive", landed);
check(
  "cancelling it is accepted",
  (await (await post5("basemap-cancel")).json()).ok === true,
);
let stopped = "";
for (let i = 0; i < 300; i++) {
  stopped = (await (await post5("basemap-status")).json()).job?.state ?? "";
  if (["cancelled", "done", "failed"].includes(stopped)) break;
  await new Promise((r) => setTimeout(r, 100));
}
/* Finishing first would make the next check vacuous rather than wrong, so
   it fails loudly instead of passing quietly. */
check(
  `the download stopped as cancelled (got ${stopped})`,
  stopped === "cancelled",
);
check(
  "a cancelled download still prunes the region it published",
  (await cancelHas("cache.pmtiles")) === 404,
);
await post5("basemap-settings", { browse_cache: false });

/* ------------------ a source that changed compression ---------------------

   Tile bytes are copied verbatim and the header says how to read them, so
   an archive built from a gzipped source and then merged with an
   uncompressed one would relabel every tile it already held. Unreadable,
   silently, and only at render time. This server's source disagrees with
   the archive seeded beside it, so every path that would merge them has to
   refuse instead. */
const base4 = process.argv[4] ?? "http://127.0.0.1:7376";
const post4 = async (endpoint, body) =>
  await fetch(`${base4}/api/${endpoint}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body ?? {}),
  });

const mismatchEstimate = await post4("basemap-estimate", {
  regions: [{ ...lb, max_zoom: 15 }],
});
const mismatchBody = await mismatchEstimate.json();
check(
  "an estimate against a differently compressed source is refused",
  mismatchEstimate.status === 502
    && (mismatchBody.error ?? "").includes("compression"),
);
await post4("basemap-settings", { browse_cache: true });
const mismatchBrowse = await post4("basemap-browse", { ...lb, zoom: 15 });
const mismatchBrowseBody = await mismatchBrowse.json();
check(
  "and so is a browse, which would write those bytes into the cache",
  mismatchBrowse.status === 409
    && (mismatchBrowseBody.error ?? "").includes("compression"),
);
check(
  "nothing was written",
  (await fetch(`${base4}/basemap/cache.pmtiles`, { method: "HEAD" })).status
    === 404,
);
await post4("basemap-settings", { browse_cache: false });

slowProxy.close();

for (const p of problems) console.log(`  PAGE  ${p}`);
check(
  "no console errors, CSP violations or failed requests",
  problems.length === 0,
);

console.log(`\n${checks} checks, ${failures} failures`);
process.exit(failures ? 1 : 0);
