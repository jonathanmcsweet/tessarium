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

page.on("console", (msg) => {
  /* A failed resource is already recorded from the response, with its URL
     attached; the console version has none and is pure noise. */
  if (
    msg.type() === "error" && !msg.text().includes("Failed to load resource")
  ) {
    problems.push(`console: ${msg.text()}`);
  }
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
const englishFooter = await page.locator(".panel-foot p").textContent();
await page.locator(".language select").selectOption("fr-FR");
await page.waitForTimeout(400);
const frenchFooter = await page.locator(".panel-foot p").textContent();
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

await browser.close();

for (const p of problems) console.log(`  PAGE  ${p}`);
check(
  "no console errors, CSP violations or failed requests",
  problems.length === 0,
);

console.log(`\n${checks} checks, ${failures} failures`);
process.exit(failures ? 1 : 0);
