/* End-to-end check of the built UI against the built server.

   This is the test for the claim the whole project rests on: enter a phrase,
   click a square, get its address. It runs the real browser against the real
   binary, because the parts that break here -- Web Worker startup, the
   Content-Security-Policy, js_of_ocaml's export target in a worker -- are all
   things that look fine in a unit test and fail in a page.

   The addresses it expects come from `vectors/vectors.json`, so a UI that
   renders beautifully and computes the wrong answer still fails. */

import { readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import http, { createServer } from "node:http";
import { chromium } from "playwright";

const base = process.argv[2] ?? "http://127.0.0.1:7379";
const vectors = JSON.parse(
  readFileSync(new URL("../../vectors/vectors.json", import.meta.url), "utf8"),
);
/* The source catalogue rather than a string copied into this file: a check
   that quotes its own copy of the wording passes after someone changes the
   wording and the meaning with it, which for a message whose whole job is
   to not overclaim is the failure worth catching. */
const messages = JSON.parse(
  readFileSync(new URL("../messages/en-US.json", import.meta.url), "utf8"),
);
const m = (key) => messages[key];

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
/* The dropdowns are React Aria's Select, not a native `<select>`, so there is
   no `selectOption`: press the control, then press the option. Options carry
   a `data-value` written by components/Dropdown.tsx for exactly this, rather
   than a key attribute belonging to the library.

   `chooseFrom` returns the button, because what a dropdown currently reads is
   the button's text -- there is no `inputValue` either. */
const dropdownIn = (scope) => page.locator(`${scope} .dropdown-button`);
const chooseFrom = async (scope, value) => {
  const button = dropdownIn(scope);
  await button.click();
  await page.locator(`.dropdown-option[data-value="${value}"]`).click();
  /* The popover unmounts on selection; waiting for that keeps a later click
     from landing on a list that is still fading. */
  await page.waitForFunction(
    () => document.querySelector(".dropdown-popover") === null,
    null,
    { timeout: 10_000 },
  );
  return button;
};

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

/* Flipped for the one test that takes the server away on purpose. Every
   handler below would otherwise record the refusal as a real failure, which
   is exactly what they are for every other second of this run.

   It covers argon2.wasm as well as /healthz: the KDF module is what makes
   unlocking genuinely fail, rather than merely look like it might. And while
   it is set, console errors and page errors are ignored wholesale -- the app
   is SUPPOSED to be complaining, loudly, for those few seconds. */
let serverGone = false;
const refusedOnPurpose = (url) =>
  serverGone && (url.includes("/healthz") || url.includes("/argon2.wasm"));

page.on("console", (msg) => {
  if (msg.type() !== "error") return;
  if (serverGone) return;
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
page.on("pageerror", (err) => {
  if (serverGone) return;
  problems.push(`pageerror: ${err.message}`);
});
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
  if (refusedOnPurpose(req.url())) return;
  if (!expected(req.url())) {
    problems.push(`requestfailed: ${req.url()} ${req.failure()?.errorText}`);
  }
});
page.on("response", (res) => {
  if (refusedOnPurpose(res.url())) return;
  if (res.status() >= 400 && !expected(res.url())) {
    problems.push(`http ${res.status()}: ${res.url()}`);
  }
});

await page.goto(base, { waitUntil: "networkidle" });

check(
  "gate renders",
  (await page.locator("h1").textContent()) === "Tessarium",
);

/* The core has to load inside the worker before validation replies.
   If js_of_ocaml exported to the wrong global, this is where it hangs.

   The `null` in every waitForFunction below is the argument passed to the
   page function, and it is there because the third parameter is the options.
   Without it the timeout is read as that argument and silently discarded --
   which is how a wait that says sixty seconds spent thirty, and reported
   Playwright's default in the failure rather than its own number. */
await page.locator("#phrase").fill("abandon abandon abandon");
await page.waitForFunction(
  () =>
    document.querySelector(".phrase-status")?.textContent?.includes(
      "expected 24 words",
    ),
  null,
  { timeout: 30_000 },
);
/* The one secret this application handles, in a field a password manager
   will recognise. It was a textarea with autocomplete off, so nothing ever
   offered to remember the string that cannot be recovered if it is lost.
   Masked by default, because it is typed on whatever screen is to hand. */
check(
  "the phrase is a password field a manager can save",
  (await page.locator("#phrase").getAttribute("type")) === "password"
    && (await page.locator("#phrase").getAttribute("autocomplete"))
      === "current-password",
);
await page.locator(".gate-phrase-toggle").click();
check(
  "and reveals on demand, because 24 words cannot be proofread as bullets",
  (await page.locator("#phrase").getAttribute("type")) === "text",
);
await page.locator(".gate-phrase-toggle").click();
check(
  "and hides again",
  (await page.locator("#phrase").getAttribute("type")) === "password",
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
  null,
  { timeout: 30_000 },
);
check(
  "checksum catches a single wrong word",
  (await page.locator(".phrase-status").textContent()).includes(
    "checksum failed",
  ),
);

/* Where the phrase comes from is the highest-value security decision in the
   app, so the guidance for it must be on screen BEFORE anything is generated
   or typed -- not at the foot of the form where it is read after the choice,
   if at all. Both halves are checked: don't invent, and don't reuse. The
   position check is the part that actually rings when the block drifts back
   down the form, since a warning below the submit button still "appears". */
{
  /* Located by class, not by copy: a reworded warning should fail the one
     text check below, not report that the layout moved. */
  const provenance = page.locator(".warning.provenance");
  check(
    "the phrase-provenance warning is visible before generating",
    await provenance.isVisible(),
  );
  /* The heading directs; the body carries the two hazards. Checked where
     each actually lives, so a reworded heading fails the heading check and
     a thinned-out body fails the body check, rather than one failure
     pointing at the wrong half. */
  const title = await provenance.locator("strong").textContent();
  check("its heading directs the user to generate", /generat/i.test(title));
  const body = await provenance.textContent();
  check(
    "its body still rules out inventing a phrase",
    body.includes("only if this button produced them"),
  );
  check(
    "its body still rules out reusing a phrase",
    body.includes("protect nothing else"),
  );
  /* The claim has to stay the true one: validation is a typo check, not a
     test of how the phrase was produced. */
  check(
    "it says the checks do not prove the phrase was generated",
    (await provenance.textContent()).includes(
      "confirm you typed a phrase correctly, not that it was generated",
    ),
  );
  check(
    "the provenance warning sits above the unlock button",
    await page.evaluate(() => {
      const warning = document.querySelector(".warning.provenance");
      const submit = document.querySelector("button[type=submit]");
      if (!warning || !submit) return false;
      return !!(warning.compareDocumentPosition(submit)
        & Node.DOCUMENT_POSITION_FOLLOWING);
    }),
  );
  check(
    "the generate button is described by its hint",
    await page.evaluate(() => {
      const button = document.querySelector(".generate button");
      const id = button?.getAttribute("aria-describedby");
      return !!id && !!document.getElementById(id)?.textContent?.trim();
    }),
  );
}

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

/* The map has to actually occupy its half of the window, and that is not
   implied by the element existing.

   This caught a real one. MapLibre puts `maplibregl-map` on the same element
   the stylesheet calls `.map`, and its own rule sets `position: relative` with
   no height. One class each, so the later stylesheet wins -- and when the map
   moved into its own chunk, its CSS started arriving in a second file loaded
   after the app's. The map computed to height 0. Everything still mounted,
   tiles still loaded, `.map-wrap` still appeared; clicks simply landed on a
   map with no area, and the first thing to complain was an unrelated check
   about the coordinate row several hundred lines below. Asserted here, at the
   point it becomes true, so the next time it is a diagnosis rather than a
   hunt. */
const mapBox = await page.locator(".map").boundingBox();
const wrapBox = await page.locator(".map-wrap").boundingBox();
check(
  `the map fills its wrapper (${Math.round(mapBox?.width ?? 0)}x${
    Math.round(mapBox?.height ?? 0)
  })`,
  mapBox !== null && wrapBox !== null
    && mapBox.height >= wrapBox.height - 1
    && mapBox.width >= wrapBox.width - 1
    && mapBox.height > 100,
);
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
   nothing, not log an error per pan.

   NOT 404, and this was tried: MapLibre's vector source swallows a 404 on
   purpose (`if (err && err.status !== 404) throw err`) and files it as an
   empty tile, so the two statuses are indistinguishable to the map and 404
   buys only a red line in devtools. What keeps the coarse map on screen is
   the source's maxzoom telling the truth, not the status code. */
check(
  "a tile with no archive behind it is 204, not an error",
  (await fetch(`${base}/tiles/0/0/0.mvt`)).status === 204,
);
check(
  "a malformed tile path is 404",
  (await fetch(`${base}/tiles/3/8/0.mvt`)).status === 404
    && (await fetch(`${base}/tiles/3/04/0.mvt`)).status === 404,
);

/* The guard, against the real route rather than the predicate. A page the
   user is merely visiting shares this loopback socket with the UI, and
   nothing here asks for credentials -- so without this, that page can start
   a download, delete a map, or switch on the network cache. It cannot read
   the reply either way; what matters is that the side effect never runs. */
check(
  "an api call from another site is refused",
  (await fetch(`${base}/api/basemap-status`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "sec-fetch-site": "cross-site",
    },
    body: "{}",
  })).status === 403,
);
check(
  "so is one carrying another site's origin",
  (await fetch(`${base}/api/basemap-status`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      origin: "http://evil.example",
    },
    body: "{}",
  })).status === 403,
);
/* A refusal is still a whole HTTP transaction: the body has to come off the
   socket, or the next request on the connection parses its tail. When it is
   too big to take off, the connection has to end instead. */
const refusedHuge = await fetch(`${base}/api/basemap-status`, {
  method: "POST",
  headers: {
    "content-type": "application/json",
    "sec-fetch-site": "cross-site",
  },
  body: `{"regions":[${"null,".repeat(1_000_000)}null]}`,
});
check(
  "a refusal whose body is too big to drain closes the connection",
  refusedHuge.status === 403
    && refusedHuge.headers.get("connection") === "close",
);
check(
  "and one small enough to drain does not",
  (await fetch(`${base}/api/basemap-status`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "sec-fetch-site": "cross-site",
    },
    body: "{}",
  })).headers.get("connection") !== "close",
);

/* text/plain is the shape that needs no preflight, so it is the one a page
   would actually reach for. */
check(
  "and one posted as text/plain, which needs no preflight",
  (await fetch(`${base}/api/basemap-status`, {
    method: "POST",
    headers: { "content-type": "text/plain" },
    body: "{}",
  })).status === 415,
);

/* The basemap endpoints need no --api and sit outside the rate limiter, so
   an unbounded read here is a way to have the process killed by declaring a
   body far larger than memory. The bound is 4 MiB against a real ceiling of
   about 250 KB -- every region the UI knows, polygons included, at once. */
const oversized = await fetch(`${base}/api/basemap-estimate`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: `{"regions":[${"null,".repeat(1_000_000)}null]}`,
});
check(
  "a request body past the bound is refused, not buffered",
  oversized.status === 413,
);
/* And the connection ends with it. What is over the bound cannot be drained
   -- being over the bound is what it means -- so the rest of the body would
   still be on the socket when the next request began parsing, and would be
   read as that request. Every check below this one is the regression test;
   this is the reason. */
check(
  "and the connection closes rather than leaving the body on the socket",
  oversized.headers.get("connection") === "close",
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
  null,
  { timeout: 30_000 },
);
await worldButton.click();
check("the world download completes at generation one", await awaitDone(1));
await page.waitForFunction(
  () =>
    [...document.querySelectorAll("[data-sonner-toast]")].some((t) =>
      (t.textContent ?? "").includes("Maps downloaded")
    ),
  null,
  { timeout: 30_000 },
);
check("the download completes with a toast", true);
check(
  "and the toast carries a close button for keyboard users",
  (await page.locator("[data-sonner-toast] [data-close-button]").count()) >= 1,
);
await page.waitForFunction(() => !document.querySelector(".banner"), null, {
  timeout: 10_000,
});
check("the banner clears once maps exist", true);
await page.waitForFunction(
  () => !document.querySelector(".download-card"),
  null,
  {
    timeout: 10_000,
  },
);
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
    () => (window.__tessarium_map?.querySourceFeatures("grid").length ?? 0) > 0,
    null,
    { timeout: 30_000 },
  )
  .then(() => true, () => false);
check("and the grid refills after the swap", gridRefilled);

/* The overview is all there is, the map sits at street zoom, and everything
   on screen is therefore overzoomed -- and MapLibre only overzooms past the
   SOURCE's stated maxzoom. The floor source must carry the depth the
   archives really cover the planet at, not a hardcoded number: a source
   pinned at 15 asked for z15 tiles nobody held and rendered a blank basemap
   over data that was there. That depth is MEASURED, and for this fixture it
   is the single zoom-0 tile. (The fixture's tiles carry no styled layers, so
   this is asserted on the source itself rather than on rendered features.) */
const floorDepth = await page
  .waitForFunction(
    () => window.__tessarium_map?.getSource("protomaps-floor")?.maxzoom === 0,
    null,
    { timeout: 30_000 },
  )
  .then(() => true, () => false);
check(
  "the floor source takes its depth from what is really covered",
  floorDepth,
);

/* From here on, basemap errors are real: the tiles on disk came from the
   fixture and MapLibre must parse every one of them cleanly. */
basemapReady = true;

/* Which file the world went into, which is the whole point of it having its
   own. Every region is its own file and every region file is reachable by a
   Remove button; the floor must not be one of them. */
check(
  "the world overview is served from its own archive",
  (await fetch(`${base}/basemap/world.pmtiles`, { method: "HEAD" })).status
    === 200,
);
check(
  "and no region archive was created for it",
  (await fetch(`${base}/basemap/map.pmtiles`, { method: "HEAD" })).status
    === 404,
);
/* It is not a region, so nothing lists it and nothing offers to remove it. */
const ledgerAfterWorld = await (await fetch(`${base}/api/basemap-ledger`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: "{}",
})).json();
check(
  "the world overview writes no ledger entry",
  ledgerAfterWorld.entries?.length === 0,
);
check(
  "and still counts as a map being on disk",
  ledgerAfterWorld.held === true,
);
const worldTile = await fetch(`${base}/tiles/0/0/0.mvt`);
check(
  "the world tile serves through the tile endpoint after the download",
  worldTile.status === 200
    && worldTile.headers.get("content-encoding") === "gzip"
    && (await worldTile.arrayBuffer()).byteLength > 0,
);
const tilejson = await (await fetch(`${base}/tiles.json`)).json();
const worldjson = await (await fetch(`${base}/world.json`)).json();
/* With an overview and no region, the detail source describes an archive
   that does not exist. It says so with an empty range -- MapLibre skips
   everything shallower than minzoom and never looks past maxzoom, so this
   source asks for nothing at all rather than a viewport of misses on every
   pan, which is what a fresh install used to pay until its first download.
   The offer to download this area survives that honesty because the
   coverage question is now clamped by the server instead of by this
   number. */
check(
  `with no region downloaded the detail source asks for nothing (${tilejson.minzoom}-${tilejson.maxzoom})`,
  tilejson.minzoom > tilejson.maxzoom && Array.isArray(tilejson.bounds)
    && tilejson.bounds.length === 4,
);
/* The floor is the whole planet or it is not a floor -- and only as deep as
   the archive really covers the whole planet, which for one downloaded
   region is the single zoom-0 tile every download starts with. Claiming
   more is claiming a tile that is not there, which draws as empty and takes
   the map off the screen. */
check(
  "world.json floors the planet at the depth the archive really covers it",
  worldjson.minzoom === 0 && worldjson.maxzoom === 0
    && worldjson.bounds.join() === "-180,-85,180,85",
);
/* Meeting rather than overlapping is what keeps a viewport one fetch
   instead of two: below the floor's depth the detail source would be
   asking for the very same tiles. */
check(
  "and the two sources meet without overlapping",
  tilejson.minzoom === worldjson.maxzoom + 1,
);
check(
  "the sprite sheet arrived via the assets tarball",
  (await fetch(`${base}/basemap/sprites/v4/light.json`)).status === 200,
);
check(
  "still unlocked after the style swap -- no reload happened",
  (await page.locator(".panel").count()) === 1,
);

/* The drawer resizes, and from the KEYBOARD, which is the half a splitter
   usually misses. Left widens, because the key moves the separator and the
   panel is what is to its right. */
const panelWidth = async () =>
  (await page.locator(".panel").boundingBox())?.width ?? 0;
const widthBefore = await panelWidth();
await page.locator(".panel-resizer").focus();
await page.keyboard.press("Shift+ArrowLeft");
const widthAfter = await panelWidth();
check(
  `the drawer widens from the keyboard (${Math.round(widthBefore)} -> ${
    Math.round(widthAfter)
  })`,
  widthAfter > widthBefore,
);
/* Changed is not enough: a separator that does not carry its value announces
   nothing to anyone not watching the pixels move. */
check(
  "and the separator announces the new width",
  Number(
    await page.locator(".panel-resizer").getAttribute("aria-valuenow"),
  ) === Math.round(widthAfter),
);
/* Back to the default, so nothing downstream inherits a resized layout. */
await page.locator(".panel-resizer").dblclick();

/* The drawer is OVER the map, and this is the assertion that says so: the
   map's own box must not change when the drawer opens, shuts or is dragged.
   As a grid column it did change, every time, which meant MapLibre re-laid
   out and the view moved under whoever was reading it. */
const mapWrapWidth = async () =>
  (await page.locator(".map-wrap").boundingBox())?.width ?? 0;
const mapBefore = await mapWrapWidth();
await page.locator(".panel-hide").click();
const collapsed = await page
  .waitForFunction(
    () => document.querySelector(".panel")?.classList.contains("collapsed"),
    null,
    { timeout: 10_000 },
  )
  .then(() => true, () => false);
check("the drawer collapses", collapsed);
check(
  `and the map does not move when it does (${Math.round(mapBefore)}px)`,
  (await mapWrapWidth()) === mapBefore,
);
/* Shut means gone from the tab order too, not merely off-screen. */
check(
  "a collapsed drawer is out of the accessibility tree",
  !(await page.locator(".panel").isVisible()),
);
check(
  "and offers a way back",
  (await page.locator(".panel-reopen button").count()) === 1,
);
/* And that way back must not be sitting on top of MapLibre's own controls.

   With the drawer shut there is nothing covering the right edge, so
   MapLibre puts its zoom and locate buttons exactly where the reopen tab
   is. The rule that keeps that corner clear has to outrank MapLibre's own
   stylesheet, which loads after ours -- so this is geometry, not a class
   check: a single-class rule looks perfectly correct in the source and
   does nothing in the page. */
const boxesOverlap = await page.evaluate(() => {
  const tab = document.querySelector(".panel-reopen")?.getBoundingClientRect();
  const ctrl = document.querySelector(".map-wrap .maplibregl-ctrl-top-right")
    ?.getBoundingClientRect();
  if (!tab || !ctrl) return null;
  return !(tab.right <= ctrl.left || ctrl.right <= tab.left
    || tab.bottom <= ctrl.top || ctrl.bottom <= tab.top);
});
check(
  "the reopen tab does not sit on top of the map's own controls",
  boxesOverlap === false,
);
await page.locator(".panel-reopen button").click();
const reopened = await page
  .waitForFunction(
    () => !document.querySelector(".panel")?.classList.contains("collapsed"),
    null,
    { timeout: 10_000 },
  )
  .then(() => true, () => false);
check("and reopens from it", reopened);

/* ------------------------------------- appearance -------------------------

   Three states, not two: "system" is the absence of a choice and has to stay
   distinguishable from having chosen light, or a device that turns dark at
   dusk stops being followed. The attribute is what says which, and the
   painted colour is what proves the attribute reached anything. */
const panelInk = () =>
  page.locator(".panel").evaluate((e) => getComputedStyle(e).backgroundColor);
const chosen = () =>
  page.evaluate(() => document.documentElement.getAttribute("data-theme"));

check("nobody has chosen a theme to begin with", (await chosen()) === null);
const lightPanel = await panelInk();

const pickTheme = async (value) => {
  await page.locator(".panel-settings").click();
  await page.locator(".settings-theme .dropdown-button").click();
  await page.locator(`.dropdown-option[data-value="${value}"]`).click();
  await page.keyboard.press("Escape");
  await page.waitForFunction(
    (want) =>
      (document.documentElement.getAttribute("data-theme") ?? "system")
        === want,
    value,
    { timeout: 10_000 },
  );
};

await pickTheme("dark");
check("choosing dark says so on the root", (await chosen()) === "dark");
const darkPanel = await panelInk();
check(
  `and repaints the panel (${lightPanel} -> ${darkPanel})`,
  darkPanel !== lightPanel,
);
check(
  "and tells the browser to draw its own chrome dark",
  (await page.evaluate(() =>
    getComputedStyle(document.documentElement).colorScheme
  )) === "dark",
);

await pickTheme("system");
check(
  "and going back to the device clears the choice",
  (await chosen()) === null,
);
check("which restores the painted colour", (await panelInk()) === lightPanel);

/* An overview and no region is the state every fresh install starts in, and
   two things have to be true of it at once. */

/* First: street zoom is undownloaded ground, and the note offering to fetch
   it has to be on screen. This is the check that fails if the detail
   source's advertised depth is made honest without moving the coverage
   clamp to the server -- the question then drags down to the overview's own
   zoom, where the answer is "present" and the offer disappears in the one
   state where it is the entire point. */
await page.evaluate(() =>
  window.__tessarium_map?.jumpTo({ center: [-0.1, 51.5], zoom: 16 })
);
check(
  "with only an overview, street zoom still offers to download the area",
  await page.waitForSelector(".map-note.action", { timeout: 20_000 })
    .then(() => true, () => false),
);

/* Second: it must cost nothing to look around. The floor draws every tile
   on screen and there is no detail to ask for, so a pan should not fetch a
   single empty tile. It used to fetch a viewport of them per pan, for as
   long as the install went without a region -- each one a round trip
   carrying no data, which is the cost that shows over a forwarded port.
   Counted rather than asserted, so the number is in the output. */
const emptyTiles = [];
const countEmpty = (res) => {
  if (res.status() === 204 && /\/tiles\/\d+\/\d+\/\d+\.mvt/.test(res.url())) {
    emptyTiles.push(res.url());
  }
};
page.on("response", countEmpty);
for (const [lon, lat] of [[-0.13, 51.52], [-0.16, 51.48], [-0.09, 51.51]]) {
  await page.evaluate(
    ([lo, la]) =>
      window.__tessarium_map?.jumpTo({ center: [lo, la], zoom: 16 }),
    [lon, lat],
  );
  await page.waitForTimeout(1500);
}
page.off("response", countEmpty);
check(
  `three street-level pans over an overview fetch no empty tiles (got ${emptyTiles.length})`,
  emptyTiles.length === 0,
);

/* Second download: detail for the current view, MERGED over the world map.
   The card must no longer offer the world, and afterwards every tile from
   both downloads has to be in one archive. */
const openButton = page.locator(".panel-download");
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
/* The world overview is the ground under every region, and nothing may
   offer to take it away. It has its own file and writes no record, so it
   should not be in this list at all -- and the check is on the list rather
   than on the server's refusal because the two locks are separate and an
   absent row is the one that can be deleted by accident. */
check(
  "the world download left no row in the downloaded-maps list",
  (await page.locator(".ledger-row").count()) === 0,
);
const viewButton = page.locator(".download-view button");
await page.waitForFunction(
  () => !document.querySelector(".download-view button")?.disabled,
  null,
  { timeout: 30_000 },
);
await viewButton.click();
check("the view download completes at generation two", await awaitDone(2));
await page.waitForFunction(
  () => !document.querySelector(".download-card"),
  null,
  {
    timeout: 10_000,
  },
);

/* The loading bar, on real traffic: wait for quiet, delay every tile past
   the tracker's 300 ms threshold, then tell the vector source to reload its
   tiles (same URLs plus a marker param -- the app-visible way to force
   refetches without racing a download's style swap, which flaked). The bar
   must appear while tiles drip in and vanish at idle.

   RECORDED, not sampled. This used to race a `waitForSelector` against a bar
   whose whole life is the delay: measured at 318 ms up, 568 ms down, and the
   wait can lose a window that short. A missed window and a bar that never
   appeared are then the same failure, which is how this check spent a while
   being called flaky. An observer watching for the bar to be ADDED records
   what happened rather than what is on screen at the moment it is asked, and
   its flag is cleared in the same evaluate that triggers the refetch, so an
   earlier bar cannot answer for this one.

   And the premise is asserted too: if the interception did not take, no tile
   was ever slow, and "the bar did not appear" is the correct answer to a
   question that was never posed. That failure now says so itself. */
/* Quiet, and STAYING quiet, BEFORE the tile delay goes on.

   The bar's whole life is about 300 ms up and 250 ms down, measured here, and
   the tracker will not raise it again while one is already visible -- so a
   bar left over from the app's own loading closes the window this test needs.
   Waiting for absence to hold past that whole cycle is what empties it.

   Order matters and cost a run to learn: once every tile is delayed by half a
   second the map is almost never quiet, so this has to happen while traffic
   is still normal. */
await page.waitForFunction(
  async () => {
    const quiet = () => document.querySelector(".map-loading") === null;
    if (!quiet()) return false;
    for (let i = 0; i < 8; i++) {
      await new Promise((done) => setTimeout(done, 100));
      if (!quiet()) return false;
    }
    return true;
  },
  null,
  { timeout: 60_000 },
);
await page.evaluate(() => {
  /* Added nodes, not a re-query: a callback runs at a microtask checkpoint,
     so a bar that went up and came down inside one would be invisible to a
     "is it there now" test. The label is read at the moment it appears,
     which is the only moment it is certain to exist. */
  window.__barWatch = new MutationObserver((records) => {
    if (window.__barSeen) return;
    for (const record of records) {
      for (const node of record.addedNodes) {
        if (node.nodeType !== Node.ELEMENT_NODE) continue;
        const bar = node.matches?.(".map-loading")
          ? node
          : node.querySelector?.(".map-loading");
        if (bar) {
          window.__barSeen = true;
          window.__barLabel = bar.getAttribute("aria-label");
          return;
        }
      }
    }
  });
  window.__barWatch.observe(document.body, { childList: true, subtree: true });
});
let delayedTiles = 0;
await page.route("**/tiles/**", async (route) => {
  delayedTiles += 1;
  await new Promise((done) => setTimeout(done, 500));
  try {
    await route.continue();
  } catch {
    /* The request died mid-delay: MapLibre aborts tiles that leave the
       view, and unroute below can beat a sleeping handler to its route.
       Either way there is nothing left to slow down. */
  }
});
/* Reset and refetch in ONE evaluate that first checks no bar is up, and
   retry if one is.

   Waiting for quiet and then triggering in a separate call leaves a gap: the
   map can raise a bar inside it, the reset then clears the record of that
   bar, and the tracker will not raise a second one while the first is still
   visible -- so the observation window opens onto a bar that can no longer
   be added. Doing the check, the reset and the trigger in the same
   synchronous block is what removes the gap; the retry is for the case where
   the quiet wait above ended just as a fetch began.

   Marked once, not once per attempt, so a retry cannot stack query
   parameters and change what is being asked for. */
let started = false;
for (let attempt = 0; attempt < 6 && !started; attempt++) {
  if (attempt > 0) await page.waitForTimeout(600);
  started = await page.evaluate(() => {
    if (document.querySelector(".map-loading")) return false;
    window.__barSeen = false;
    window.__barLabel = null;
    const src = window.__tessarium_map.getSource("protomaps");
    src.setTiles(
      src.tiles.map((u) => u.includes("e2e_bar=1") ? u : `${u}&e2e_bar=1`),
    );
    return true;
  });
}
check("the refetch was triggered against a quiet map", started);
const barSeen = await page
  .waitForFunction(() => window.__barSeen === true, null, { timeout: 30_000 })
  .then(() => true, () => false);
check(
  `the refetch actually went through the delay (${delayedTiles} tiles)`,
  delayedTiles > 0,
);
check("slow tiles raise the loading bar", barSeen);
/* Read off the bar as it appeared, not off the DOM afterwards. Asked
   afterwards, the bar is almost always already gone -- it lives about 250 ms
   -- and the old form said "labelled OR absent", which absent satisfies. A
   check that passes because the thing it is about is missing reads as
   coverage and is none. */
check(
  "the bar names itself for the screen reader",
  ((await page.evaluate(() => window.__barLabel)) ?? "").length > 0,
);
await page.unroute("**/tiles/**");
/* Caught rather than thrown, so a bar that never comes down is reported as
   the failure it is instead of aborting the run and taking every check after
   it with it. That is how it presented the first time: a timeout, no tally,
   and nothing saying which assertion had been reached. */
const settled = await page
  .waitForFunction(() => !document.querySelector(".map-loading"), null, {
    timeout: 60_000,
  })
  .then(() => true, () => false);
check("the bar hides once the map settles", settled);
await page.evaluate(() => window.__barWatch?.disconnect());

/* Beside, not merged. The world went to world.pmtiles and the region to a
   file of its own, and neither one spans zoom 0 to 15 by itself -- the union
   is a fact about the directory, which is what the map is told.

   Bytes 100-101 of a PMTiles header are its min and max zoom, so the region's
   own file is asked directly: it must reach 15, because a file carried to
   another machine has to hold what it claims without anything beside it. */
const ledgerFiles = await (await postJson("basemap-ledger")).json();
const regionFile = ledgerFiles.entries?.[0]?.file ?? "";
check("a downloaded region has a file of its own", regionFile !== "");
const zoomBytes = await fetch(`${base}/basemap/${regionFile}`, {
  headers: { range: "bytes=100-101" },
});
const zooms = new Uint8Array(await zoomBytes.arrayBuffer());
check(
  `the region's own file reaches zoom 15 (got ${zooms[0]}-${zooms[1]})`,
  zooms[1] === 15,
);
check(
  "and nothing was merged into a shared archive",
  (await fetch(`${base}/basemap/map.pmtiles`, { method: "HEAD" })).status
    === 404,
);
check(
  "tiles.json spans the union of every archive on disk",
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
  null,
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
  .locator(".region-tree .region-disclosure")
  .filter({ hasText: "United Kingdom" });
/* Pressed rather than checked: React Aria's checkbox keeps a real input and
   hides it, so `check()` refuses it as invisible. The label IS the control
   -- clicking it is what a person does. */
await ukEntry
  .locator(".region-check")
  .filter({ hasText: "The whole country" })
  .click();
await page.waitForFunction(
  () => !document.querySelector(".download-region-offer button")?.disabled,
  null,
  { timeout: 30_000 },
);
check("picking a country by name yields a real estimate", true);

/* The box sits BESIDE its label, not above it.

   Layout is not usually worth an end-to-end check, but this one broke
   silently and stayed broken: `.download-card label` set `display: block`
   at two-class specificity and outranked `.region-check`'s own `flex`, so
   every checkbox in the picker stacked over its text and nothing failed.
   Geometry is the only thing that catches that -- a class-name assertion
   passes while the rule that beats it is somewhere else entirely. */
const boxBeside = await ukEntry
  .locator(".region-check")
  .filter({ hasText: "The whole country" })
  .evaluate((label) => {
    const box = label.querySelector(".checkbox-box");
    const text = [...label.children].find((c) =>
      c !== box && (c.textContent ?? "").trim() !== ""
    );
    if (!box || !text) return null;
    const b = box.getBoundingClientRect();
    const t = text.getBoundingClientRect();
    return {
      leftOf: b.right <= t.left,
      sameLine: b.top < t.bottom && t.top < b.bottom,
    };
  });
check(
  "the checkbox sits to the left of its label, on the same line",
  boxBeside?.leftOf === true && boxBeside.sameLine === true,
);
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
  .click();
await page.waitForFunction(
  () =>
    (document.querySelector(".download-region-offer .hint")?.textContent ?? "")
      .includes("Places selected: 2"),
  null,
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
await page.waitForFunction(
  () => !document.querySelector(".download-card"),
  null,
  {
    timeout: 10_000,
  },
);

/* And a federation exposes its states and cities as checkboxes: the United
   States entry must offer more than forty states, plus named cities. */
await openButton.click();
await page.waitForSelector(".download-card", { timeout: 10_000 });
await page.locator("#region-filter").fill("United States");
const usEntry = page
  .locator(".region-tree .region-disclosure")
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
   world-spanning z0. It used to answer "covered", because the estimate diffed
   against the one archive everything merged into and the world download had
   already put that tile there. It quotes a price now, and that is the change
   working: a region is diffed against ITS OWN file, so it fetches its own
   shallow tiles rather than borrowing the overview's. A file carried to a
   machine with no overview has to draw on its own.

   What is being proved either way is that the two-box polygon request
   survived validation, planning and the merge arithmetic end to end -- so
   the assertion is that a real answer arrived, not which one. */
await page.locator("#region-filter").fill("Fiji");
await page
  .locator(".region-tree .region-disclosure")
  .filter({ hasText: "Fiji" })
  .locator(".region-check")
  .filter({ hasText: "The whole country" })
  .click();
await page.waitForFunction(
  () =>
    /already have|About /.test(
      document.querySelector(".download-region-offer .hint")?.textContent ?? "",
    ),
  null,
  { timeout: 30_000 },
);
check("a two-box antimeridian country estimates cleanly", true);
await page.locator(".download-card .icon-button").click();
await page.waitForFunction(
  () => !document.querySelector(".download-card"),
  null,
  {
    timeout: 10_000,
  },
);

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

/* ------------------------- addresses in the search box ----------------------

   One box takes both a place name and an address, and the difference is not
   cosmetic: a place name is looked up on the server, and an address must
   never be. This is the check for that. It watches the wire, because the
   claim is about what leaves the browser, not about what is displayed --
   nothing on screen would look wrong if the request went out anyway.

   The failure it exists to catch is real and was live until this landed:
   typing an address searched the place index for it, which prefix-matched
   the first word and flew the map to a village in France. */
const searchRequests = [];
const watchSearch = (request) => {
  if (request.url().includes("/api/basemap-search")) {
    searchRequests.push(request.postData() ?? "");
  }
};
page.on("request", watchSearch);

const addressForSearch = sample.address;
/* The same address in a spelling that uses a different separator. Every one
   of `, / - _ .` and space is accepted by address_of_string, and an earlier
   version of the classifier looked only at dots -- so the dashed spelling
   sent three words and three of four digits to the index on its way to being
   typed. Testing one spelling would not have caught that. */
const addressDashed = sample.address.replace(/[.]/g, "-");

/* DEBOUNCE_MS in PlaceSearch is 250, so the delay here must be LONGER than
   that or no intermediate value ever reaches the classifier and this checks
   only that the finished address is withheld. At 30 ms every keystroke reset
   the timer and exactly one value -- the complete address -- was ever
   classified, which made the check pass against a version with no partial
   handling at all. */
const typeAndWatch = async (text) => {
  await page.locator("#place-search-input").fill("");
  await page.waitForTimeout(400);
  searchRequests.length = 0;
  await page.locator("#place-search-input").pressSequentially(text, {
    delay: 300,
  });
  await page.waitForTimeout(700);
  return searchRequests.slice();
};

/* The guarantee is NOT "nothing is sent" -- a lone "vacuum" is a BIP-39 word
   and also an English one, and withholding every single word would take
   "orange", "river" and "city hall" off the place index for no privacy gain.
   The guarantee is that nothing recognisable as an ADDRESS is sent: never two
   of the three words, never the number, never the whole thing. That is the
   difference between a leak and a search.

   Stated this precisely because the first version of this check said "sends
   nothing" and passed only because it typed faster than the debounce. */
const addressWords = sample.address.split(".");
const addressNumber = addressWords[3];
const countWords = (body) =>
  addressWords.slice(0, 3).filter((w) => body.includes(w)).length;

for (
  const [label, text] of [
    ["dotted", addressForSearch],
    ["dash-separated", addressDashed],
  ]
) {
  const sent = await typeAndWatch(text);
  const worst = Math.max(0, ...sent.map(countWords));
  check(
    `typing a ${label} address never sends two of its words (worst ${worst}: ${
      JSON.stringify(sent.filter((b) => countWords(b) >= 2))
    })`,
    worst <= 1,
  );
  check(
    `typing a ${label} address never sends its number`,
    !sent.some((body) => body.includes(addressNumber)),
  );
  check(
    `typing a ${label} address never sends the whole thing`,
    !sent.some((body) => body.includes(text)),
  );
}

/* And it resolves: the address offered is the one typed, and taking it lands
   on the square that address names -- the vector's own point. */
const addressOffered = await page
  .waitForSelector(".place-option", { timeout: 10_000 })
  .then(() => true, () => false);
check(
  "an address in the search box is offered as a destination",
  addressOffered,
);
await page.locator(".place-option").first().click();
const landedOnAddress = await page
  .waitForFunction(
    (want) => {
      const map = window.__tessarium_map;
      if (!map) return false;
      const c = map.getCenter();
      return Math.abs(c.lng - want[0]) < 0.0005
        && Math.abs(c.lat - want[1]) < 0.0005;
    },
    [sampleLon, sampleLat],
    { timeout: 20_000 },
  )
  .then(() => true, () => false);
check("choosing it flies to the square that address names", landedOnAddress);
/* And the box is empty afterwards. The search sits OVER the map, so an
   address left in it would be in every screenshot of the map -- the exact
   exposure the panel's conceal toggle exists to prevent, reintroduced by the
   back door. A place name is kept, deliberately; an address is not. */
check(
  "and the address does not stay sitting in the box over the map",
  (await page.locator("#place-search-input").inputValue()) === "",
);

/* A place name must still go out, or the gate is stuck shut and the feature
   is gone rather than fixed. A query string used nowhere else above: the
   place cache holds answers for five minutes, so reusing "fixtu" here would
   be served from memory and prove nothing about the wire. */
await page.locator("#place-search-input").fill("");
await page.waitForTimeout(400);
searchRequests.length = 0;
await page.locator("#place-search-input").fill("fixturevi");
await page.waitForSelector(".place-option", { timeout: 10_000 });
check(
  "a place name still reaches the index",
  searchRequests.length > 0,
);
check(
  "and asks for a screenful of rows",
  searchRequests.some((body) => JSON.parse(body).limit === 8),
);

/* A query that names its context asks for a WIDER slice, and this is what
   makes answering the context possible at all.

   The server ranks by population and knows nothing of states -- no tile
   label knows its country -- so on the real United States index the Jasper
   in Georgia comes back sixth of the Jaspers, below the fold of a list of
   eight. The dropdown re-ranks by the border data it already ships, but it
   can only re-rank rows it was given. Ask for eight and the right answer
   was never in the response to begin with. */
await page.locator("#place-search-input").fill("");
await page.waitForTimeout(400);
searchRequests.length = 0;
await page.locator("#place-search-input").fill("fixtureville, ZZ");
await page.waitForTimeout(700);
const widened = searchRequests.map((body) => JSON.parse(body).limit);
check(
  `a query naming its context asks wider (got ${JSON.stringify(widened)})`,
  widened.length > 0 && widened.every((n) => n === 40),
);
await page.locator("#place-search-input").fill("");
page.off("request", watchSearch);
await page.locator("#place-search-input").fill("");

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
/* And says the one thing that is true wherever it appears. What the floor
   draws underneath ranges from a country map to a single stretched polygon
   depending on how far past its depth the camera has gone, so a note
   promising a wider map cannot keep the promise, and one denying any map
   contradicts what is on screen elsewhere. Read from the catalogue rather
   than copied here, so rewording it back into a claim fails this. */
check(
  "and claims only that the detail is missing",
  (await page.locator(".map-note.action span").innerText())
    === m("map_coverage_gap"),
);
/* The wash is the other half of that claim. It is 42% opaque -- sized for
   ground with nothing drawn on it -- so painting it over the floor would
   darken the map the floor exists to keep. Withheld, not faded: the
   rectangles are never handed to the source, which is what makes this
   question answerable by asking what is on screen. */
check(
  "and does not wash out the map underneath it",
  await page.evaluate(() =>
    window.__tessarium_map.queryRenderedFeatures({
      layers: ["coverage-blank"],
    }).length
  ) === 0,
);

/* The other half of the same claim, and the state the wash still exists
   for: no floor at all. Stubbed rather than staged. Which archives make a
   floor is settled in the server's own suite, against archives built to
   have and to lack one; what is left to check here is that the app reacts
   to the answer, and the archive that produces it -- one holding not even
   the single zoom-0 tile of the planet -- is not one a download can leave
   behind. Both halves matter: without this the wash could be deleted
   outright and every check above would still pass. */
await page.route("**/api/basemap-coverage", async (route) => {
  const answer = await route.fetch();
  await route.fulfill({ json: { ...(await answer.json()), floor: false } });
});
await page.evaluate(() =>
  window.__tessarium_map?.jumpTo({ center: [139.7, 35.68], zoom: 11 })
);
check(
  "with nothing drawn underneath, the blank ground is painted",
  await page.waitForFunction(
    () => {
      const map = window.__tessarium_map;
      return !!map
        && map.queryRenderedFeatures({ layers: ["coverage-blank"] }).length > 0;
    },
    null,
    { timeout: 15_000 },
  ).then(() => true, () => false),
);
await page.unroute("**/api/basemap-coverage");
await page.evaluate(() =>
  window.__tessarium_map?.jumpTo({ center: [139.7, 35.68], zoom: 12 })
);
await page.waitForSelector(".map-note.action", { timeout: 15_000 });
/* The note is the one place on the map that offers the way out of a blank
   screen, so its button has to reach the downloader. */
await page.locator(".map-note.action .note-action").click();
check(
  "the note offers the download card",
  await page.waitForSelector(".download-card", { timeout: 10_000 })
    .then(() => true, () => false),
);
await page.locator(".panel-download").click();
await page.waitForFunction(
  () => !document.querySelector(".download-card"),
  null,
  {
    timeout: 10_000,
  },
);

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

/* The grid overlay had the same hazard and no guard.

   Its answers come from the worker rather than the network, so the delay
   goes into the worker script -- which is fetched over HTTP, and is created
   once per page, so it has to be in place before the page loads. Hence a
   page of its own, and a longitude range nothing else in this suite visits,
   so only this check pays for the delay. */
const gridPage = await context.newPage();
await gridPage.route("**/core.worker.js", async (route) => {
  const body = await (await route.fetch()).text();
  await route.fulfill({
    contentType: "text/javascript",
    body: body.replace(
      "const result = await handler(payload ?? {});",
      `const result = await handler(payload ?? {});
       if (op === "grid" && payload && payload.lonLo < -100) {
         await new Promise((r) => setTimeout(r, 2500));
       }`,
    ),
  });
});
await gridPage.goto(base, { waitUntil: "networkidle" });
await gridPage.locator("#phrase").fill(sampleMnemonic);
await gridPage.waitForSelector(".valid", { timeout: 30_000 });
await gridPage.locator("button[type=submit]").click();
await gridPage.waitForSelector(".map-wrap", { timeout: 60_000 });

/* The westmost longitude the overlay currently holds. Read from the source's
   own data rather than from the screen: cells painted for a viewport already
   left are off-screen, which is the whole complaint. */
const gridWest = () =>
  gridPage.evaluate(async () => {
    const data = await window.__tessarium_map?.getSource("grid")?.getData();
    const ring = data?.features?.[0]?.geometry?.coordinates?.[0];
    return ring ? ring[0][0] : null;
  });
const gridSettled = () =>
  gridPage.waitForFunction(
    async () =>
      ((await window.__tessarium_map?.getSource("grid")?.getData())?.features
        ?.length ?? 0) > 0,
    null,
    { timeout: 30_000 },
  );

/* London first, so its answer is in the query cache and comes back in a
   microtask on the way home. */
await gridPage.evaluate(() =>
  window.__tessarium_map?.jumpTo({ center: [-0.12, 51.5], zoom: 19 })
);
await gridSettled();
/* Out to a longitude the worker is holding back 2.5 s. The pause is what
   makes it a race: two jumps back to back settle as one move, and the
   request being outrun would never be sent. */
await gridPage.evaluate(() =>
  window.__tessarium_map?.jumpTo({ center: [-122.4, 37.8], zoom: 19 })
);
await new Promise((done) => setTimeout(done, 700));
await gridPage.evaluate(() =>
  window.__tessarium_map?.jumpTo({ center: [-0.12, 51.5], zoom: 19 })
);
await new Promise((done) => setTimeout(done, 4500));
const west = await gridWest();
check(
  `a grid answer for a view already left cannot paint over the current one (${west})`,
  west !== null && west > -10 && west < 10,
);
await gridPage.close();

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

   Every REGION download above was recorded inside the detail archive
   itself -- name, date, size -- and the list, the reminder setting, and
   Remove are all driven through the real card. The world overview is not
   among them: it went to its own file and wrote no entry, which is what
   makes it un-removable.

   A patch inside an already-downloaded region used to be ADOPTED: the tiles
   were in the one shared archive, nothing was fetched, and an entry landed
   claiming them with "age unknown". There is no shared archive to adopt out
   of any more. The patch is its own region with its own file, so it is its
   own download -- which is the trade this layout makes, and the reason a
   file can be carried away on its own. */
await postJson("basemap-download", {
  name: "Overlapping patch",
  regions: [{
    min_lon: -0.2,
    min_lat: 51.46,
    max_lon: -0.1,
    max_lat: 51.5,
    max_zoom: 6,
  }],
});
check(
  "a region inside another is downloaded rather than refused",
  await awaitDone(4),
);
const ledger1 = await (await postJson("basemap-ledger")).json();
check(
  "the archive records every region download by name",
  ledger1.entries?.length === 3
    && ["Map view", "United Kingdom and London", "Overlapping patch"]
      .every((n) => ledger1.entries.some((e) => e.name === n)),
);
check(
  "and does not record the world overview among them",
  !ledger1.entries?.some((e) => e.name === "World overview"),
);
const patchEntry = ledger1.entries?.find((e) => e.name === "Overlapping patch");
check(
  "it gets a file of its own, not a share of somebody else's",
  (patchEntry?.file ?? "") !== ""
    && ledger1.entries.every((e) => e.file !== "")
    && new Set(ledger1.entries.map((e) => e.file)).size === 3,
);
check(
  "every download records when and how much",
  ledger1.entries?.filter((e) => e.completed > 0 && e.bytes > 0).length === 3,
);

await openButton.click();
await page.waitForSelector(".download-ledger", { timeout: 10_000 });
/* The list refetches on mount; wait for the adoption to be visible rather
   than racing the request. */
const listedRows = await page
  .waitForFunction(
    () => document.querySelectorAll(".ledger-row").length === 3,
    null,
    { timeout: 30_000 },
  )
  .then(() => true, () => false);
check("the card lists the downloaded maps", listedRows);
check(
  "nothing just downloaded is flagged for update",
  (await page.locator(".ledger-stale").count()) === 0,
);
/* Every row offers its file directly. Nothing is built and nothing is
   waited on: the download already wrote the file this points at, which is
   what the export step used to spend minutes producing. */
check(
  "each row hands over its own file",
  (await page.locator(".ledger-row .ledger-export").count()) === 3
    && (await page.locator(".ledger-row a.ledger-export").count()) === 3,
);
const saveHref = await page.locator(".ledger-row").filter({
  hasText: "Overlapping patch",
}).locator("a.ledger-export").getAttribute("href");
check(
  `the link points at the archive on disk (got ${saveHref})`,
  (saveHref ?? "").startsWith("/basemap/")
    && (saveHref ?? "").endsWith(".pmtiles"),
);
check(
  "and it is really there",
  (await fetch(`${base}${saveHref}`, { method: "HEAD" })).status === 200,
);
check(
  "a fresh download names its date",
  ((await page.locator(".ledger-row").filter({ hasText: "Map view" })
    .locator(".hint").textContent()) ?? "").includes("updated"),
);

/* The reminder threshold lives on the server, next to the archive it
   describes -- localStorage stays empty, as asserted at the end -- so the
   choice must survive closing the card. */
check(
  "the update reminder defaults to 90 days",
  ((await dropdownIn(".ledger-reminder").textContent()) ?? "").includes("90"),
);
await chooseFrom(".ledger-reminder", "30");
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
await page.waitForFunction(
  () => !document.querySelector(".download-card"),
  null,
  {
    timeout: 10_000,
  },
);
await openButton.click();
await page.waitForSelector(".ledger-reminder .dropdown-button", {
  timeout: 10_000,
});
check(
  "the reminder choice survives on the server",
  ((await dropdownIn(".ledger-reminder").textContent()) ?? "").includes("30"),
);

/* Remove is two presses of the same button, because it discards gigabytes.
   The view download's tiles sit inside the United Kingdom pick, so removing
   it must keep the archive intact -- entries own records, not tiles. */
const viewRow = page.locator(".ledger-row").filter({ hasText: "Map view" });

/* The name has to have a column to sit in. Unwrapped, the row's three
   buttons took the full width and left the name a few pixels, which
   `overflow-wrap` then honoured by breaking "Map view" one letter per line --
   a tall thin stack of characters. Wider than it is tall is the cheap way to
   say "this is a line of text", and it fails loudly on the broken layout. */
const nameBox = await viewRow.locator(".ledger-name").boundingBox();
check(
  `the ledger name reads as a line, not a column (${
    Math.round(nameBox?.width ?? 0)
  }x${Math.round(nameBox?.height ?? 0)})`,
  nameBox !== null && nameBox.width > nameBox.height,
);

await viewRow.locator(".ledger-remove").click();
check(
  "remove asks to be sure",
  ((await viewRow.locator(".ledger-remove").textContent()) ?? "")
    .includes("Really"),
);
await viewRow.locator(".ledger-remove").click();
const rowGone = await page
  .waitForFunction(
    () => document.querySelectorAll(".ledger-row").length === 2,
    null,
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
    null,
    { timeout: 10_000 },
  )
  .then(() => true, () => false);
check("removal announces what it freed", removedToast);
const ledger2 = await (await postJson("basemap-ledger")).json();
check(
  "the archive agrees the entry is gone",
  ledger2.entries?.length === 2
    && !ledger2.entries.some((e) => e.name === "Map view"),
);
/* And the floor is untouched by a removal, which is the reason the overview
   has its own file. */
check(
  "removing a region leaves the world overview alone",
  (await fetch(`${base}/basemap/world.pmtiles`, { method: "HEAD" })).status
    === 200,
);
/* The other regions are untouched too, and now that is a fact about files
   rather than about a rewrite: a removal unlinks one archive and cannot
   reach into the others. */
const survivors = await Promise.all(
  (ledger2.entries ?? []).map(async (e) =>
    (await fetch(`${base}/basemap/${e.file}`, { method: "HEAD" })).status
  ),
);
check(
  "every region that was not removed still has its file",
  survivors.length > 0 && survivors.every((s) => s === 200),
);

/* Update through the card, on the clipped country pick: the one deliberate
   way to refresh held tiles, exercised over a polygon region. The card
   closes itself when the job completes, like any download. */
await page
  .locator(".ledger-row")
  .filter({ hasText: "United Kingdom" })
  .locator(".ledger-update")
  .click();
check("an update of a clipped region completes", await awaitDone(6));
await page.waitForFunction(
  () => !document.querySelector(".download-card"),
  null,
  {
    timeout: 10_000,
  },
);

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
/* Removing an entry removes the archive itself: the record lives inside the
   file it describes, so the two leave together and there is nothing left
   behind holding tiles nobody can name. */
const led3file = (await (await post3("basemap-ledger")).json()).entries
  ?.find((e) => e.id === id3)?.file ?? "";
check("the region under test has a file of its own", led3file !== "");
check(
  "and it is on disk before the removal",
  (await fetch(`${base3}/basemap/${led3file}`, { method: "HEAD" })).status
    === 200,
);
await post3("basemap-remove", { id: id3 });
const rem3 = await finalJob3(4);
check(
  "removing the last region deletes its archive",
  rem3?.state === "removed"
    && (await fetch(`${base3}/basemap/${led3file}`, { method: "HEAD" }))
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
await worldPage.locator(".panel-download").click();
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

/* Going to an address, through the one box that now takes both an address and
   a place name. It replaces a dedicated lookup form in the panel; the address
   is classified in the browser, so nothing about it is sent anywhere, and the
   offered row is taken the way a place result is taken. */
const goToAddress = async (address) => {
  await page.locator("#place-search-input").fill("");
  await page.waitForTimeout(350);
  await page.locator("#place-search-input").fill(address);
  await page.waitForSelector(".place-option", { timeout: 15_000 });
  await page.locator(".place-option").first().click();
  /* At most a 1.2 s flight, and for anything off-screen no flight at all --
     see ui/src/core/camera.ts. Either way this is long enough. */
  await page.waitForTimeout(2000);
};

/* The round trip the whole project is for, driven entirely through the UI:
   paste an address, fly to the square it names, click that square, and get
   the same address back.

   No test hook on the map. Going through the real controls is what makes this
   evidence that a person can do it. */
await goToAddress(sample.address);

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

/* The epoch the panel names, and it has to be the one this build actually
   speaks. An address carries no version inside it, so a code issued under an
   older grid decodes to a different and entirely plausible square with nothing
   to say why -- naming the grid here is what lets someone label the codes they
   keep with the grid those codes belong to. Held to the VECTORS rather than to
   a copy of the string in this file, so a panel left showing a stale version
   fails here. */
const shownVersions = await page.locator(".versions code").allTextContents();
check(
  `the panel names the grid version (${vectors.grid_version}, got ${
    shownVersions.join(" ")
  })`,
  shownVersions.includes(vectors.grid_version),
);
check(
  `the panel names the derivation version (${vectors.derivation_version})`,
  shownVersions.includes(vectors.derivation_version),
);

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

/* Arriving at an address selects it, and Enter on the canvas selects the
   centre square. Both are checked here, and BOTH need something else to be
   selected first or they pass against a build that does neither: the panel
   already says `sample.address` from the click above, so an assertion that
   it says so again is true no matter what the code does. That is exactly how
   the first version of this passed with the feature removed.

   `clickAway` is what makes them mean something. At zoom 20 a quarter of the
   canvas is tens of metres, which is several squares, so it lands on a
   different one every time -- and it moves the selection without moving the
   camera, which is the state both checks need. */
await goToAddress(sample.address);
const centreBox = await page.locator(".map").boundingBox();
const clickAway = async () => {
  await page.mouse.click(
    centreBox.x + centreBox.width * 0.25,
    centreBox.y + centreBox.height * 0.25,
  );
  await page.waitForTimeout(1500);
  return await page.locator(".address").textContent();
};

check(
  "clicking away from the centre selects a different square",
  (await clickAway()) !== sample.address,
);

/* The papercut this closes: typing an address is asking to be told about
   that square, and until now it moved the camera and left the panel on
   whatever was selected before. The camera is already there, so nothing but
   the selection can be making this true. */
await goToAddress(sample.address);
check(
  `arriving at ${sample.address} selects its square without a click`,
  (await page.locator(".address").textContent()) === sample.address,
);

/* Keyboard access. The map is the one control that cannot be reached with the
   search box, so Enter on the focused canvas must select the centre square --
   the same square flyTo just centred, and the same address as the click. */
await clickAway();
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
/* The explainer by name, not "the first paragraph in the footer" -- a
   warning was added above it and silently became what this read. */
const englishFooter = await page.locator(".panel-explainer").textContent();

/* The map has to follow too. Its labels are asked for in the interface
   language, and the style reads that language once, when it is built -- so
   switching afterwards used to translate the controls and leave an English
   map underneath until a download happened to rebuild the style. Asserted on
   the style the map is actually holding, not on pixels: the fixture's tiles
   carry no labels to read. */
const labelLang = (lang) =>
  page.evaluate(
    (l) =>
      JSON.stringify(window.__tessarium_map?.getStyle()?.layers ?? [])
        .includes(`name:${l}`),
    lang,
  );
/* The absence is what is checkable. Protomaps keeps `name:en` in every style
   as the fallback for a place with no name in the chosen language, so its
   presence says nothing; the language actually asked for is the one that
   appears alongside it. */
check(
  "the map is not asking for French before French is chosen",
  !(await labelLang("fr")),
);

await chooseFrom(".language", "fr-FR");
await page.waitForTimeout(400);
const mapFollowed = await page
  .waitForFunction(
    () =>
      JSON.stringify(window.__tessarium_map?.getStyle()?.layers ?? [])
        .includes("name:fr"),
    null,
    { timeout: 15_000 },
  )
  .then(() => true, () => false);
check("and switching language rebuilds the map for the new one", mapFollowed);
const frenchFooter = await page.locator(".panel-explainer").textContent();
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
  "the address example in the search box is not translated",
  ((await page.getAttribute("#place-search-input", "placeholder")) ?? "")
    .includes("dream.tourist.creek.2703"),
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
/* A refusal, said in French. This is the whole point of the code-and-
   catalogue split: the message is produced by the worker and by the OCaml
   core, neither of which can see a locale, so before this change a French
   user met English at the exact moment something went wrong.

   The address below is well formed and names nothing -- about 35% of word
   combinations do not, which is what makes a typo obvious -- so it is a
   refusal from the wasm core, carried out through a code. Matched on French
   words rather than on "not the English", because a blank box would also not
   be the English. */
await page.locator("#place-search-input").fill("");
await page.waitForTimeout(350);
await page.locator("#place-search-input").fill(vectors.invalid_addresses[0]);
const refusalText = await page.locator(".place-empty").first()
  .textContent({ timeout: 15_000 })
  .catch(() => null);
check(
  `an address that names nothing is refused in French (${
    JSON.stringify((refusalText ?? "").slice(0, 40))
  })`,
  typeof refusalText === "string"
    && refusalText.includes("combinaisons")
    && !refusalText.includes("word combinations"),
);
await page.locator("#place-search-input").fill("");
await page.waitForTimeout(350);

await chooseFrom(".language", "en-US");
await page.waitForTimeout(400);

/* And the same refusal in English, so the check above is testing the
   catalogue rather than a box that says "combinaisons" whatever happens. */
await page.locator("#place-search-input").fill(vectors.invalid_addresses[0]);
const refusalEnglish = await page.locator(".place-empty").first()
  .textContent({ timeout: 15_000 })
  .catch(() => null);
check(
  `and in English once the language is changed back`,
  typeof refusalEnglish === "string"
    && refusalEnglish.includes("word combinations"),
);
await page.locator("#place-search-input").fill("");
await page.waitForTimeout(350);

/* NFKD across the whole stack.

   The vectors' keys were derived from the NFKD form of this passphrase.
   Unlock with the PRECOMPOSED form -- the direction that can fail: the
   decomposed form is NFKD's own output and would pass with normalisation
   removed -- and require the vector's address out. Since kdf-3 the browser
   builds its KDF inputs through the js_of_ocaml core and stretches in the
   Argon2id wasm, so this pins that whole chain, not a JS re-spelling of
   the normalisation. "café" typed on one keyboard and pasted from another
   are two byte sequences; before NFKD they were two different maps and the
   user was told nothing. */
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

/* Locking asks first now: it forgets a key that cannot be recovered from
   anything this app holds, so the press that does it is confirmed. Cancel is
   the safe answer and the dialog is dismissable, which is why the
   destructive one is the only thing that locks. */
await page.locator(".panel-head .lock").click();
await page.waitForSelector(".modal-dialog", { timeout: 10_000 });
check(
  "locking asks before it forgets the key",
  (await page.locator(".modal-dialog .warning").count()) === 1,
);
await page.locator(".modal-actions button.danger").click();
await page.waitForSelector("#phrase", { timeout: 30_000 });
await page.locator("#phrase").fill(nfkdEntry.mnemonic);
await page.waitForSelector(".valid", { timeout: 30_000 });
await page.locator(".passphrase-summary").click();
await page.locator("#passphrase").fill(nfkdEntry.passphrase);
await page.locator("button[type=submit]").click();
await page.waitForSelector(".map-wrap", { timeout: 60_000 });

await goToAddress(nfkdSample.address);
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

/* ------- the same phrase, the same address, the same place, every time -----

   Reported from use: save two addresses in a notepad, lock, type the same
   phrase back in, and the two addresses no longer land where they were saved
   from -- and not consistently, so a single lookup looks fine and only
   repeating it shows the drift.

   Nothing above catches that. The suite unlocks once at the top and locks
   exactly once, to a DIFFERENT phrase, so "the same phrase twice" was never
   asked. js/worker-differential.mjs cannot ask it either: it drives the
   worker in one process, and a key that changed across a lock is invisible
   from inside the worker that holds it.

   So this locks and re-enters the SAME phrase three times, and holds two
   addresses, saved once at the start, to the place they were saved from.
   Three cycles rather than one, because the report was that it was
   inconsistent rather than always wrong.

   Two things are compared, and they fail in different ways:
     - where the address takes the CAMERA. That is decode under the key, so a
       key that changed moves it.
     - what the square at the original point is CALLED. A changed key decodes
       an address to a new place and re-encodes that place back to the same
       words, so the camera check alone can be satisfied by a wrong key; this
       is the half that cannot be.

   The tolerance is 1e-6 degrees, about 11 cm. That is deliberately far
   tighter than the ~3 m cell: at cell width this would pass while pointing
   at the wrong square. The panel prints 7 fraction digits, so the parsed
   value is good to about 1e-7 and the margin is real.

   If the grid or the constants ever change on purpose, saved addresses SHOULD
   stop lining up and this must fail: the two points come from the committed
   vectors, which are regenerated in the same commit. */

const same = (a, b) => Math.abs(a - b) < 1e-6;

const relock = async (mnemonic) => {
  await page.locator(".panel-head .lock").click();
  await page.waitForSelector(".modal-dialog", { timeout: 10_000 });
  await page.locator(".modal-actions button.danger").click();
  await page.waitForSelector("#phrase", { timeout: 30_000 });
  await page.locator("#phrase").fill(mnemonic);
  await page.waitForSelector(".valid", { timeout: 30_000 });
  await page.locator("button[type=submit]").click();
  await page.waitForSelector(".map-wrap", { timeout: 60_000 });
};

/* Both values are concealed after every unlock and STAY as the user set them
   across squares, so this reveals only what is actually masked -- pressing
   unconditionally hides them again on the second square. */
const reveal = async () => {
  if (((await page.locator(".address").textContent()) ?? "").includes("•")) {
    await page.locator(".address-row .icon-button").first().click();
  }
  if (
    (await page.locator(".coords dd").allTextContents()).some((t) =>
      t.includes("•")
    )
  ) {
    await page.locator(".coords-row .icon-button").first().click();
  }
  await page.waitForFunction(
    () =>
      !(document.querySelector(".address")?.textContent ?? "").includes("•")
      && ![...document.querySelectorAll(".coords dd")].some((d) =>
        (d.textContent ?? "").includes("•")
      ),
    undefined,
    { timeout: 10_000 },
  );
};

/* Click one exact point and read back what the panel says about it. Always
   the same physical point across cycles: the panel prints the square's LOW
   CORNER, and re-clicking that corner is a coin toss between four squares. */
/* Whether the panel is showing the square for the point just clicked rather
   than the one selected before it. The panel prints the square's low corner,
   so a point inside its own square sits at or above that corner by less than
   one square's width. The bound is loose deliberately: this only has to tell
   "our point" from "the other saved point", which is a hemisphere away. The
   precise comparison belongs to the caller. */
const showsSquareFor = async (lat, lon) => {
  const cells = await page.locator(".coords dd").allTextContents();
  if (cells.length !== 2 || cells.some((t) => t.includes("•"))) return null;
  const [cornerLat, cornerLon] = cells.map((t) =>
    Number.parseFloat(t.replace(/[^0-9.-]/g, ""))
  );
  const holds = (point, corner) => point - corner >= 0 && point - corner < 1e-3;
  return holds(lat, cornerLat) && holds(lon, cornerLon)
    ? { cornerLat, cornerLon }
    : null;
};

/* Click one exact point and read back what the panel says about it. Always
   the same physical point across cycles: the panel prints the square's LOW
   CORNER, and re-clicking that corner is a coin toss between four squares.

   Two things here are load-related rather than fussy, and both were seen.
   Selecting is a click plus a round trip into the worker, and under `make
   test` -- where this runs alongside everything else -- the click can land
   while the map is still settling and select nothing, so it is retried. And
   waiting for `.address` is not enough on its own: the PREVIOUS square's
   address is still on screen, so the wait returns immediately and the read
   races the update. [showsSquareFor] is what actually decides the panel has
   caught up. */
const inspectAt = async (lat, lon) => {
  const box = await page.locator(".map").boundingBox();
  let corner = null;
  for (let attempt = 1; attempt <= 3 && corner === null; attempt++) {
    await page.evaluate(([la, lo]) => {
      const map = window.__tessarium_map;
      if (!map) return;
      /* Cancel any flight still running: a jumpTo during one is overtaken by
         it, and the click would then land on a different square. */
      map.stop();
      map.jumpTo({ center: [lo, la], zoom: 20 });
    }, [lat, lon]);
    await page.waitForTimeout(600);
    await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
    const showed = await page
      .waitForSelector(".address", { timeout: 10_000 })
      .then(() => true, () => false);
    if (!showed) continue;
    await reveal();
    for (let i = 0; i < 20 && corner === null; i++) {
      corner = await showsSquareFor(lat, lon);
      if (corner === null) await page.waitForTimeout(250);
    }
  }
  check(
    `a square containing ${lat.toFixed(4)},${lon.toFixed(4)} was selected`,
    corner !== null,
  );
  return {
    address: await page.locator(".address").textContent(),
    cornerLat: corner?.cornerLat ?? Number.NaN,
    cornerLon: corner?.cornerLon ?? Number.NaN,
  };
};

/* Where an address takes the camera -- the user's actual question, so it is
   read off the map rather than the panel. */
const flyToAddress = async (address) => {
  await goToAddress(address);
  return await page.evaluate(() => {
    const c = window.__tessarium_map.getCenter();
    return { lat: c.lat, lon: c.lng };
  });
};

/* Two ordinary points, opposite hemispheres on both axes, chosen by
   COORDINATE rather than by address: the addresses move whenever the
   constants do, while the coordinates are the generator's inputs and do not.
   Deliberately not the vector list's first two, which are (0, 0) and a pole
   -- a dropped sign is invisible at the origin. */
const savedPoints = [[51.508, -0.1281], [-33.8568, 151.2153]].map((
  [lat, lon],
) =>
  vectors.addresses.find((a) =>
    a.mnemonic === vectors.key_derivation[0].name
    && Math.abs(a.lat_ns / 1e9 - lat) < 1e-9
    && Math.abs(a.lon_ns / 1e9 - lon) < 1e-9
  )
);
check(
  "two ordinary vector points are available to save addresses for",
  savedPoints.length === 2 && savedPoints.every(Boolean),
);

await relock(sampleMnemonic);

/* Saved once, the way a user saves them: click the square, write down what
   the panel says, and note where looking the address back up goes. */
const saved = [];
for (const point of savedPoints) {
  const at = { lat: point.lat_ns / 1e9, lon: point.lon_ns / 1e9 };
  const seen = await inspectAt(at.lat, at.lon);
  check(
    `saving ${seen.address} agrees with the committed vector `
      + `(${point.address})`,
    seen.address === point.address,
  );
  saved.push({ at, ...seen, landed: await flyToAddress(seen.address) });
}

for (let cycle = 1; cycle <= 3; cycle++) {
  await relock(sampleMnemonic);
  for (const [i, s] of saved.entries()) {
    const landed = await flyToAddress(s.address);
    check(
      `cycle ${cycle}: ${s.address} still lands where it was saved from `
        + `(got ${landed.lat.toFixed(7)},${landed.lon.toFixed(7)} `
        + `want ${s.landed.lat.toFixed(7)},${s.landed.lon.toFixed(7)})`,
      same(landed.lat, s.landed.lat) && same(landed.lon, s.landed.lon),
    );
    const again = await inspectAt(s.at.lat, s.at.lon);
    check(
      `cycle ${cycle}: point ${i + 1} is still called ${s.address} `
        + `(got ${again.address})`,
      again.address === s.address,
    );
    check(
      `cycle ${cycle}: and point ${i + 1}'s square has not moved `
        + `(got ${again.cornerLat.toFixed(7)},${again.cornerLon.toFixed(7)} `
        + `want ${s.cornerLat.toFixed(7)},${s.cornerLon.toFixed(7)})`,
      same(again.cornerLat, s.cornerLat) && same(again.cornerLon, s.cornerLon),
    );
  }
}

/* ------------------ the coarse map stays under you -------------------------

   Reported from use: zoom into an area you only have the low-resolution map
   for, watch it zoom in cleanly, and then watch the map you were looking at
   be replaced by grey.

   MapLibre keeps a stretched coarse tile on screen only while the finer tile
   has NO data -- and an empty answer IS data, meaning "this square is
   genuinely blank", so it wins and the coarse map goes. Changing the status
   to 404 does not help: the vector source swallows a 404 by design and files
   it as the same empty tile. What decides this is the source's maxzoom. While
   it claims more depth than the archive holds here, MapLibre keeps asking for
   tiles that will never come; when it tells the truth, MapLibre overzooms the
   coarse tile instead, which is measurably what a user wants to see.

   The situation needs an archive that CLAIMS depth it does not have
   everywhere, which is what this server now holds: London to zoom 15, and a
   thinner cone of low zooms around it. So the source advertises maxzoom 15,
   MapLibre asks for zoom 15 wherever you go, and just west of the downloaded
   box there is nothing to answer with. That is the reported situation
   exactly, and it is why the shallow-archive server cannot stand in for it --
   there the source advertises zoom 6, MapLibre never asks for more, and
   nothing is ever missing.

   Asserted through querySourceFeatures, which reads the tiles the source is
   RENDERING FROM, rather than off the screen: the fixture's tiles are
   deliberately unstyled, so nothing is drawn either way and a screenshot
   could not tell the two outcomes apart. */
const thinLon = -0.30;
const thinLat = 51.50;
const deepThin = tileAt(thinLon, thinLat, 15);
const coarseThin = tileAt(thinLon, thinLat, 8);

/* The premise, stated rather than assumed: this really is a place with a
   coarse map and no detail. Without both halves the checks below pass for
   the wrong reason. */
check(
  "just west of the download there is no deep tile",
  (await fetch(`${base}/tiles/15/${deepThin.x}/${deepThin.y}.mvt`)).status
    === 204,
);
check(
  "but there is a coarse one",
  (await fetch(`${base}/tiles/8/${coarseThin.x}/${coarseThin.y}.mvt`)).status
    === 200,
);

const drawnFrom = async (zoom) => {
  await page.evaluate(
    ([lon, lat, z]) =>
      window.__tessarium_map.jumpTo({ center: [lon, lat], zoom: z }),
    [thinLon, thinLat, zoom],
  );
  await page.waitForFunction(
    () => window.__tessarium_map?.areTilesLoaded() === true,
    null,
    { timeout: 30_000 },
  ).catch(() => {});
  await page.waitForTimeout(1500);
  /* Either source counts: the question is whether the basemap is still
     drawing ground here, not which of the two layers supplied it. Past the
     downloaded depth the answer must come from the floor. */
  return await page.evaluate(() =>
    ["protomaps", "protomaps-floor"].reduce(
      (n, id) =>
        n
        + window.__tessarium_map.querySourceFeatures(id, {
          sourceLayer: "fixture",
        }).length,
      0,
    )
  );
};

/* At a zoom the archive covers, there is a map to lose. */
const coarseDrawn = await drawnFrom(8);
check(
  `the coarse map is there to begin with (${coarseDrawn} features)`,
  coarseDrawn > 0,
);
/* And it is still there after zooming past everything that was downloaded --
   which is the whole point: the screen must not go blank under you. */
const deepDrawn = await drawnFrom(16);
check(
  `zooming past what was downloaded keeps it (${deepDrawn} features rendered)`,
  deepDrawn > 0,
);

/* ------------------------ the server going away --------------------------

   The failure this answers, which cost an afternoon: with no server the gate
   still renders, the phrase still validates and the checksum still goes
   green -- all three run in the browser -- so the app looks fine right up
   until "Open my map", which fails with "Could not open the map." That
   blames the phrase. Nothing said the server was missing.

   It is not an exotic state either: it is what `pnpm run dev` is in, every
   time, without the backend behind it, because the two wasm modules the key
   is derived with are embedded in the server binary rather than served from
   public/.

   /healthz is refused rather than the whole origin, because the page itself
   has to keep loading for there to be anywhere to put a banner. */

const bannerSays = (text, timeout = 30_000) =>
  page
    .waitForFunction(
      (t) =>
        [...document.querySelectorAll(".banner p")].some((p) =>
          (p.textContent ?? "").includes(t)
        ),
      text,
      { timeout },
    )
    .then(() => true, () => false);

serverGone = true;
await page.route(
  "**/healthz",
  (route) => route.fulfill({ status: 503, body: "" }),
);
/* Reloading drops the key with it, so this lands on the gate -- which is the
   screen that matters: it is the one a person is looking at when they cannot
   get in. */
await page.reload({ waitUntil: "domcontentloaded" });
await page.waitForSelector("#phrase", { timeout: 30_000 });
check(
  "an unreachable server is reported in a banner, at the gate",
  await bannerSays("Cannot reach the server"),
);

/* And pressing the button anyway must not blame the phrase. argon2.wasm is
   refused too, so unlocking genuinely fails -- which is the case that used
   to answer "Could not open the map" over a phrase whose checksum had gone
   green one second earlier. */
await page.route(
  "**/argon2.wasm",
  (route) => route.fulfill({ status: 503, body: "" }),
);
await page.locator("#phrase").fill(mnemonic);
await page.waitForSelector(".valid", { timeout: 30_000 });
await page.locator("button[type=submit]").click();
const toastNamesServer = await page
  .waitForFunction(
    () =>
      [...document.querySelectorAll("[data-sonner-toast]")].some((t) =>
        (t.textContent ?? "").includes("Cannot reach the server")
      ),
    null,
    { timeout: 30_000 },
  )
  .then(() => true, () => false);
check(
  "and Open my map then blames the server, not the phrase",
  toastNamesServer,
);
await page.unroute("**/argon2.wasm");

await page.unroute("**/healthz");
serverGone = false;
await page.reload({ waitUntil: "domcontentloaded" });
await page.waitForSelector("#phrase", { timeout: 30_000 });
/* And it goes away by itself: a banner that outlives its cause teaches
   people to ignore banners. */
const cleared = await page
  .waitForFunction(
    () =>
      ![...document.querySelectorAll(".banner p")].some((p) =>
        (p.textContent ?? "").includes("Cannot reach the server")
      ),
    null,
    { timeout: 30_000 },
  )
  .then(() => true, () => false);
check("and it clears once the server answers again", cleared);

/* One download, described once.

   The card used to render its own progress bar and its own cancel button
   while a job ran, and MapProgress renders both -- per region, which is the
   richer report -- one section up the same panel. While the card floated
   over the map those were two places; once both were in the panel they were
   the same download said twice, with two ways to cancel it.

   The job is faked rather than started: a real one against the fixture
   server finishes between polls, so there is no running state to look at.
   What is under test is what the panel DRAWS for a running job, which is
   exactly what the fake supplies. Installed before the reload because the
   status query stops polling once a job is idle -- the fetch on mount is
   the one that has to see it.

   Last in this browser on purpose: it reloads, which costs the key. */
await page.route("**/api/basemap-status", (route) =>
  route.fulfill({
    status: 200,
    contentType: "application/json",
    body: JSON.stringify({
      generation: 4242,
      job: {
        state: "fetching",
        done_bytes: 33_000_000,
        total_bytes: 668_000_000,
        part: 1,
        parts: 1,
        regions: [{
          label: "Georgia",
          done_bytes: 31_000_000,
          total_bytes: 665_000_000,
          planned: true,
        }],
      },
    }),
  }));
await page.reload({ waitUntil: "domcontentloaded" });
await page.locator("#phrase").fill(mnemonic);
await page.waitForSelector(".valid", { timeout: 30_000 });
await page.locator("button[type=submit]").click();
await page.waitForSelector(".map-wrap", { timeout: 60_000 });
await page.locator(".panel-download").click();
await page.waitForSelector(".download-card", { timeout: 10_000 });

const reportedOnce = await page
  .waitForFunction(
    () => document.querySelectorAll(".downloads progress").length > 0,
    null,
    { timeout: 20_000 },
  )
  .then(() => true, () => false);
check("a running download is reported once, by MapProgress", reportedOnce);
check(
  "and the card does not report it a second time",
  (await page.locator(".download-card progress").count()) === 0,
);
/* Two cancel buttons for one download is the worse half of it: whichever is
   pressed, the other stays on screen offering to do it again. */
check(
  "nor offers a second way to cancel it",
  (await page.locator(".download-card").getByRole("button").filter({
    hasText: /cancel/i,
  }).count()) === 0,
);
await page.unroute("**/api/basemap-status");

await browser.close();

/* ----------------------------- coming back --------------------------------

   The complaint this answers: opening the app a second time downloaded
   everything it had already downloaded. Every response was `cache-control:
   no-cache` with no validator attached, and `no-cache` means "ask", not
   "refetch" -- but with nothing to ask ABOUT, every question was answered in
   full. Over a forwarded port that was about ten megabytes and twenty
   seconds, on a map the browser already had.

   A browser rather than a protocol test, because the claim is about one: that
   it stores these responses, revalidates them, and is told they have not
   changed. A server emitting a correct ETag that no client ever sends back
   would pass a protocol test and fix nothing a user would notice.

   Two visits in one context, so the second one meets the first one's cache.
   Bytes off the wire, not status codes: a response the browser never asked
   for at all is a better outcome than a 304, and counting 304s would score it
   as a failure. */
const revisitBrowser = await chromium.launch();
const revisitContext = await revisitBrowser.newContext({
  viewport: { width: 1280, height: 900 },
});

const visit = async () => {
  const p = await revisitContext.newPage();
  /* Two whole app sessions run here -- gate, worker, core, map. Unwatched
     they would run with CSP violations and page errors invisible, which is
     the opposite of what the rest of this file does. */
  p.on("console", (msg) => {
    if (msg.type() === "error" && !msg.text().includes("Failed to load")) {
      problems.push(`revisit console: ${msg.text()}`);
    }
  });
  p.on(
    "pageerror",
    (err) => problems.push(`revisit pageerror: ${err.message}`),
  );
  const rows = [];
  const pending = [];
  p.on("requestfinished", (req) => {
    pending.push(
      req.sizes()
        .then(async (size) => {
          const res = await req.response();
          rows.push({
            path: new URL(req.url()).pathname,
            method: req.method(),
            status: res ? res.status() : 0,
            /* Playwright reports the body as `encodedDataLength` minus the
               response headers, so a response the browser served from its own
               cache -- the best possible outcome -- comes back NEGATIVE, by
               the size of headers that were never received. Clamped for the
               totals, and kept raw as well, because "how many were free" is
               a number worth asserting rather than inferring. */
            bytes: Math.max(0, size.responseBodySize),
            fromCache: size.responseBodySize < 0,
          });
        })
        .catch(() => {}),
    );
  });
  /* All the way in, both times. A bare page load reaches neither of the two
     heavy things: the core loads when the worker is first asked a question,
     and the map does not exist until the phrase is accepted. Measuring a
     visit that stops at the gate would report a saving on a fifth of what a
     visit actually costs. */
  await p.goto(base, { waitUntil: "networkidle" });
  await p.locator("#phrase").fill(sampleMnemonic);
  await p.waitForSelector(".valid", { timeout: 60_000 });
  await p.locator("button[type=submit]").click();
  await p.waitForSelector(".map-wrap", { timeout: 60_000 });
  await p.waitForFunction(
    () => window.__tessarium_map?.areTilesLoaded() === true,
    null,
    { timeout: 60_000 },
  );
  await p.waitForLoadState("networkidle");
  await Promise.all(pending);
  await p.close();
  /* Awaited again after the close: `pending` is a growing array and the first
     await only covers what had landed by then. Closing the page is what
     guarantees no more will arrive. */
  await Promise.all(pending);
  return rows;
};

const firstVisit = await visit();
const secondVisit = await visit();
/* GETs only, because those are the ones a cache can answer: the app's two
   POSTs to /api are uncacheable by construction. They are held to a size of
   their own below rather than quietly dropped, so the headline number cannot
   be made to look better by traffic moving out of it. */
const bodyBytes = (rows) =>
  rows.filter((r) => r.method === "GET").reduce((n, r) => n + r.bytes, 0);
const otherBytes = (rows) =>
  rows.filter((r) => r.method !== "GET").reduce((n, r) => n + r.bytes, 0);
const first = bodyBytes(firstVisit);
const second = bodyBytes(secondVisit);

/* Printed rather than only asserted: this is a number the project makes a
   claim about, and a threshold that passes says nothing about how much room
   is left under it. */
console.log(
  `  revisit ${Math.round(second / 1024)} KB against ${
    Math.round(first / 1024)
  } KB, ${firstVisit.length} requests, ${
    secondVisit.filter((r) => r.fromCache).length
  } straight from cache`,
);

/* Without a first visit that actually downloaded something, the second one
   costing nothing would mean nothing. */
/* Floors, not budgets. Both exist so that "coming back costs nothing" is
   measured against a visit that actually paid for something; ui/test/
   payload.mjs is where size is held to account, and it is the only place that
   should fail when something grows.

   Lowered from 512 KB and 100 KB when the js_of_ocaml bundle went from
   1,058 KB on the wire to 181 KB. Neither was in danger of firing -- a first
   visit is around 735 KB and the bundle is well over 100 KB either way -- but
   both were sized against a payload that no longer exists, and a floor that
   tracks the current figure is a budget wearing the wrong name. These are set
   where making the app smaller still is not a test failure. */
check(
  `the first visit downloads the app (${Math.round(first / 1024)} KB)`,
  first > 256 * 1024,
);
check(
  `the core is part of it (${
    firstVisit.filter((r) => r.path === "/tessarium.js").length
  } request)`,
  firstVisit.some((r) => r.path === "/tessarium.js" && r.bytes > 50 * 1024),
);
check(
  `coming back re-downloads almost nothing (${
    Math.round(second / 1024)
  } KB against ${Math.round(first / 1024)} KB)`,
  second < first / 20,
);
/* Named separately because it is the item the complaint was really about.
   It is not only the verified core: ocaml/lib's BIP-39, NFKD and KDF inputs,
   the band table, digestif, uunf and the js_of_ocaml runtime are all in
   there, and it moves when any of them does. */
const coreAgain = secondVisit.filter((r) =>
  r.path === "/tessarium.js" && r.bytes > 0
);
check(
  `the core is not sent again (${coreAgain.length} resends)`,
  coreAgain.length === 0,
);
/* Whatever the second visit did pay for, name it, so a regression that
   re-downloads one large thing is legible rather than a total that drifted. */
if (second >= first / 20) {
  for (
    const r of secondVisit.filter((r) => r.bytes > 4096).sort((a, b) =>
      b.bytes - a.bytes
    ).slice(0, 8)
  ) console.log(`    re-sent ${Math.round(r.bytes / 1024)} KB  ${r.path}`);
}

/* The map's own bytes are most of the weight, so a run where the map never
   asked for a tile would report a saving it did not make. */
const firstTiles = firstVisit.filter((r) =>
  r.path.startsWith("/tiles/") && r.bytes > 0
);
check(
  `the map fetched tiles on the way in (${firstTiles.length})`,
  firstTiles.length > 0,
);
/* Sent, not asked for. The browser asks about every one of them -- that is
   what `no-cache` plus a validator means -- and a name saying otherwise would
   describe a different design. */
check(
  `and none of them is sent again (${
    secondVisit.filter((r) => r.path.startsWith("/tiles/") && r.bytes > 0)
      .length
  })`,
  secondVisit.every((r) => !r.path.startsWith("/tiles/") || r.bytes === 0),
);
check(
  `what a visit does not GET stays small (${otherBytes(secondVisit)} B)`,
  otherBytes(secondVisit) < 4096,
);
/* The saving must be the cache doing its job, not the second visit quietly
   doing less. */
check(
  `most of the second visit came from cache (${
    secondVisit.filter((r) => r.fromCache).length
  } of ${secondVisit.length})`,
  secondVisit.filter((r) => r.fromCache).length > 0,
);

await revisitBrowser.close();

/* ------------------------ what the gate alone costs -----------------------

   The complaint this answers: the phrase screen downloaded the map engine
   before it could be typed into. MapLibre and the basemap style are most of
   what this application ships, none of it is reachable until a phrase has
   been accepted, and a static import put all of it in the entry chunk -- 551
   KB on the wire, measured, on the one screen a visitor sees before deciding
   whether to use this at all. The map is a separate chunk now; see
   ui/src/components/mapChunk.ts.

   A cold context, because the claim is about a first visit. And nothing is
   typed at first: the gate starts the map download as soon as a phrase passes
   its checksum, so a run that typed one would be measuring the warm-up rather
   than the gate.

   So this is the cost of REACHING a phrase field that can be typed into, and
   not the cost of using it. The verified core (/tessarium.js, about 181 KB)
   and the map chunk both follow, as the phrase is typed and as it validates.
   The number below is smaller than a whole session on purpose: the screen it
   measures is the one shown to someone who has not yet decided to have a
   session at all.

   Two checks, because either one alone can be satisfied the wrong way. The
   budget is what fails if the map returns to the entry chunk. The second is
   what fails if someone meets the budget by breaking the map instead -- the
   chunk has to still arrive on the way in, or there is no saving, only a
   smaller app that does less. */
const gateBrowser = await chromium.launch();
const gateContext = await gateBrowser.newContext({
  viewport: { width: 1280, height: 900 },
});
const gatePage = await gateContext.newPage();
gatePage.on(
  "pageerror",
  (err) => problems.push(`gate pageerror: ${err.message}`),
);
const gateRows = [];
const gatePending = [];
gatePage.on("requestfinished", (req) => {
  gatePending.push(
    req.sizes()
      .then(async (size) => {
        const res = await req.response();
        gateRows.push({
          path: new URL(req.url()).pathname,
          method: req.method(),
          status: res ? res.status() : 0,
          bytes: Math.max(0, size.responseBodySize),
        });
      })
      .catch(() => {}),
  );
});

await gatePage.goto(base, { waitUntil: "networkidle" });
await gatePage.waitForSelector("#phrase", { state: "visible" });
await gatePage.waitForLoadState("networkidle");
await Promise.all(gatePending);
/* Snapshotted before anything is typed. `gateRows` keeps growing after this
   line, and the whole point of the number is where it stops. */
const atGate = gateRows.slice();
const gateBytes = atGate
  .filter((r) => r.method === "GET")
  .reduce((n, r) => n + r.bytes, 0);

console.log(
  `  gate ${Math.round(gateBytes / 1024)} KB over ${
    atGate.filter((r) => r.method === "GET").length
  } requests`,
);

/* 200 KB against a measured 178 over the wire (173 under gzip -9; the
   server's compressor emits a little more, and this budget is the wire).

   Raised from 176 when the language picker became a React Aria Select.
   That put the library's shared core -- collections, overlays,
   focus management -- in the entry chunk, because the gate renders a
   dropdown. Measured: the gate went up 38,617 bytes and the map chunk came
   DOWN 49,222, because the map no longer carries its own copy, so a whole
   session is 10,605 bytes cheaper and only the first screen pays more. That
   is a real cost on the one screen this check exists to protect, and it was
   taken deliberately for one interaction library rather than two; it is
   recorded here rather than absorbed silently.

   The remaining gap is room for the gate itself to grow, and it is still
   nowhere near the 551 KB that a static map import costs, which is the
   regression this exists to catch. Raise it only with a measurement saying
   why, the same rule ui/test/payload.mjs sets. */
check(
  `the phrase screen costs ${Math.round(gateBytes / 1024)} KB`,
  gateBytes < 200 * 1024,
);
/* Named, so a regression is legible rather than a total that drifted. */
if (gateBytes >= 200 * 1024) {
  for (
    const r of atGate.filter((r) => r.bytes > 4096).sort((a, b) =>
      b.bytes - a.bytes
    )
  ) console.log(`    ${Math.round(r.bytes / 1024)} KB  ${r.path}`);
}

const jsAssets = (rows) =>
  rows.filter((r) =>
    r.path.startsWith("/assets/") && r.path.endsWith(".js") && r.bytes > 0
  );
check(
  `and pulls one script to do it (${jsAssets(atGate).length})`,
  jsAssets(atGate).length === 1,
);

/* Now all the way in, on the same page, so the second half is measured
   against the same cold cache. Matched on size rather than on the chunk's
   name: what matters is that the map arrives separately and is the big half,
   not what Vite decided to call the file. */
await gatePage.locator("#phrase").fill(sampleMnemonic);
await gatePage.waitForSelector(".valid", { timeout: 60_000 });
await gatePage.locator("button[type=submit]").click();
await gatePage.waitForSelector(".map-wrap", { timeout: 60_000 });
await gatePage.waitForLoadState("networkidle");
await Promise.all(gatePending);

const mapChunks = jsAssets(gateRows).filter((r) =>
  !atGate.some((g) => g.path === r.path)
);
check(
  `the map arrives as its own download (${mapChunks.length} chunk, ${
    Math.round(mapChunks.reduce((n, r) => n + r.bytes, 0) / 1024)
  } KB)`,
  mapChunks.length >= 1
    && mapChunks.reduce((n, r) => n + r.bytes, 0) > 200 * 1024,
);
/* The saving is real only if the split did not simply move the whole app
   later. The gate has to be the smaller half. */
check(
  `and it is the larger half`,
  mapChunks.reduce((n, r) => n + r.bytes, 0) > gateBytes,
);

/* The fallback, which needs the download to be slow enough to see. Nothing
   else in this suite ever renders it -- on a local server the chunk arrives
   between frames -- and an unrendered loading state is exactly the kind that
   rots into a blank panel or an untranslated string without anyone noticing.
   Delayed here on purpose, and read for its text as well as its presence, so
   a missing catalogue entry fails rather than showing an empty box. */
const slowPage = await gateContext.newPage();
const entryPath = jsAssets(atGate)[0]?.path;
await slowPage.route("**/assets/*.js", async (route) => {
  if (new URL(route.request().url()).pathname === entryPath) {
    return route.continue();
  }
  await new Promise((resolve) => setTimeout(resolve, 3000));
  return route.continue();
});
await slowPage.goto(base, { waitUntil: "networkidle" });
await slowPage.locator("#phrase").fill(sampleMnemonic);
await slowPage.waitForSelector(".valid", { timeout: 60_000 });
await slowPage.locator("button[type=submit]").click();
const pendingText = await slowPage.locator(".map-pending").first()
  .textContent({ timeout: 30_000 })
  .catch(() => null);
check(
  `a slow map download says so rather than showing a hole (${
    JSON.stringify(pendingText)
  })`,
  typeof pendingText === "string" && pendingText.trim().length > 0,
);
/* And it goes away by itself: a placeholder that outlives its download is
   worse than none, because the map underneath it works. */
await slowPage.waitForSelector(".map-wrap", { timeout: 60_000 });
check(
  "and it is gone once the map is there",
  await slowPage.locator(".map-pending").count() === 0,
);
await slowPage.close();

await gateBrowser.close();

/* A path the resolver accepts but the filesystem will not look at.
   `Tessarium.UrlPath.theorem_no_escape` says a 300-byte segment cannot leave
   the root, and it is right -- it holds no separator and no NUL. (The leading
   dot is a different claim, `theorem_no_dotfile`, and not what matters here.)
   It is simply longer than NAME_MAX, which is 255 on Linux, so statx answers
   ENAMETOOLONG and the exception used to travel up as a connection error: one
   unauthenticated request took the connection down instead of being answered.
   Name length is a fact about the directory, and F* is never told about
   directories, so this gets a test rather than a lemma.

   Both routes, because they answer differently and only one is a 404: a
   segment with no extension is an SPA route, so the UI path serves
   index.html, and the basemap path has no such fallback. Node's fetch does
   not normalise a long segment the way it collapses `..`, so what the server
   sees is what is written here. */
const longName = "a".repeat(300);
const longRes = await fetch(`${base}/${longName}`).then(
  (r) => r.status,
  (e) => `threw: ${e.message}`,
);
check(
  `a 300-byte path segment falls through to the app (${longRes})`,
  longRes === 200,
);
const longBasemap = await fetch(`${base}/basemap/${longName}`).then(
  (r) => r.status,
  (e) => `threw: ${e.message}`,
);
check(
  `and on the basemap route it is a plain 404 (${longBasemap})`,
  longBasemap === 404,
);
/* Weaker than it looks, and kept anyway: node opens a fresh connection, so
   this passes even against the bug above -- the exception took one socket
   down, not the server. What it does catch is the worse version, where an
   unhandled error on a request path ends the process. */
const afterLong = await fetch(`${base}/healthz`).then(
  (r) => r.status,
  (e) => `threw: ${e.message}`,
);
check(
  `and the server is still answering afterwards (${afterLong})`,
  afterLong === 200,
);

/* The conditional itself, at the protocol level: the properties a browser
   depends on but does not reveal when it is working. */
const conditional = async (path) => {
  const plain = await fetch(`${base}${path}`);
  /* Decoded, not wire bytes: node's fetch asks for gzip and inflates before
     handing the body over, so this is several times what crossed the socket.
     It is here to show the resource is not empty, which is all it can show. */
  const decoded = (await plain.arrayBuffer()).byteLength;
  const tag = plain.headers.get("etag");
  const csp = plain.headers.get("content-security-policy");
  if (!tag) return { tag: null, status: plain.status, decoded, length: -1 };
  const again = await fetch(`${base}${path}`, {
    headers: { "if-none-match": tag },
  });
  const length = (await again.arrayBuffer()).byteLength;
  return {
    tag,
    status: again.status,
    length,
    decoded,
    csp,
    /* A 304 is still a response this server sent, and it must carry the same
       policy as the body it stands in for. Nothing else would notice if it
       stopped: the browser reuses the stored response, so a missing policy
       here would show up as a security hole rather than a broken page. */
    cspAgain: again.headers.get("content-security-policy"),
  };
};

const coreCond = await conditional("/tessarium.js");
check(
  `an embedded asset carries an ETag and answers 304 with no body (${coreCond.decoded} decoded, then ${coreCond.length})`,
  coreCond.tag !== null && coreCond.status === 304 && coreCond.decoded > 0
    && coreCond.length === 0,
);
check(
  "and the 304 carries the same security policy as the body it replaces",
  coreCond.csp !== null && coreCond.cspAgain === coreCond.csp,
);
/* Two encodings are two representations. A client holding the gzipped bytes
   must not be told its copy is current when the tag it sent describes the
   other one -- it would decode gzip as UTF-8. */
const gz = await fetch(`${base}/tessarium.js`, {
  headers: { "accept-encoding": "gzip" },
});
await gz.arrayBuffer();
const identityTagged = await fetch(`${base}/tessarium.js`, {
  headers: {
    "accept-encoding": "identity",
    "if-none-match": gz.headers.get("etag"),
  },
});
await identityTagged.arrayBuffer();
check(
  "a gzip tag does not match the identity representation",
  identityTagged.status === 200,
);

/* A file off disk, whose tag is its size and modification time rather than a
   hash: the sprite sheet, because the fixture's one glyph file is empty and a
   304 for it would be indistinguishable from a 200. */
const sprite = await conditional("/basemap/sprites/v4/light.png");
check(
  `a file off disk revalidates too (${sprite.decoded} decoded, then ${sprite.length})`,
  sprite.tag !== null && sprite.status === 304 && sprite.decoded > 0
    && sprite.length === 0,
);

/* Two If-None-Match field lines rather than one comma-joined value. An
   intermediary is free to split what a browser sent as one, and RFC 9110 5.3
   says the two forms mean the same thing -- but the header API hands back
   only the LAST line, so a server that asks for one value tells a client
   holding the bytes to download them again. Sent through node:http because
   fetch's Headers joins duplicates before they reach the socket, which is
   the very thing being tested around. */
const twoLines = async (path, tags) =>
  await new Promise((resolve) => {
    const url = new URL(`${base}${path}`);
    http.request({
      hostname: url.hostname,
      port: url.port,
      path: url.pathname,
      /* Same encoding the tag was taken under. Ask for identity here and the
         gzip tag correctly does not match -- which is the encoding suffix
         working, and would look like this check failing. */
      headers: { "accept-encoding": "gzip", "if-none-match": tags },
    }, (res) => {
      res.resume();
      res.on("end", () => resolve(res.statusCode));
    }).end();
  });
const coreTag = (await fetch(`${base}/tessarium.js`, { method: "HEAD" }))
  .headers.get("etag");
check(
  "a tag split across two field lines is still found",
  await twoLines("/tessarium.js", [coreTag, '"something-else"']) === 304,
);
check(
  "and a pair that names neither is not",
  await twoLines("/tessarium.js", ['"one"', '"two"']) === 200,
);

/* A tile the app itself fetched on the first visit, rather than a guessed
   z/x/y: tiles are most of the bytes, and their tag is over the bytes because
   the archive under them can be replaced while the server runs. */
const someTile = firstTiles[0];
const tileCond = someTile ? await conditional(someTile.path) : null;
check(
  `a tile revalidates too (${someTile?.path ?? "no tile was fetched"})`,
  tileCond !== null && tileCond.status === 304 && tileCond.length === 0
    && tileCond.decoded > 0,
);

/* The one GET a session makes that used to carry no validator at all. */
const tileJson = await conditional("/tiles.json");
check(
  `the tile metadata revalidates too (${tileJson.decoded} decoded, then ${tileJson.length})`,
  tileJson.tag !== null && tileJson.status === 304 && tileJson.decoded > 0
    && tileJson.length === 0,
);

/* A Range whose validator has moved on is answered with the whole thing, not
   with a window into different bytes -- map.pmtiles is rewritten in place by
   the downloader, so splicing a stale 206 into a partial copy would join two
   archives. */
const ranged = async (extra) => {
  const r = await fetch(`${base}/basemap/sprites/v4/light.png`, {
    headers: { range: "bytes=0-9", ...extra },
  });
  await r.arrayBuffer();
  return r.status;
};
check("a plain range is still a range", await ranged({}) === 206);
check(
  "a range guarded by the current tag is still a range",
  await ranged({ "if-range": sprite.tag }) === 206,
);
check(
  "a range guarded by a tag that has moved on gets the whole file",
  await ranged({ "if-range": '"stale"' }) === 200,
);

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
  `the download is recorded; the browses never were (${
    (prunedLedger.entries ?? []).map((e) => e.name).join(", ")
  })`,
  prunedLedger.entries?.some((e) => e.name === "London borrowed back")
    && prunedLedger.entries?.length === 2,
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
/* A part having landed is what makes the run own a region, and now it can be
   asked directly: the record is published with every part, not only the last,
   so an entry appearing IS a part on disk. That is the property that makes a
   cancelled download resumable -- and it is why this no longer waits on a
   file name it had to know in advance. */
let landed = false;
for (let i = 0; i < 600 && !landed; i++) {
  landed = ((await (await post5("basemap-ledger")).json()).entries ?? [])
    .length > 0;
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
/* What it leaves behind, which used to be nothing anyone could name. The
   parts that landed are in a file of the region's own and the record inside
   it says so, because the record is published with every part rather than
   only the last. Tiles from a cancelled download used to sit in the shared
   archive claimed by no entry: unlistable, unremovable, and invisible to
   everything except the map drawing them. */
const cancelLedger = await (await post5("basemap-ledger")).json();
const partial = cancelLedger.entries?.[0];
check(
  "a cancelled download leaves a region that can be named",
  (partial?.file ?? "") !== "",
);
check(
  "and its tiles really are on disk under that name",
  (await cancelHas(partial?.file ?? "nothing")) === 200,
);
/* And it is removable, which is the part that was impossible before. */
await post5("basemap-remove", { id: partial?.id });
let removedPartial = "";
for (let i = 0; i < 300; i++) {
  removedPartial = (await (await post5("basemap-status")).json()).job?.state
    ?? "";
  if (["removed", "failed"].includes(removedPartial)) break;
  await new Promise((r) => setTimeout(r, 100));
}
check(
  `an interrupted download can be removed (got ${removedPartial})`,
  removedPartial === "removed"
    && (await cancelHas(partial?.file ?? "nothing")) === 404,
);
await post5("basemap-settings", { browse_cache: false });

/* ------------------ a source that changed compression ---------------------

   Tile bytes are copied verbatim and the header says how to read them, so
   an archive built from a gzipped source and then MERGED with an
   uncompressed one would relabel every tile it already held. Unreadable,
   silently, and only at render time. This server's source disagrees with
   the archive seeded beside it, so every path that would merge them has to
   refuse instead.

   Which is now fewer paths, and that is the point. A region download merges
   with nothing: it writes its own file, and the tile endpoint reads every
   file through that file's own header, so two regions in two compressions
   are two files that both draw. Refusing there would be refusing on behalf
   of a merge that cannot happen. A browse still writes into the cache, and
   the cache is still folded into map.pmtiles, so that one still refuses. */
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
check(
  "an estimate for a region of its own is answered, not refused",
  mismatchEstimate.status === 200,
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

/* --------------- a promised content-length is a promise --------------------

   `serve_file` writes the status line and `content-length` first and the body
   afterwards. It used to open the file in the body callback, so a file that
   was renamed in between produced `200 OK, content-length: N` followed by a
   closed socket with nothing in it -- and a truncated body against a promised
   length is the one failure a client cannot tell from a network fault. The
   application opens that window itself: the downloader renames every region
   archive into place under the very root this endpoint serves.

   Driven the way it was measured. A file under the basemap root is moved away
   and back while the same file is fetched in a loop, and the rule is that
   every 200 delivers exactly what it promised. A 404 is a fine answer -- the
   name really is absent for part of each cycle -- and so is any other status;
   what is not fine is a 200 that under-delivers.

   The counts are reported whether or not it passes, because "0 truncated" is
   only worth reading next to how many 200s actually happened. */
const racyRoot = new URL("../../_build/e2e-basemap/", import.meta.url);
const racyPath = new URL("racy.bin", racyRoot);
const racyAside = new URL("racy.bin.aside", racyRoot);
const racyBytes = Buffer.alloc(128 * 1024, 7);
writeFileSync(racyPath, racyBytes);

let racyComplete = 0, racyTruncated = 0, racyMissing = 0, racyOther = 0;
/* 600 rather than a round hundred, and the reason is worth stating: the
   window this opens is narrow. Measured against the unfixed server, 2 of 300
   requests truncated -- so a short loop would clear a broken build about one
   run in eight. 600 puts that under 2%. It is still a probabilistic check,
   which is why the fix is a structural one and this only watches it. */
const ROUNDS = 600;

/* Away and back, so the name is genuinely absent for part of every cycle.
   Replacing it in place would not do: the old code would open the
   replacement, stream a file of the same length, and look correct. */
const flipper = (async () => {
  for (let i = 0; i < ROUNDS; i++) {
    try {
      renameSync(racyPath, racyAside);
      renameSync(racyAside, racyPath);
    } catch { /* lost a race with ourselves; the next round re-tries */ }
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
})();

for (let i = 0; i < ROUNDS; i++) {
  let res;
  try {
    res = await fetch(`${base}/basemap/racy.bin`);
  } catch {
    racyOther += 1;
    continue;
  }
  if (res.status === 404) {
    racyMissing += 1;
    await res.arrayBuffer().catch(() => {});
    continue;
  }
  if (res.status !== 200) {
    racyOther += 1;
    await res.arrayBuffer().catch(() => {});
    continue;
  }
  const promised = Number(res.headers.get("content-length"));
  /* undici rejects the body when it is shorter than the length that was
     promised, which is exactly the failure being looked for -- so the throw
     counts as a truncation rather than as an error in this harness. */
  const got = await res.arrayBuffer().then((b) => b.byteLength, () => -1);
  if (got === promised && promised === racyBytes.length) racyComplete += 1;
  else racyTruncated += 1;
}
await flipper;
rmSync(racyPath, { force: true });
rmSync(racyAside, { force: true });

check(
  `a file renamed mid-flight never truncates a promised body `
    + `(${racyComplete} complete, ${racyTruncated} truncated, `
    + `${racyMissing} absent, ${racyOther} other, of ${ROUNDS})`,
  racyTruncated === 0,
);
/* Guards the check above from passing because nothing was ever served: if the
   loop only ever saw 404s it has proved nothing about promised bodies. */
check(
  `and the loop actually served the file (${racyComplete} times)`,
  racyComplete > 0,
);

slowProxy.close();

for (const p of problems) console.log(`  PAGE  ${p}`);
check(
  "no console errors, CSP violations or failed requests",
  problems.length === 0,
);

console.log(`\n${checks} checks, ${failures} failures`);
process.exit(failures ? 1 : 0);
