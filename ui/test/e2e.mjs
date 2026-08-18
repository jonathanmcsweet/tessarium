/* End-to-end check of the built UI against the built server.

   This is the test for the claim the whole project rests on: enter a phrase,
   click a square, get its address. It runs the real browser against the real
   binary, because the parts that break here -- Web Worker startup, the
   Content-Security-Policy, js_of_ocaml's export target in a worker -- are all
   things that look fine in a unit test and fail in a page.

   The addresses it expects come from `vectors/vectors.json`, so a UI that
   renders beautifully and computes the wrong answer still fails. */

import { readFileSync } from "node:fs";
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

/* PBKDF2 runs here. Generous, because a cold worker on a loaded machine is
   slower than the number anyone quotes. */
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

/* From here on, basemap errors are real: the tiles on disk came from the
   fixture and MapLibre must parse every one of them cleanly. */
basemapReady = true;

check(
  "the downloaded archive is served",
  (await fetch(`${base}/basemap/map.pmtiles`, { method: "HEAD" })).status
    === 200,
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
check(
  "coordinates are hidden by default",
  (await page.locator(".coords dd").allTextContents()).every((t) =>
    t.includes("•")
  ),
);
const coordsEye = page.locator(".coords-row .icon-button").first();
await coordsEye.click();
check(
  "the coordinates eye reveals them",
  (await page.locator(".coords dd").allTextContents()).every((t) =>
    /\d/.test(t)
  ),
);

/* Zoomed out, a ~3 m square is sub-pixel; a pin has to mark it or a fresh
   lookup shows an empty map. Checked by rendering, not by layer presence:
   the layer existing and drawing nothing was the failure mode. */
const pinVisible = await page.evaluate(async () => {
  const map = window.__tessarium_map;
  if (!map) return false;
  const zoomWas = map.getZoom();
  map.setZoom(12);
  await new Promise((resolve) => map.once("idle", resolve));
  const pins = map.queryRenderedFeatures(undefined, {
    layers: ["selection-pin"],
  }).length;
  map.setZoom(zoomWas);
  await new Promise((resolve) => map.once("idle", resolve));
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
   actually fail: without NFKD those bytes go into PBKDF2 unchanged and derive
   a different key. */
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
/* Locking hid the coordinates again -- the reset is deliberate. */
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

for (const p of problems) console.log(`  PAGE  ${p}`);
check(
  "no console errors, CSP violations or failed requests",
  problems.length === 0,
);

console.log(`\n${checks} checks, ${failures} failures`);
process.exit(failures ? 1 : 0);
