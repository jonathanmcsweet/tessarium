/* End-to-end check of the built UI against the built server.

   This is the test for the claim the whole project rests on: enter a phrase,
   click a square, get its address. It runs the real browser against the real
   binary, because the parts that break here -- Web Worker startup, the
   Content-Security-Policy, js_of_ocaml's export target in a worker -- look
   fine in a unit test and fail in a page.

   The addresses it expects come from `vectors/vectors.json`, so a UI that
   renders beautifully and computes the wrong answer still fails. */

import {
  copyFileSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import http, { createServer } from "node:http";
import { chromium } from "playwright";

const base = process.argv[2] ?? "http://127.0.0.1:7379";
const vectors = JSON.parse(
  readFileSync(new URL("../../vectors/vectors.json", import.meta.url), "utf8"),
);
/* The source catalogue, not a copy of the wording kept here. A check quoting
   its own copy still passes after someone changes the wording and the meaning
   with it -- which for a message whose job is to not overclaim is the failure
   worth catching. */
const messages = JSON.parse(
  readFileSync(new URL("../messages/en-US.json", import.meta.url), "utf8"),
);
const m = (key) => messages[key];

const results = [];
const check = (name, ok) => {
  results.push({ name, ok });
  if (!ok) console.log(`  FAIL  ${name}`);
};

/* How long a success toast stays, read from the source rather than copied
   here. Two checks below depend on it: that a success goes by itself, and that
   an error is still there once a success would have gone. A stale copy would
   leave both waiting for the wrong moment. Read as text rather than imported,
   because src/toast.ts builds a React Aria queue at module scope and wants a
   DOM. */
const successMs = Number(
  /SUCCESS_MS = (\d+)/.exec(
    readFileSync(new URL("../src/toast.ts", import.meta.url), "utf8"),
  )?.[1],
);
check(
  `a success toast's own timeout is legible in the source (${successMs}ms)`,
  Number.isFinite(successMs) && successMs > 0,
);
/* A fallback, so the two waits below are merely wrong rather than nonsense. */
const SUCCESS_MS = Number.isFinite(successMs) && successMs > 0
  ? successMs
  : 5000;

/* Poll until `probe` answers with something truthy, or the budget runs out.
   Returns the answer, or the last falsy one. */
const until = async (probe, { tries = 120, delayMs = 500 } = {}) => {
  const value = await probe();
  if (value || tries <= 1) return value;
  await new Promise((r) => setTimeout(r, delayMs));
  return until(probe, { tries: tries - 1, delayMs });
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
   no `selectOption`: press the control, then press the option. Options carry a
   `data-value` written by components/Dropdown.tsx for this, rather than a key
   attribute belonging to the library.

   `chooseFrom` returns the button, because a dropdown's current value is the
   button's text -- there is no `inputValue` either. */
const dropdownIn = (scope) => page.locator(`${scope} .dropdown-button`);
const chooseFrom = async (scope, value) => {
  const button = dropdownIn(scope);
  await button.click();
  await page.locator(`.dropdown-option[data-value="${value}"]`).click();
  /* The popover unmounts on selection. Waiting for that keeps a later click
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

   One test cancels a download halfway, and against a local fixture there is
   normally no halfway: the archive shares one tile blob, the reader fetches a
   megabyte at a time, and a whole region arrives in about three requests and
   under half a second, measured. So the cancel server reads through this
   proxy, which pauses before forwarding every range request. Paired with
   map-slow.pmtiles, whose tiles each sit in their own 64 KiB slot so reads
   cannot be coalesced away, a download takes seconds and cancelling it is
   deliberate rather than lucky. */
const PROXY_DELAY_MS = 300;
const fixtureBase = process.env.E2E_FIXTURE ?? "http://127.0.0.1:7374";
const proxyPort = Number(process.env.E2E_PROXY_PORT ?? 7378);
const slowProxy = createServer((req, res) => {
  const headers = req.headers.range ? { range: req.headers.range } : {};
  fetch(`${fixtureBase}${req.url}`, { method: req.method, headers })
    .then(async (upstream) => {
      const body = Buffer.from(await upstream.arrayBuffer());
      await new Promise((done) => setTimeout(done, PROXY_DELAY_MS));
      const pass = Object.fromEntries(
        ["content-type", "content-range", "accept-ranges"]
          .map((h) => [h, upstream.headers.get(h)])
          .filter(([, v]) => v),
      );
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
   worker that will not start, a script that 404s. */
const problems = [];

/* Missing basemap assets are expected until a .pmtiles has been fetched, and
   the UI reports that itself. Everything else is a real failure. */
const expected = (url) => url.includes("/basemap/");

/* Set once the in-app download completes. Before that, MapLibre reports the
   missing archive and sprites through console errors; after it, the same
   messages mean the downloaded tiles are bad, which this suite must fail on. */
let basemapReady = false;

/* Set for the one test that takes the server away on purpose. Every handler
   below would otherwise record the refusal as a real failure, which is what it
   is for every other second of this run.

   It covers argon2.wasm as well as /healthz: the KDF module is what makes
   unlocking genuinely fail rather than merely look like it might. While it is
   set, console errors and page errors are ignored wholesale -- the app is
   supposed to be complaining loudly for those few seconds. */
let serverGone = false;
const refusedOnPurpose = (url) =>
  serverGone && (url.includes("/healthz") || url.includes("/argon2.wasm"));

page.on("console", (msg) => {
  if (msg.type() !== "error") return;
  if (serverGone) return;
  const text = msg.text();
  /* A failed resource is already recorded from the response, with its URL.
     The console version carries no URL and is pure noise. */
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
     the view or the style swaps. The client cancelling itself is not a
     failure; anything else that dies on /tiles/ still is. */
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

/* The core has to load inside the worker before validation replies. If
   js_of_ocaml exported to the wrong global, this is where it hangs.

   The `null` in every waitForFunction below is the argument passed to the page
   function. It is there because the third parameter is the options: without
   it, the timeout is read as that argument and discarded, so a wait that says
   sixty seconds spends Playwright's default thirty and reports that number in
   the failure. */
const gateCopy = page.locator(".gate-phrase-copy");
await page.locator("#phrase").fill("abandon abandon abandon");
await page.waitForFunction(
  () =>
    document.querySelector(".phrase-status")?.textContent?.includes(
      "expected 24 words",
    ),
  null,
  { timeout: 30_000 },
);
/* The one secret this app handles, in a field a password manager will
   recognise. It was a textarea with autocomplete off, so nothing ever offered
   to remember the string that cannot be recovered if it is lost. Masked by
   default, because it is typed on whatever screen is to hand. */
check(
  "the phrase is a password field a manager can save",
  (await page.locator("#phrase").getAttribute("type")) === "password"
    && (await page.locator("#phrase").getAttribute("autocomplete"))
      === "current-password",
);
/* Three words is not a phrase, and half a secret on the clipboard is worse
   than none: the copy button is there, so the row does not change width on
   the last word typed, and it cannot be pressed yet. */
check(
  "copying is offered but refused until the phrase is whole",
  (await gateCopy.count()) === 1 && await gateCopy.isDisabled(),
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
   app, so its guidance rides the control that makes the choice: the info icon
   beside "Generate one for me", not a paragraph at the foot of the form where
   it is read after the choice if at all.

   Moving a sentence into a tooltip hides it from anyone who does not reach
   for it, so the checks below are the same three the import hint carries --
   the icon is beside the button, the sentence is the icon's accessible name
   whether or not it is open, and hovering puts it on screen -- plus the one
   this move is most likely to break quietly: that the hazard is still being
   said at all. */
{
  /* Located by position, not by copy: a reworded sentence should fail the
     text checks below, not report that the icon moved. */
  const provenance = page.locator(".generate .info-tip");
  check(
    "the phrase-provenance icon is beside the generate button",
    (await provenance.count()) === 1
      && await provenance.isVisible(),
  );
  check(
    "and the form spends no warning block under it doing the same",
    (await page.locator(".gate-card .warning.provenance").count()) === 0,
  );
  /* One sentence now, so both halves are read off the same string: what the
     checks DO cover, and the hazard they do not. The hazard has to survive a
     rewording -- validation is a typo check, so a phrase someone chose
     themselves can pass every one of them and still be guessable, and a
     warning that stops saying so is decoration. */
  const name = (await provenance.getAttribute("aria-label")) ?? "";
  check(
    "its name says the checks are about what was typed",
    /typed a phrase correctly/i.test(name),
  );
  check(
    "and still warns against choosing your own phrase",
    /own phrase/i.test(name) && /secure/i.test(name),
  );
  await provenance.hover();
  const tip = await page
    .waitForSelector('[role="tooltip"]', { timeout: 5_000 })
    .then((el) => el.textContent(), () => "");
  check(
    "hovering it puts that sentence on screen",
    /typed a phrase correctly/i.test(tip ?? ""),
  );
  /* Off the icon again: an open tooltip is a positioned overlay, and the
     checks below read the form underneath it. */
  await page.mouse.move(0, 0);
  await page.waitForFunction(
    () => document.querySelector('[role="tooltip"]') === null,
    null,
    { timeout: 5_000 },
  );
}

/* The control that cannot be pressed is the one most likely to be asked
   about, and a `disabled` button answers a hover with nothing -- the browser
   delivers it no hover at all, so the tooltip never fires.

   Back to three words for it: 24 is the state where this button is
   AVAILABLE, and the typo phrase above is 24. The typo goes back afterwards,
   so what follows sees the field it expects. Here rather than beside the
   first three-word check because the first hover on a freshly loaded page
   opens nothing whatever it is over, and the icon above has warmed the
   tooltip up. */
await page.locator("#phrase").fill("abandon abandon abandon");
await page.waitForFunction(
  () =>
    document.querySelector(".gate-phrase-copy")
      ?.getAttribute("aria-disabled") === "true",
  null,
  { timeout: 30_000 },
);
await gateCopy.hover();
const copyTip = await page
  .waitForSelector('[role="tooltip"]', { timeout: 5_000 })
  .catch(() => null);
check(
  "the copy button says what it is while it is still refusing to run",
  /copy/i.test((await copyTip?.textContent()) ?? ""),
);
/* Read off the page rather than named: the tooltip was the inverted pair,
   which in the dark palettes is a pale box with black text sitting on top of
   the theme rather than in it. Compared against the card it floats over,
   because that is the surface it is supposed to be made of. */
check(
  "and it is painted in the theme's own surface, not the inverse of it",
  await page.evaluate(() => {
    const tip = document.querySelector('[role="tooltip"]');
    const card = document.querySelector(".gate-card");
    if (!tip || !card) return false;
    const paint = (el) => getComputedStyle(el).backgroundColor;
    return paint(tip) === paint(card);
  }),
);
/* Reachable is not pressable. The browser is no longer refusing the press,
   so the component has to, and half a secret on the clipboard is what that
   refusal is for. */
await gateCopy.click({ force: true });
check(
  "and pressing it anyway copies nothing",
  (await gateCopy.getAttribute("aria-disabled")) === "true"
    && (await gateCopy.innerHTML()).includes('data-glyph="copy"'),
);
await page.mouse.move(0, 0);
await page.waitForFunction(
  () => document.querySelector('[role="tooltip"]') === null,
  null,
  { timeout: 5_000 },
);
/* The field as the checks below expect to find it. */
await page.locator("#phrase").fill(typo.join(" "));
await page.waitForFunction(
  () => {
    const t = document.querySelector(".phrase-status")?.textContent ?? "";
    return t.includes("24/24") && t.includes("checksum failed");
  },
  null,
  { timeout: 30_000 },
);

/* The keyboard focus ring, counted in painted pixels rather than in declared
   properties -- which is the only way to see this one. The ring was declared
   all along: `outline-offset: 2px` on every button, in every palette. It was
   never drawn in either edgerunner palette, because `clip-path` cut the button
   out of its own box and an outline two pixels outside that polygon is
   outside the clip. Computed style reports the outline either way, so nothing
   short of reading the pixels can tell the two apart.

   Screenshotted into the page and decoded by the browser's own canvas: there
   is no image decoder here, and Chromium already has one. Measured both ways
   before the fix -- 1066 accent pixels with the chamfer in the box, zero with
   the clip -- so this fails on the mechanism it is here to hold. */
const ringPixels = async (selector) => {
  const box = await page.locator(selector).boundingBox();
  if (box === null) return 0;
  const pad = 8;
  const shot = (await page.screenshot({
    clip: {
      x: Math.max(0, box.x - pad),
      y: Math.max(0, box.y - pad),
      width: box.width + pad * 2,
      height: box.height + pad * 2,
    },
  })).toString("base64");
  return page.evaluate(async (png) => {
    /* The token is a hex string; the canvas speaks rgb. The browser converts
       it, rather than this file carrying a parser for a colour it does not
       own. */
    const probe = document.createElement("span");
    probe.style.color = getComputedStyle(document.documentElement)
      .getPropertyValue("--color-accent-text").trim();
    document.body.append(probe);
    const [r0, g0, b0] = (getComputedStyle(probe).color.match(/\d+/g) ?? [])
      .map(Number);
    probe.remove();
    const img = new Image();
    img.src = `data:image/png;base64,${png}`;
    await img.decode();
    const canvas = document.createElement("canvas");
    canvas.width = img.width;
    canvas.height = img.height;
    const ctx = canvas.getContext("2d");
    if (ctx === null) return 0;
    ctx.drawImage(img, 0, 0);
    const { data } = ctx.getImageData(0, 0, canvas.width, canvas.height);
    let hits = 0;
    for (let i = 0; i < data.length; i += 4) {
      if (
        Math.abs(data[i] - r0) < 24 && Math.abs(data[i + 1] - g0) < 24
        && Math.abs(data[i + 2] - b0) < 24
      ) hits++;
    }
    return hits;
  }, shot);
};

{
  const generate = page.locator(".generate .btn");
  const shape = await generate.evaluate((el) => {
    const style = getComputedStyle(el);
    return {
      clip: style.clipPath,
      corner: style.cornerShape,
      radius: style.borderTopRightRadius,
    };
  });
  check(
    `the chamfer is part of the button's box (${shape.corner}, ${shape.radius})`,
    shape.clip === "none" && shape.corner === "bevel"
      && Number.parseFloat(shape.radius) > 0,
  );
  /* And off the thing you type into, which is the only `field` on screen
     before the map exists. It carries a step more inline padding than a
     square one needs, so a caret at the start of the line clears the corner
     rather than sitting in it. */
  const typed = await page.locator("#phrase").evaluate((el) => {
    const style = getComputedStyle(el);
    return {
      clip: style.clipPath,
      corner: style.cornerShape,
      radius: Number.parseFloat(style.borderTopRightRadius),
      pad: Number.parseFloat(style.paddingInlineStart),
    };
  });
  check(
    `and off the phrase field, padded clear of it (${typed.radius}px cut, ${typed.pad}px in)`,
    typed.clip === "none" && typed.corner === "bevel" && typed.radius > 0
      && typed.pad > typed.radius,
  );
  /* Tabbed to, not focused by script: the ring is `:focus-visible`, and a
     programmatic focus does not make it visible. */
  await page.locator("#phrase").focus();
  for (let i = 0; i < 6; i++) {
    await page.keyboard.press("Tab");
    const focused = await page.evaluate(() =>
      document.activeElement?.className ?? ""
    );
    if (focused.includes("btn-quiet")) break;
  }
  const hits = await ringPixels(".generate .btn");
  check(
    `and a keyboard focus ring is actually painted around it (${hits} px)`,
    hits > 0,
  );
  await page.locator("#phrase").focus();
}

/* "Generate one for me" must produce a phrase this same app accepts. A
   generator whose output fails its own checksum would strand a user who had
   already written 24 words down. Two presses must also differ: a generator
   wired to a constant would pass every other check here.

   Wait for the value to CHANGE, not merely to be 24 words. The typo phrase
   above is already 24 words, so a length check is satisfied before the click
   has done anything, leaving a request in flight to land later and overwrite
   whatever the test does next. */
const beforeGenerate = await page.locator("#phrase").inputValue();
await page.locator(".generate .btn").click();
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
    t.includes("Save these 24 words in a password vault")
  ),
);
/* The vault half of that warning needs a way to get the words out. Read back
   off the real clipboard, because a button that says it copied and did not is
   the failure this is for -- and the tick has to say so where the press
   happened, which is the same button in the same green the address uses. */
check("a whole phrase can be copied", !(await gateCopy.isDisabled()));
await gateCopy.click();
check(
  "the clipboard takes the phrase itself",
  (await page.evaluate(() => navigator.clipboard.readText()))
    === firstGenerated,
);
check(
  "and the button says so where it was pressed",
  await page
    .waitForFunction(
      () =>
        document.querySelector(".gate-phrase-copy")?.getAttribute("aria-label")
          === "Phrase copied",
      null,
      { timeout: 5_000 },
    )
    .then(() => true, () => false),
);
await page.locator(".generate .btn").click();
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
   this test just put in it. That render is also the one that drops the
   write-it-down notice. */
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
    t.includes("Save these 24 words in a password vault")
  ),
);

/* Appearance, from the gate.

   The settings gear lives in the panel header, which does not exist until a
   map is open -- so before this the only screen a person can be stuck on was
   the one screen with no way to change how it looks. Someone reading 24 words
   off paper in a bright room could not turn the lights up.

   Driven through the control and asserted on the ROOT attribute and on paint:
   a picker that sets state nothing reads would pass a click-and-see-the-label
   check. Put back to the default afterwards, because the theme section far
   below asserts that nothing has been chosen yet, and it is right to. */
check(
  "the gate offers a theme as well as a language",
  await page.locator(".gate-card .theme .dropdown-button").isVisible(),
);
const gateLightness = async () => {
  const bg = await page.locator(".gate-card").first()
    .evaluate((n) => getComputedStyle(n).backgroundColor);
  const nums = bg.match(/-?[\d.]+/g)?.map(Number) ?? [];
  return bg.startsWith("oklab") || bg.startsWith("oklch")
    ? nums[0]
    : (nums[0] + nums[1] + nums[2]) / (3 * 255);
};
const gateDark = await gateLightness();
await chooseFrom(".gate-card .theme", "light");
await page.waitForFunction(
  () => document.documentElement.getAttribute("data-theme") === "light",
  null,
  { timeout: 10_000 },
);
const gateLight = await gateLightness();
check(
  `choosing one repaints the gate itself (${gateDark.toFixed(2)} -> ${
    gateLight.toFixed(2)
  })`,
  gateLight > gateDark + 0.2,
);
/* Back to the default, which is the one theme that wears no attribute -- so
   this also says the control can return to it rather than only leave it. */
await chooseFrom(".gate-card .theme", "edge-dark");
await page.waitForFunction(
  () => document.documentElement.getAttribute("data-theme") === null,
  null,
  { timeout: 10_000 },
);
check("and the gate can put it back to the default", true);

await page.locator("button[type=submit]").click();

/* The Argon2id derivation runs here. Generous, because a cold worker on a
   loaded machine is slower than the number anyone quotes. */
await page.waitForSelector(".map-wrap", { timeout: 60_000 });
check("map opens after derivation", true);

/* The map has to occupy its half of the window, which the element existing
   does not imply.

   This caught a real one. MapLibre puts `maplibregl-map` on the same element
   the stylesheet calls `.map`, and its own rule sets `position: relative` with
   no height. One class each, so the later stylesheet wins -- and when the map
   moved into its own chunk, its CSS started arriving in a second file loaded
   after the app's. The map computed to height 0. Everything still mounted,
   tiles still loaded, `.map-wrap` still appeared; clicks landed on a map with
   no area, and the first complaint was an unrelated check about the coordinate
   row several hundred lines below. Asserted here, where it becomes true, so
   next time it is a diagnosis rather than a hunt. */
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

/* Nothing may have been persisted. A stated guarantee of the design, so it is
   asserted rather than assumed. */
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

/* The core is reachable only through the worker. The key not being on the main
   thread is the whole point of putting it there. */
const keyOnMainThread = await page.evaluate(
  () => typeof globalThis.tessarium !== "undefined",
);
check("core is not loaded on the main thread", !keyOnMainThread);

/* A freshly spawned worker has no key. That is what confining the key to one
   worker buys. */
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
   existed, to write an address inside each square. It was removed because a
   screenshot of a labelled grid hands over fifty (address, real place) pairs
   from a user who thought they were sharing a picture of a street, and each
   pair is material for searching out their phrase. */
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

   The server under test started with an EMPTY basemap directory and its
   download source pointed at a second instance of this same server, which
   serves a generated fixture archive. So this drives the whole pipeline with
   no external network: the missing-basemap banner, the world-map-first offer,
   the estimate, our Range client against our own Range server, the extract,
   the assets tarball, the style swap without a page reload -- and then a
   SECOND download that must MERGE detail into the archive rather than replace
   it, which is what makes "world first, then detail" usable.

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

/* Tiles are served through /tiles across the archives, and a tile nobody holds
   is a quiet 204: past the coverage edge the map must render nothing, not log
   an error per pan.

   NOT 404, and that was tried. MapLibre's vector source swallows a 404 on
   purpose (`if (err && err.status !== 404) throw err`) and files it as an
   empty tile, so the two statuses are indistinguishable to the map and 404
   buys only a red line in devtools. What keeps the coarse map on screen is the
   source's maxzoom telling the truth, not the status code. */
check(
  "a tile with no archive behind it is 204, not an error",
  (await fetch(`${base}/tiles/0/0/0.mvt`)).status === 204,
);
check(
  "a malformed tile path is 404",
  (await fetch(`${base}/tiles/3/8/0.mvt`)).status === 404
    && (await fetch(`${base}/tiles/3/04/0.mvt`)).status === 404,
);

/* The guard, against the real route rather than the predicate. A page the user
   is merely visiting shares this loopback socket with the UI, and nothing here
   asks for credentials -- so without the guard, that page could start a
   download, delete a map, or switch on the network cache. It cannot read the
   reply either way; what matters is that the side effect never runs. */
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
   socket, or the next request on that connection parses its tail. When the
   body is too big to take off, the connection has to end instead. */
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

/* The basemap endpoints need no --api and sit outside the rate limiter, so an
   unbounded read here would let a caller kill the process by declaring a body
   larger than memory. The bound is 4 MiB against a real ceiling of about
   250 KB -- every region the UI knows, polygons included, at once. */
const oversized = await fetch(`${base}/api/basemap-estimate`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: `{"regions":[${"null,".repeat(1_000_000)}null]}`,
});
check(
  "a request body past the bound is refused, not buffered",
  oversized.status === 413,
);
/* And the connection ends with it. A body over the bound cannot be drained, so
   the rest of it would still be on the socket when the next request began
   parsing, and would be read as part of that request. */
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

/* Polygon clipping, end to end: the same box estimated whole, then clipped to
   a triangle covering part of it, must shrink rather than vanish. The fixture
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

/* Wait for a download to complete, by generation. A tiny fixture download can
   run start to done between two UI polls, and the generation in the status
   envelope is what makes that visible. */
const awaitDone = async (generation) => {
  const outcome = await until(async () => {
    const status = await (await postJson("basemap-status")).json();
    return status.generation === generation && status.job?.state === "done"
      ? { done: true }
      : status.job?.state === "failed"
      ? { done: false, reason: status.job.reason }
      : false;
  });
  if (outcome && !outcome.done) {
    console.log(`  download failed: ${outcome.reason}`);
  }
  return outcome ? outcome.done : false;
};

await bannerAction.click();
await page.waitForSelector(".download-card", { timeout: 10_000 });
check("the download card opens from the banner", true);
/* The card offers regions and nothing else. Every package now carries the
   world overview at the depth the map draws it, so there is no planet left to
   fetch and the card must not pretend otherwise -- not here, on the empty map
   that used to lead with exactly that offer. */
check(
  "and offers no download of the planet",
  (await page.locator(".download-world").count()) === 0,
);

/* The download bar took whatever the browser drew. `<progress>` carried an
   `accent-color`, which Chrome ignores for this element, so it painted its
   own green -- the one colour in the application that belonged to no palette,
   sitting under a card whose every other pixel is a token.

   Read off the pixels, because a computed style cannot answer it: Chrome
   exposes nothing useful for `::-webkit-progress-value`, and the probe that
   asked returned the track's colour for both halves. A bar of this file's own
   making, at a size worth sampling, rather than waiting for a real download
   to be a known fraction done. */
const barPaint = async () => {
  await page.evaluate(() => {
    const bar = document.createElement("progress");
    bar.id = "paint-probe";
    bar.max = 100;
    bar.value = 40;
    bar.style.cssText =
      "position:fixed;left:20px;top:20px;width:200px;height:20px;z-index:99";
    document.body.append(bar);
  });
  const png = (await page.locator("#paint-probe").screenshot())
    .toString("base64");
  const paint = await page.evaluate(async (data) => {
    const img = new Image();
    img.src = `data:image/png;base64,${data}`;
    await img.decode();
    const canvas = document.createElement("canvas");
    canvas.width = img.width;
    canvas.height = img.height;
    const ctx = canvas.getContext("2d");
    if (ctx === null) return null;
    ctx.drawImage(img, 0, 0);
    const at = (fraction) => {
      const d = ctx.getImageData(
        Math.round(img.width * fraction),
        Math.round(img.height / 2),
        1,
        1,
      ).data;
      return `rgb(${d[0]}, ${d[1]}, ${d[2]})`;
    };
    /* The tokens are hex and the canvas speaks rgb, so the browser converts
       them rather than this file carrying a parser for colours it does not
       own. */
    const token = (name) => {
      const probe = document.createElement("span");
      probe.style.color = getComputedStyle(document.documentElement)
        .getPropertyValue(name).trim();
      document.body.append(probe);
      const value = getComputedStyle(probe).color;
      probe.remove();
      return value;
    };
    return {
      filled: at(0.2),
      empty: at(0.8),
      accent: token("--color-accent"),
      line: token("--color-line"),
    };
  }, png);
  await page.evaluate(() => document.getElementById("paint-probe")?.remove());
  return paint;
};

const bar = await barPaint();
check(
  `the download bar fills with the palette's accent (${bar?.filled})`,
  bar !== null && bar.filled === bar.accent,
);
check(
  `and its track is the palette's line (${bar?.empty})`,
  bar !== null && bar.empty === bar.line,
);

/* The panel's text has three roles and nothing else:

     panel-title   what a section IS             mono, 12, uppercase, ink
     panel-label   a thing inside that section   sans, 14, medium,    ink
     panel-note    what is true about it         sans, 14, regular,   ink-soft

   It had been seven, most written out in a class list. "DOWNLOADED MAPS" was
   the body face at 11px, indented 10px past the rows it labelled, beside an
   "OFFLINE MAPS" in mono at 12; a checkbox's own text carried no class at all
   and inherited 16px from the document; and a row's name was brighter than
   the heading above it.

   Read off the page rather than off the class names: a shared class is not
   the claim, a shared rendering is. The other direction -- that an element
   rendering as a role also WEARS it -- is checked below, because a role
   reached by `@apply` under another name is a rendering you cannot find from
   the element. */
const roles = await page.evaluate(() => {
  const face = (selector) => {
    const el = document.querySelector(selector);
    if (el === null) return null;
    const style = getComputedStyle(el);
    return {
      family: style.fontFamily,
      transform: style.textTransform,
      size: style.fontSize,
      weight: style.fontWeight,
      color: style.color,
    };
  };
  const ink = (name) => {
    const probe = document.createElement("span");
    probe.style.color = getComputedStyle(document.documentElement)
      .getPropertyValue(name).trim();
    document.body.append(probe);
    const value = getComputedStyle(probe).color;
    probe.remove();
    return value;
  };
  return {
    section: face(".download-card > .panel-section-head > .panel-title"),
    group: face(".download-import .panel-title"),
    quiet: face(".region-sub .panel-title"),
    picker: face('label[for="region-filter"]'),
    note: face(".download-card .hint"),
    check: face(".download-browse .panel-note"),
    ink: ink("--color-ink"),
    soft: ink("--color-ink-soft"),
  };
});

const sameRole = (a, b) =>
  a !== null && b !== null
  && JSON.stringify(a) === JSON.stringify(b);

check(
  `a section's label is one label (${
    roles.group?.family?.split(",")[0]
  } ${roles.group?.size})`,
  sameRole(roles.section, roles.group),
);
check(
  "and it is the panel's ink, being the most important thing in its section",
  roles.section?.color === roles.ink,
);
/* The same label said quietly, for a group inside a ROW: a white uppercase
   heading repeated down a list of two hundred countries is a texture, not a
   hierarchy. Everything but the colour matches. */
check(
  "a group inside a row wears the same label, in soft",
  roles.quiet !== null && roles.section !== null
    && roles.quiet.family === roles.section.family
    && roles.quiet.size === roles.section.size
    && roles.quiet.transform === roles.section.transform
    && roles.quiet.color === roles.soft,
);
/* The third role, and its own: a thing inside a section is neither the
   section's label nor a note about it. The row names in the ledger are
   checked against this one further down, where a downloaded region exists to
   have a name. */
check(
  `a thing in a section is its own role (${roles.picker?.size} ${roles.picker?.weight})`,
  roles.picker !== null && roles.picker.color === roles.ink
    && roles.picker.transform === "none"
    && !sameRole(roles.picker, roles.section)
    && !sameRole(roles.picker, roles.note),
);
/* A checkbox's text is a note about a setting. It had no class at all, so it
   inherited the document's 16px -- two points larger than every other line in
   the card, and in the panel's full ink beside notes in soft. */
check(
  `and a note is one note (${roles.check?.size} ${roles.check?.color})`,
  roles.check !== null && roles.note !== null
    && roles.check.size === roles.note.size
    && roles.check.color === roles.note.color
    && roles.check.color === roles.soft,
);
check(
  "with nothing in the card smaller than the label above it",
  Number.parseFloat(roles.picker?.size ?? "0")
    >= Number.parseFloat(roles.section?.size ?? "99"),
);

/* And a role is WORN, not aliased.

   `region-group` used to be `@apply panel-title` under another name: five
   headings rendered as the panel's section label while nothing in their
   markup said so, and the one word devtools could tell you about such an
   element appeared nowhere else in the stylesheet. This asks the other
   question -- of everything on screen that READS as a section label, does it
   say `panel-title`? -- which no check on the class names can.

   The signature is the mono face at the title's size in uppercase, which
   nothing else in the panel is. */
const unworn = await page.evaluate(() => {
  const title = document.querySelector(".panel-title");
  if (title === null) return null;
  const want = getComputedStyle(title);
  const signature = (style) =>
    style.fontFamily === want.fontFamily && style.fontSize === want.fontSize
    && style.textTransform === want.textTransform
    && style.fontWeight === want.fontWeight;
  return [...document.querySelectorAll(".app *")]
    .filter((el) =>
      el.textContent.trim().length > 0 && el.children.length === 0
      && signature(getComputedStyle(el))
      && !el.classList.contains("panel-title")
    )
    .map((el) => `${el.tagName.toLowerCase()}.${[...el.classList].join(".")}`);
});
check(
  `everything that reads as a section label wears panel-title (${
    unworn?.join(" ")
  })`,
  unworn !== null && unworn.length === 0,
);

/* One component draws them all, so they have one shape: a `<section>`, named
   by its own heading, and a heading that steps down when the section is
   inside another. The panel had two sections ruled underneath and two ruled
   on top, three `<p>`s standing in for a heading -- unreachable by heading
   navigation -- and the title-and-control row built twice. */
const sections = await page.evaluate(() =>
  [...document.querySelectorAll(".panel-section, .panel-group")].map((el) => {
    const head = el.firstElementChild;
    const heading = head?.querySelector(".panel-title") ?? null;
    return {
      tag: el.tagName.toLowerCase(),
      head: head?.className ?? null,
      level: heading?.tagName.toLowerCase() ?? null,
      named: heading !== null
        && el.getAttribute("aria-labelledby") === heading.id,
      group: el.classList.contains("panel-group"),
      /* The rule that separates one region from the next is drawn once, by
         the lower one. On some and underneath others, a running download put
         two lines between the address and its progress. */
      ruled: getComputedStyle(el).borderTopWidth !== "0px",
      under: getComputedStyle(el).borderBottomWidth !== "0px",
    };
  })
);
check(
  `every region of the panel is one (${sections.length})`,
  sections.length >= 4,
);
check(
  "each is a section, headed, and named by its own heading",
  sections.every((sec) =>
    sec.tag === "section" && sec.head === "panel-section-head" && sec.named
  ),
);
check(
  "a region is an h2 and a region inside one is an h3",
  sections.every((sec) => sec.level === (sec.group ? "h3" : "h2")),
);
check(
  "the panel's own regions are ruled on top, and nothing underneath",
  sections.every((sec) => (sec.group || sec.ruled) && !sec.under),
);

/* The one setting here that reaches the network without a press says what it
   does in an icon rather than in four lines of small print under a one-line
   control -- the same move the gate's provenance note made.

   The icon is OUTSIDE the checkbox: React Aria's Checkbox is the label, so a
   press anywhere inside it toggles the setting, and an info icon that flips
   the thing it explains is worse than no icon. */
check(
  "the browse setting explains itself in an icon",
  (await page.locator(".download-browse .info-tip").count()) === 1
    && (await page.locator(".download-browse .hint").count()) === 0,
);
check(
  "which does not sit inside the control it explains",
  (await page.locator(".download-browse .region-check .info-tip").count())
    === 0,
);
/* So the overview is put on disk the way a package puts it there, before
   anything below can rely on it. Through the server, which still knows how to
   write world.pmtiles and still checks that a download claiming to be the
   planet covers it -- not through the app, which no longer asks. This is the
   one place the suite reaches past the UI to stage what an install ships. */
const staged = await postJson("basemap-download", {
  regions: [{
    min_lon: -180,
    min_lat: -85,
    max_lon: 180,
    max_lat: 85,
    max_zoom: 6,
  }],
  world: true,
});
check(
  "the overview is staged the way a package ships it",
  staged.status === 200,
);
check("the world download completes at generation one", await awaitDone(1));
/* Reopened, because the app was not watching. A download it starts is one it
   follows to its toast; this one arrived underneath it, exactly as a package's
   does -- on disk before the first run. So the state from here on is the one
   every install opens in: an overview, no region, and no banner. */
await page.reload({ waitUntil: "domcontentloaded" });
await page.locator("#phrase").fill(sampleMnemonic);
await page.waitForSelector(".valid", { timeout: 30_000 });
await page.locator("button[type=submit]").click();
await page.waitForSelector(".map-wrap", { timeout: 60_000 });
check(
  "a store that ships an overview opens with no missing-basemap banner",
  (await page.locator(".banner").count()) === 0,
);

/* The overview is all there is and the map sits at street zoom, so everything
   on screen is overzoomed -- and MapLibre only overzooms past the SOURCE's
   stated maxzoom. The floor source must carry the depth the archives really
   cover the planet at, not a hardcoded number: a source pinned at 15 asked for
   z15 tiles nobody held and rendered a blank basemap over data that was there.
   That depth is measured, and for this fixture it is the single zoom-0 tile.
   The fixture's tiles carry no styled layers, so this reads the source itself
   rather than rendered features. */
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
   fixture, and MapLibre must parse every one cleanly. */
basemapReady = true;

/* Which file the world went into, which is the point of it having its own.
   Every region is its own file and every region file has a Remove button; the
   floor must not be one of them. */
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
/* It is not a region: it writes no record, and is listed anyway -- under an id
   the server made up, flagged, with no date, because nothing recorded fetching
   it. Listing it is what shows a user the map they are standing on, instead of
   leaving the largest file on disk out of "what maps do I have". */
const ledgerAfterWorld = await (await fetch(`${base}/api/basemap-ledger`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: "{}",
})).json();
check(
  "the world overview writes no ledger entry and is listed as itself",
  ledgerAfterWorld.entries?.length === 1
    && ledgerAfterWorld.entries[0].overview === true
    && ledgerAfterWorld.entries[0].id === "world"
    && ledgerAfterWorld.entries[0].file === ""
    && ledgerAfterWorld.entries[0].completed === 0
    && ledgerAfterWorld.entries[0].bytes > 0,
);
/* Every verb that takes an id off that list has to refuse this one.

   Two locks, and the outer one answers first: the overview is listed under a
   word, every real id is hex, and the route parses ids before a handler sees
   them -- so the request never reaches the code that removes things. The inner
   lock is the handlers refusing the id by name, with the reason a person would
   need. That one is driven in ocaml/server/test/test_regions.ml, because
   nothing over HTTP gets past the first lock to reach it. Both are kept:
   whichever is removed, the other still holds. */
for (
  const [verb, endpoint] of [
    ["removed", "basemap-remove"],
    ["exported", "basemap-export"],
    ["updated", "basemap-update"],
  ]
) {
  const res = await postJson(endpoint, { id: "world" });
  check(
    `the overview cannot be ${verb} through its listed id (got ${res.status})`,
    res.status === 400,
  );
}
check(
  "and it is still on disk after all three tried",
  (await fetch(`${base}/basemap/world.pmtiles`, { method: "HEAD" })).status
    === 200,
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
/* With an overview and no region, the detail source describes an archive that
   does not exist. It says so with an empty range: MapLibre skips everything
   shallower than minzoom and never looks past maxzoom, so the source asks for
   nothing rather than a viewport of misses on every pan, which is what a fresh
   install used to pay until its first download. The offer to download this
   area survives that honesty because the server, not this number, decides the
   coverage question. */
check(
  `with no region downloaded the detail source asks for nothing (${tilejson.minzoom}-${tilejson.maxzoom})`,
  tilejson.minzoom > tilejson.maxzoom && Array.isArray(tilejson.bounds)
    && tilejson.bounds.length === 4,
);
/* The floor is the whole planet or it is not a floor -- and only as deep as
   the archive really covers the whole planet, which for one downloaded region
   is the single zoom-0 tile every download starts with. Claiming more claims a
   tile that is not there, which draws as empty and takes the map off screen. */
check(
  "world.json floors the planet at the depth the archive really covers it",
  worldjson.minzoom === 0 && worldjson.maxzoom === 0
    && worldjson.bounds.join() === "-180,-85,180,85",
);
/* Meeting rather than overlapping keeps a viewport to one fetch: below the
   floor's depth the detail source would ask for the very same tiles. */
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

/* The drawer resizes from the KEYBOARD, which is the half a splitter usually
   misses. Left widens, because the key moves the separator and the panel is to
   its right. */
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
   nothing to anyone who is not watching the pixels move. */
check(
  "and the separator announces the new width",
  Number(
    await page.locator(".panel-resizer").getAttribute("aria-valuenow"),
  ) === Math.round(widthAfter),
);
/* Back to the default, so nothing downstream inherits a resized layout. */
await page.locator(".panel-resizer").dblclick();
/* What you take hold of is one mark in two orientations. The drawer's edge
   carried a square-ended bar while the sheet's top carried a rounded pill --
   two shapes for the same affordance, and in the edgerunner palettes the
   rounded one was the only round end on screen. Read off the page: the
   claim is a shared rendering, not a shared class name. */
/* The pointer is parked on the resizer by the double click above, and the
   handle lights on hover -- so it is moved off, and its fade back is WAITED
   for, before the resting colours are compared. Read without the wait, the
   drawer's handle came back mid-transition, a colour that is neither the one
   it rests at nor the one it lights to. The hover is checked on its own
   below. */
/* Focus too, not just the pointer: the separator was driven from the keyboard
   above, so `:focus-visible` still holds it lit. */
await page.mouse.move(4, 4);
await page.locator(".panel-resizer").evaluate((el) => el.blur());
/* Polled until it stops moving rather than awaited through the Animation API:
   the transition has not been created yet at the moment the pointer leaves,
   so `getAnimations()` comes back empty and resolves at once. */
const settle = async () => {
  let last = null;
  for (let i = 0; i < 40; i++) {
    const now = await page.locator(".panel-resizer > .grab-pill")
      .evaluate((el) => getComputedStyle(el).backgroundColor);
    if (now === last) return now;
    last = now;
    await page.waitForTimeout(50);
  }
  return last;
};
const atRest = await settle();
const handles = await page.evaluate(() => {
  const read = (selector) => {
    const el = document.querySelector(selector);
    if (el === null) return null;
    const style = getComputedStyle(el);
    return {
      width: style.width,
      height: style.height,
      radius: style.borderTopLeftRadius,
      clip: style.clipPath,
      turned: style.rotate,
      paint: style.backgroundColor,
    };
  };
  return {
    sheet: read(".sheet-grab .grab-pill"),
    drawer: read(".panel-resizer .grab-pill"),
  };
});
check(
  `the drawer's handle is the sheet's, turned (${handles.drawer?.turned})`,
  handles.sheet !== null && handles.drawer !== null
    && handles.drawer.width === handles.sheet.width
    && handles.drawer.height === handles.sheet.height
    && handles.drawer.clip === handles.sheet.clip
    && handles.drawer.radius === handles.sheet.radius
    && atRest === handles.sheet.paint
    && handles.drawer.turned === "90deg"
    && handles.sheet.turned === "none",
);
/* The edge is a 24px target holding a mark twice that long. It was a flex
   item with nothing saying it could not shrink, so it came out the width of
   its target and read as a stub. */
check(
  `and is as long as the sheet's (${handles.drawer?.width})`,
  handles.drawer !== null
    && Number.parseFloat(handles.drawer.width)
      > (await page.locator(".panel-resizer").boundingBox()).width,
);
/* Lighting under the pointer is the only thing that says the edge is a
   control at all: there is no label on it and no border around it. */
await page.locator(".panel-resizer").hover();
const lit = await settle();
check(
  `and it lights under the pointer, being a control with no other sign (${lit})`,
  lit !== atRest,
);
await page.mouse.move(4, 4);
await settle();

/* And in a palette that cuts, neither of them has a round end. */
check(
  `with no round end where the palette cuts (${handles.drawer?.radius})`,
  handles.drawer !== null
    && Number.parseFloat(handles.drawer.radius) === 0
    && (handles.drawer.clip.match(/^polygon\((.*)\)$/)?.[1] ?? "")
        .split(",").length === 6,
);

/* The drawer sits OVER the map: the map's own box must not change when the
   drawer opens, shuts or is dragged. As a grid column it changed every time,
   so MapLibre re-laid out and the view moved under whoever was reading it. */
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
check(
  "a collapsed drawer is out of the accessibility tree",
  !(await page.locator(".panel").isVisible()),
);
check(
  "and offers a way back",
  (await page.locator(".panel-reopen button").count()) === 1,
);
/* And that way back must not sit on top of MapLibre's own controls.

   With the drawer shut, nothing covers the right edge, so MapLibre puts its
   zoom and locate buttons exactly where the reopen tab is. The rule that keeps
   that corner clear has to outrank MapLibre's stylesheet, which loads after
   ours -- so this is geometry, not a class check: a single-class rule looks
   correct in the source and does nothing in the page. */
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

/* --------------------------------- the panel as a sheet --------------------

   Below --breakpoint-drawer the panel stops being a drawer down the right
   edge and becomes a sheet across the bottom. Nothing the application draws
   over the map can see the panel, so all of them keep clear of two numbers
   instead -- how much of the right edge is covered, and how much of the
   bottom -- and App.tsx used to write the first of those from the panel's
   width alone.

   On a phone that was a lie about an edge the sheet does not touch, and
   every overlay believed it: MapLibre's zoom column landed 340px in from the
   right, which on a 390px screen is the top-LEFT corner, on top of the
   search field. The attribution went off the left of the screen entirely,
   and the scale bar and the map's notes sat under the sheet.

   Geometry rather than a class check, for the reason the reopen tab above is
   geometry: these numbers reach MapLibre through a stylesheet that has to
   outrank MapLibre's own, so a rule can look right in the source and be
   doing nothing at all. A page of its own at a phone's size, because the
   drawer is a different component at that width and the rest of this file
   is about the drawer. */
const phone = await context.newPage();
await phone.setViewportSize({ width: 390, height: 844 });
await phone.goto(base, { waitUntil: "networkidle" });
await phone.locator("#phrase").fill(sampleMnemonic);
await phone.waitForSelector(".valid", { timeout: 30_000 });
await phone.locator("button[type=submit]").click();
await phone.waitForSelector(".map-wrap", { timeout: 60_000 });
/* Out far enough for the grid to stop being drawn, which is one of the three
   things the panel has to say about a view. */
await phone.evaluate(() => window.__tessarium_map?.setZoom(16));
await phone.waitForFunction(
  () => document.querySelectorAll(".view-note").length > 1,
  null,
  { timeout: 15_000 },
).catch(() => {});

const overlaid = (a, b) =>
  !(a.right <= b.left || b.right <= a.left || a.bottom <= b.top
    || b.bottom <= a.top);
const overlays = () =>
  phone.evaluate(() => {
    const box = (selector) => {
      const el = document.querySelector(selector);
      if (!el) return null;
      const r = el.getBoundingClientRect();
      return { left: r.left, top: r.top, right: r.right, bottom: r.bottom };
    };
    return {
      wrap: box(".map-wrap"),
      /* The buttons themselves for the search check and the container for
         the edge check: MapLibre's container carries the margin, and it is
         the container that the offset moves. */
      zoom: box(".map-wrap .maplibregl-ctrl-top-right"),
      buttons: box(
        ".map-wrap .maplibregl-ctrl-top-right .maplibregl-ctrl-group",
      ),
      attribution: box(".map-wrap .maplibregl-ctrl-bottom-right"),
      scale: box(".map-wrap .maplibregl-ctrl-bottom-left"),
      search: box(".map-search"),
      panel: box(".panel"),
      tab: box(".panel-reopen"),
      grab: box(".sheet-grab-button"),
    };
  });

const sheet = await overlays();
check(
  "at a phone's width the panel covers the bottom of the map, not its side",
  sheet.panel.left <= sheet.wrap.left + 1
    && sheet.panel.right >= sheet.wrap.right - 1,
);
check(
  `the zoom column stays at the map's right edge (${
    Math.round(sheet.wrap.right - sheet.zoom.right)
  }px in)`,
  sheet.wrap.right - sheet.zoom.right <= 1,
);
check(
  "and clear of the search field",
  !overlaid(sheet.buttons, sheet.search),
);
check(
  `the attribution stays on the screen (left edge at ${
    Math.round(sheet.attribution.left)
  })`,
  sheet.attribution.left >= sheet.wrap.left,
);
/* A pixel of tolerance throughout: the sheet's height is a percentage of an
   odd viewport, so its top edge lands on a fraction. */
check(
  "and above the sheet rather than under it",
  sheet.attribution.bottom <= sheet.panel.top + 1,
);
check(
  "the scale bar clears the sheet too, in the other corner",
  sheet.scale.bottom <= sheet.panel.top + 1,
);

/* --------------------------- what the map has to say ----------------------

   It used to say it itself, in a card over the ground it was about: at a
   phone's width that card was 312x102 in a strip it shared with the scale
   bar and the credit, and the three of them piled up above the sheet.

   The map draws none of it now. The panel says all three -- no detail here,
   too far out for the grid, too many squares to draw -- under a heading of
   its own, above the square. Nothing is left on the map to keep in sync with
   it, which is the check: not that the panel gained a section, but that
   there is exactly one place either of them says any of this. */
const said = await phone.evaluate(() => ({
  onMap: document.querySelectorAll(".map-notes, .map-note").length,
  section: document.querySelectorAll(".view-notes").length,
  rows: [...document.querySelectorAll(".view-note")].map((r) =>
    (r.textContent ?? "").trim()
  ),
  heading: document.querySelector(".view-notes .panel-title")?.textContent
    ?.trim() ?? null,
  /* Nothing in the section is pressable: the one thing to do about any of
     it is the download button in the panel's own header, which the coverage
     row names in words. A button here would be a second way in, beside the
     first, saying the same thing. */
  controls: document.querySelectorAll(".view-notes button, .view-notes a")
    .length,
  header: document.querySelectorAll(".panel-download").length,
  /* Above the square, not below it: it is about where the reader is looking,
     which is the question that comes before which square they picked. */
  beforeSelected: (() => {
    const view = document.querySelector(".view-notes");
    const selected = document.querySelector(".selected");
    if (!view || !selected) return false;
    return (view.compareDocumentPosition(selected)
      & Node.DOCUMENT_POSITION_FOLLOWING) !== 0;
  })(),
}));
check("the map draws no note of its own", said.onMap === 0);
check(
  `the panel says it instead, in one section (${said.section})`,
  said.section === 1,
);
check(
  `both facts are drawn here at once (${said.rows.length})`,
  said.rows.length === 2,
);
check(
  `under its own heading (${said.heading})`,
  said.heading === m("panel_this_view"),
);
check(
  "the uncovered ground is named in the panel's own words",
  said.rows.some((row) => row.startsWith(m("map_coverage_gap"))),
);
check(
  "and the grid's zoom in its own",
  said.rows.includes(m("map_zoom_for_grid")),
);
check(
  `and carries no control of its own (${said.controls})`,
  said.controls === 0,
);
check(
  `pointing at the download button already in the header (${said.header})`,
  said.header === 1,
);
check("and the section sits above the square", said.beforeSelected);

/* And it is written in the same voice as the section under it. "This view"
   carried `m-0 text-sm leading-normal` in its class list -- two thirds of
   `hint` and none of its colour -- so it sat in plain ink directly above a
   sentence in soft, with nothing anywhere saying the two were meant to
   differ. They are one utility now; this reads them back off the page
   because a shared class name is not the claim, a shared rendering is. */
const voices = await page.evaluate(() => {
  const read = (selector) => {
    const el = document.querySelector(selector);
    if (el === null) return null;
    const style = getComputedStyle(el);
    return {
      color: style.color,
      size: style.fontSize,
      leading: style.lineHeight,
      margin: style.margin,
    };
  };
  return { note: read(".view-note"), hint: read(".selected .hint") };
});
check(
  `the view note is set like the square's hint (${voices.note?.color})`,
  voices.note !== null && voices.hint !== null
    && JSON.stringify(voices.note) === JSON.stringify(voices.hint),
);

/* A sheet is closed by its handle. The drawer's pair -- an icon in the panel
   header that means "close the panel on the right", and a tab floating at
   that right edge to bring it back -- are describing a layout this width does
   not have, and both stand down here. */
/* Inside the sheet, all of it. Nothing of the handle stands above the panel's
   top edge, so the map meets the sheet directly: a band of the sheet's own
   colour above the sheet is what read as a separate strip, and no amount of
   moving the pill down fixes a band that is still there. */
check(
  `the sheet wears a handle, wholly inside its own top edge (top ${
    Math.round(sheet.grab.top - sheet.panel.top)
  }px, bottom ${Math.round(sheet.grab.bottom - sheet.panel.top)}px)`,
  sheet.grab !== null && sheet.grab.top >= sheet.panel.top - 1
    && sheet.grab.bottom > sheet.panel.top,
);
check(
  "and the drawer's own hide button is not on a phone",
  !(await phone.locator(".panel-hide").isVisible()),
);

/* Shut, the sheet covers nothing and the handle is all that is left of it,
   lying along the map's bottom edge. The search field still measures from the
   right edge: at 5.5rem of fixed reserve it ran under the zoom buttons here,
   with the field drawn on top of them. */
await phone.locator(".sheet-grab-button").click();
await phone.waitForFunction(
  () => document.querySelector(".panel")?.classList.contains("collapsed"),
  null,
  { timeout: 10_000 },
);
await phone.waitForTimeout(300);
const shut = await overlays();
check(
  "with the sheet shut its handle lies along the map's bottom edge",
  shut.grab !== null && shut.grab.bottom >= shut.wrap.bottom - 1,
);
/* Not "absent": the tab is display:none below the breakpoint, so it is still
   in the document with a zero box. What matters is that nothing is drawn
   there. */
check(
  "and nothing reopens it from the right edge, which is the drawer's gesture",
  !(await phone.locator(".panel-reopen").isVisible()),
);
check(
  `and the search field still stops short of the zoom column (field to ${
    Math.round(shut.search.right)
  }, buttons from ${Math.round(shut.buttons.left)})`,
  !overlaid(shut.buttons, shut.search),
);
/* Down to the handle rather than past it: the sheet covers nothing now, but
   the handle does, and the scale bar reads the two as one number. */
check(
  `the scale bar drops to the handle, not through it (${
    Math.round(shut.grab.top - shut.scale.bottom)
  }px)`,
  Math.abs(shut.scale.bottom - shut.grab.top) <= 2,
);
/* And it brings the sheet back, which is the half a one-way check misses. */
await phone.locator(".sheet-grab-button").click();
await phone.waitForFunction(
  () => !document.querySelector(".panel")?.classList.contains("collapsed"),
  null,
  { timeout: 10_000 },
);
await phone.waitForTimeout(300);
const pulledBack = await overlays();
/* Into the sheet, not onto it: the handle used to rest on the panel's top
   edge with a rule between them, which read as a separate strip. It overlaps
   now -- by less than the header's own padding, so it covers no control --
   and the rule is gone. */
check(
  `and pulling the handle again brings the sheet back (${
    Math.round(pulledBack.grab.bottom - pulledBack.panel.top)
  }px into it)`,
  pulledBack.grab.top >= pulledBack.panel.top - 1
    && pulledBack.grab.bottom > pulledBack.panel.top
    && pulledBack.panel.top < pulledBack.wrap.bottom - 1,
);
/* And in a palette that cuts, the pill is not a pill: six sides, both ends
   mitred at the same 45 degrees as every button around it, symmetrical so it
   does not look like it prefers one side to grab from. This page is in the
   default palette, which is an edgerunner one. */
check(
  "the handle is angular where the palette is",
  await phone.locator(".sheet-grab .grab-pill").evaluate((el) => {
    const style = getComputedStyle(el);
    if (Number.parseFloat(style.borderTopLeftRadius) !== 0) return false;
    /* Counted by vertex rather than matched by shape: the computed value
       mixes units -- `4px 0px` beside `calc(100% - 4px) 100%` -- and neither
       `calc` nor the percentage is a thing to pin. Six is the claim. */
    const body = style.clipPath.match(/^polygon\((.*)\)$/)?.[1];
    return body !== undefined && body.split(",").length === 6;
  }),
);
check(
  "with no rule along its top to say it is a separate thing",
  await phone.locator(".sheet-grab-button").evaluate((el) =>
    getComputedStyle(el).borderTopWidth === "0px"
  ),
);
/* And it clears the header's controls, which sit under it. A handle that
   swallows the top of the download button is worse than a visible seam --
   which is what `max-drawer:pt-8` on the header is for: the sheet carries
   its own room for its handle rather than borrowing the controls'. */
check(
  "and stopping short of the controls it now sits over",
  pulledBack.grab.bottom
    < (await phone.locator(".panel-download").boundingBox()).y,
);
await phone.locator(".sheet-grab-button").click();
await phone.waitForFunction(
  () => document.querySelector(".panel")?.classList.contains("collapsed"),
  null,
  { timeout: 10_000 },
);
await phone.waitForTimeout(300);

/* ------------------------------- the floor ---------------------------------

   320px, the narrowest phone anyone still ships, and the width this
   application stops laying out below: narrower than that and the page scrolls
   rather than the map giving up any more of itself.

   The sheet's header cannot hold the brand and three controls on one row down
   here -- measured, it gives out at 356 -- so it stacks. Left to itself it
   stacked hard left twice over, which reads as two half-empty rows; both
   lines centre instead. Read as an offset from the header's own centre, so
   the claim is "centred" rather than "at some x I wrote down". */
await phone.locator(".sheet-grab-button").click();
await phone.waitForFunction(
  () => !document.querySelector(".panel")?.classList.contains("collapsed"),
  null,
  { timeout: 10_000 },
);
const headLayout = () =>
  phone.evaluate(() => {
    const head = document.querySelector(".panel-head");
    if (head === null) return null;
    const box = head.getBoundingClientRect();
    const brand = head.querySelector(".brand").getBoundingClientRect();
    const controls = head.querySelector("div").getBoundingClientRect();
    const offCentre = (r) =>
      Math.round((r.left - box.left) - (box.right - r.right));
    return {
      stacked: Math.abs(brand.top - controls.top) > 20,
      brand: offCentre(brand),
      controls: offCentre(controls),
      overflows: document.documentElement.scrollWidth
        > document.documentElement.clientWidth,
    };
  });

await phone.setViewportSize({ width: 320, height: 844 });
await phone.waitForTimeout(400);
const floor = await headLayout();
check(
  `at the 320px floor the header stacks (${floor?.stacked})`,
  floor?.stacked === true,
);
check(
  `and both of its rows centre (brand ${floor?.brand}, controls ${floor?.controls})`,
  Math.abs(floor?.brand ?? 99) <= 1 && Math.abs(floor?.controls ?? 99) <= 1,
);
/* And nothing is pushed off the side getting there. The floor is a
   `min-width`, so a NARROWER window scrolls -- but at the floor itself
   nothing should. */
check("with nothing hanging off the side", floor?.overflows === false);

/* Above the stack, the row is a row again: brand left, controls right. A
   rule that centred at every width would leave these two huddled in the
   middle of a 390px header with a gap at each end. */
await phone.setViewportSize({ width: 390, height: 844 });
await phone.waitForTimeout(400);
const roomy = await headLayout();
check(
  `at a phone's own width it is one row again (${roomy?.stacked})`,
  roomy?.stacked === false && (roomy?.brand ?? 0) < -20
    && (roomy?.controls ?? 0) > 20,
);
await phone.locator(".sheet-grab-button").click();
await phone.waitForFunction(
  () => document.querySelector(".panel")?.classList.contains("collapsed"),
  null,
  { timeout: 10_000 },
);
await phone.waitForTimeout(300);

/* --------------------------------- the credit ------------------------------

   MapLibre decides from the map's own width whether the attribution needs a
   toggle, and then draws it open anyway: 194px of credit lying across the
   bottom of a phone. */
const band = () =>
  phone.evaluate(() => {
    const credit = document.querySelector(".maplibregl-ctrl-attrib");
    return {
      creditWidth: Math.round(credit?.getBoundingClientRect().width ?? 0),
      creditCompact: credit?.classList.contains("maplibregl-compact") ?? false,
    };
  });

const strip = await band();
check(
  `at a phone's width MapLibre calls the credit compact (${strip.creditCompact})`,
  strip.creditCompact,
);
check(
  `and it starts behind its toggle (${strip.creditWidth}px)`,
  strip.creditWidth <= 40,
);
await phone.locator(".maplibregl-ctrl-attrib-button").click();
await phone.waitForTimeout(250);
const opened = await band();
check(
  `which a tap still opens (${opened.creditWidth}px)`,
  opened.creditWidth > 100,
);
await phone.close();

/* A map with room keeps the whole line: nothing here repeats a width, so the
   one place that decides is MapLibre, and shutCredit only acts on the maps it
   already called narrow. */
const wideCredit = await page.evaluate(() => {
  const el = document.querySelector(".maplibregl-ctrl-attrib");
  return {
    compact: el?.classList.contains("maplibregl-compact") ?? true,
    width: Math.round(el?.getBoundingClientRect().width ?? 0),
  };
});
check(
  `the desktop map draws its credit in full (${wideCredit.width}px, compact ${wideCredit.compact})`,
  !wideCredit.compact && wideCredit.width > 100,
);

/* ------------------------------------- appearance -------------------------

   Five palettes and a sixth entry that is not one. "Match my device" is a
   deferral rather than a colour, and it has to stay distinguishable from
   having chosen light, or a device that turns dark at dusk stops being
   followed. The attribute says which; the painted colour proves the attribute
   reached anything.

   The DEFAULT wears no attribute, because the stylesheet's @theme block paints
   before one is set. That makes "nothing chosen" and "chose the default" the
   same state on purpose, and it makes the assertion below -- that an untouched
   page is already dark -- fail if the default and the @theme block ever stop
   being the same palette. */
const chosen = () =>
  page.evaluate(() => document.documentElement.getAttribute("data-theme"));

/* Lightness of a painted surface, on one scale. The computed colour arrives as
   oklab() in this browser, whose first number IS lightness; rgb() is
   normalised to the same 0..1 range. */
const surfaceLightness = async (sel) => {
  const bg = await page.locator(sel).first()
    .evaluate((n) => getComputedStyle(n).backgroundColor);
  const nums = bg.match(/-?[\d.]+/g)?.map(Number) ?? [];
  return bg.startsWith("oklab") || bg.startsWith("oklch")
    ? nums[0]
    : (nums[0] + nums[1] + nums[2]) / (3 * 255);
};

check("nobody has chosen a theme to begin with", (await chosen()) === null);
check(
  `and the default is a dark one (panel lightness ${
    (await surfaceLightness(".panel")).toFixed(2)
  })`,
  (await surfaceLightness(".panel")) < 0.5,
);
check(
  "which the browser is told about, so its own chrome matches",
  (await page.evaluate(() =>
    getComputedStyle(document.documentElement).colorScheme
  )) === "dark",
);

/* The map's icons are baked images, one sheet per flavour, and the style names
   the sheet it wants. It named `light` for every theme, so a dark map drew
   white motorway shields over itself. The sheet is the one part of the map the
   palette cannot reach, so it has to be chosen rather than coloured. Read off
   the style the map is holding, because the bug was a string that looked right
   in the source and was never varied. */
const spriteSheet = () =>
  page.evaluate(() =>
    (window.__tessarium_map?.getStyle()?.sprite ?? "").toString()
  );
const sheetIs = (want) =>
  page.waitForFunction(
    (w) =>
      (window.__tessarium_map?.getStyle()?.sprite ?? "").toString()
        .endsWith(`/sprites/v4/${w}`),
    want,
    { timeout: 15_000 },
  ).then(() => true, () => false);
check(
  `the default map asks for the dark sheet (${await spriteSheet()})`,
  await sheetIs("dark"),
);

const pickTheme = async (value) => {
  await page.locator(".panel-foot .theme .dropdown-button").click();
  await page.locator(`.dropdown-option[data-value="${value}"]`).click();
  await page.waitForFunction(
    (want) =>
      (document.documentElement.getAttribute("data-theme") ?? "edge-dark")
        === want,
    value,
    { timeout: 10_000 },
  );
};

/* What a palette resolves to, as four of its load-bearing tokens. Not the
   panel's computed colour, which was tried first and is not an identity: both
   light palettes lay their cards on plain white, so a theme resolving to
   another theme would look identical to one that did not. Ground, card, ink
   and accent together do separate all five. */
const paletteId = () =>
  page.evaluate(() => {
    const s = getComputedStyle(document.documentElement);
    return ["bg", "card", "ink", "accent"]
      .map((t) => s.getPropertyValue(`--color-${t}`).trim()).join(" ");
  });

/* Every entry in the menu, asserted on what it paints rather than on the name
   it set. The five identities must be five DIFFERENT identities further down:
   a theme resolving to another theme is the failure a list of names cannot
   see, and renaming two palettes without repointing one is how it happens. */
const painted = {};
for (
  const [name, wantLight] of [
    ["light", true],
    ["dark", false],
    ["edge-light", true],
    ["edge-dark", false],
    ["night", false],
  ]
) {
  await pickTheme(name);
  painted[name] = await paletteId();
  const lightness = await surfaceLightness(".panel");
  check(
    `choosing ${name} paints a ${wantLight ? "pale" : "dark"} panel (${
      lightness.toFixed(2)
    })`,
    wantLight ? lightness > 0.5 : lightness < 0.5,
  );
  check(
    `and tells the browser ${name} is a ${wantLight ? "light" : "dark"} scheme`,
    (await page.evaluate(() =>
      getComputedStyle(document.documentElement).colorScheme
    )) === (wantLight ? "light" : "dark"),
  );
  /* The map's own controls, which are not this project's markup: MapLibre
     ships them light-only, and they sat white over a dark map until someone
     using the app at night pointed at them. Computed colour, not class names,
     because the bug was a stylesheet this project does not own winning. Every
     palette is checked, because the rule that fixes it is a list, and a sixth
     theme can fall off a list. */
  check(
    `${name}: the zoom buttons follow the theme`,
    (await surfaceLightness(".maplibregl-ctrl-group") < 0.5) !== wantLight,
  );
  check(
    `${name}: and so does the scale bar`,
    (await surfaceLightness(".maplibregl-ctrl-scale") < 0.5) !== wantLight,
  );
  /* Low light takes the dark sheet too: no red sheet is drawn, and `black`,
     the other near-black option, is missing its points of interest. */
  check(
    `${name}: the map asks for the ${wantLight ? "light" : "dark"} sheet`,
    await sheetIs(wantLight ? "light" : "dark"),
  );
}

const ids = Object.values(painted);
check(
  `each theme resolves to its own palette (${
    new Set(ids).size
  } of ${ids.length})`,
  new Set(ids).size === ids.length,
);

/* The default wears NO attribute, so choosing it has to remove one rather than
   set it. Otherwise the stylesheet has a rule nothing matches, and the first
   frame after a reload is a different theme from the one the menu shows. */
await pickTheme("edge-dark");
check(
  "choosing the default clears the attribute rather than setting it",
  (await chosen()) === null,
);

/* The plain themes are plain because five tokens are held at rest, not because
   anything is switched off elsewhere: one colour repeated across the
   gradient's three stops is a solid button, the mono stack is no second
   typeface, and an absent clip is a rectangle. Read back resolved,
   because "at rest" is a property of the values, not of the rule that sets
   them.

   The cut is read off real controls rather than off the token. Two things
   have to be true and only the control can say both: that the utility spends
   the token at all, and that Tailwind emitted a variable nothing in the
   markup mentions by name. Low light joins the plain pair here -- it is a
   palette for keeping night vision, not a second edgerunner. */
const levers = () =>
  page.evaluate(async () => {
    /* A face still loading reports as absent, and `block` means the wordmark
       is drawn in nothing at all until it lands. */
    await document.fonts.ready;
    const s = getComputedStyle(document.documentElement);
    const g = (n) => s.getPropertyValue(n).trim();
    /* null rather than a throw: a selector that has rotted must fail the
       check that reads it, not the evaluate that collects it.

       Both mechanisms, because the chamfer is drawn by `corner-shape` where
       the browser has it and clipped where it does not, and "chamfered" means
       the shape is there AND nothing is clipping it out of its own box. */
    const shape = (sel) => {
      const el = document.querySelector(sel);
      if (el === null) return null;
      const style = getComputedStyle(el);
      return {
        clip: style.clipPath,
        corner: style.cornerShape,
        radius: Number.parseFloat(style.borderTopRightRadius),
      };
    };
    return {
      stops: [g("--color-cta-from"), g("--color-cta-mid"), g("--color-cta-to")],
      /* Off the wordmark itself, not off the token: what matters is the
         face the browser RESOLVED for it, which is also the only way to see
         that the shipped face loaded rather than silently falling back to
         the mono stack it names second. */
      brand: (() => {
        const el = document.querySelector(".brand");
        return el ? getComputedStyle(el).fontFamily : "missing";
      })(),
      faceLoaded: document.fonts.check('700 24px "Bodoni Moda"'),
      wash: g("--bg-image"),
      cut: shape(".btn"),
      iconCut: shape(".icon-button"),
      /* The two controls on this screen that are not buttons and take the
         shape anyway: the map's search box, and the closed dropdown at the
         foot of the panel. The `field` utility itself is checked at the
         gate, which is the only place one is on screen before the map
         exists. */
      field: shape(".place-search-field"),
      trigger: shape(".dropdown-button"),
    };
  });
/* Square is a bevel of nothing, and nothing clipping. Chamfered is a real
   bevel, and still nothing clipping: a clipped button loses its border along
   the diagonal and its focus ring altogether, which is the whole reason the
   shape stopped being a polygon. */
const square = (shape) =>
  shape !== null && shape.clip === "none" && shape.radius === 0;
const chamfered = (shape) =>
  shape !== null && shape.clip === "none" && shape.corner === "bevel"
  && shape.radius > 0;

for (const plain of ["light", "dark", "night"]) {
  await pickTheme(plain);
  const { stops, brand, wash, cut, iconCut, field, trigger } = await levers();
  check(
    `${plain}: the primary action is one colour, not a gradient`,
    new Set(stops).size === 1 && stops[0] !== "",
  );
  check(
    `${plain}: the wordmark wears no second typeface (${brand})`,
    !/Bodoni/.test(brand) && /mono|Menlo|Consolas/i.test(brand),
  );
  check(`${plain}: and the ground carries no wash`, wash === "none");
  check(`${plain}: the buttons keep their corners`, square(cut));
  check(`${plain}: and so do the icon buttons`, square(iconCut));
  check(
    `${plain}: and the search box and the dropdown`,
    square(field) && square(trigger),
  );
}

/* And the edgerunner pair actually moves them, so the check above says
   something about the plain themes rather than about all of them. */
await pickTheme("edge-dark");
const edge = await levers();
check(
  "edgerunner dark runs a real three-stop gradient",
  new Set(edge.stops).size === 3,
);
check(
  `and draws its wordmark in the shipped face (${edge.brand})`,
  /Bodoni/.test(edge.brand),
);
/* And the face is really there. A @font-face whose file 404s resolves to the
   fallback with nothing said, and the check above would pass on the name
   alone -- the browser reports what the cascade asked for, not what it got. */
check("which is loaded, not merely named", edge.faceLoaded === true);
check("and a wash on the ground", edge.wash !== "none");
check(
  `and cuts the corner off its buttons (${edge.cut?.radius}px)`,
  chamfered(edge.cut) && chamfered(edge.iconCut),
);
/* The same corner off the things that are not buttons. */
check(
  `and off the search box and the dropdown too (${edge.field?.radius}px)`,
  chamfered(edge.field) && chamfered(edge.trigger),
);

/* The other half of the pair. Edgerunner light INHERITS the shape rather than
   setting it, which is exactly the arrangement that breaks quietly when a
   palette starts overriding one of the four tokens and not the rest. */
await pickTheme("edge-light");
const edgeLight = await levers();
check(
  `and so does edgerunner light (${edgeLight.cut?.radius}px)`,
  chamfered(edgeLight.cut) && chamfered(edgeLight.iconCut)
    && chamfered(edgeLight.field) && chamfered(edgeLight.trigger),
);

/* "Match my device" is the one entry that is not a palette. It sets an
   attribute like any other choice, and resolves to the PLAIN pair, because an
   operating system says light or dark and never says edgerunner. This browser
   reports a light preference, so it must land on plain light exactly. */
await pickTheme("system");
check("matching the device says so on the root", (await chosen()) === "system");
check(
  "and on a light device that is plain light, not a edgerunner one",
  (await paletteId()) === painted.light,
);

/* MapLibre's own controls -- zoom, compass, geolocate. They ship a light-only
   stylesheet with #333 baked into the glyph, which no token can reach, so
   they were inverted: grey whatever the palette said, and white buttons on a
   red map in low light. They are masks now, and the colour comes off the
   button, so the question is answerable rather than approximate -- the paint
   must BE the palette's ink, not merely close to it.

   Read from the zoom-in control, the one MapLibre always draws. The probe is
   how a custom property becomes the same string the computed style reports:
   --color-ink is a hex literal and backgroundColor is an rgb() triple, and
   comparing those two as text compares nothing. */
const ctrlPaint = async (theme) => {
  await pickTheme(theme);
  return page.evaluate(() => {
    const icon = document.querySelector(
      ".maplibregl-ctrl-zoom-in .maplibregl-ctrl-icon",
    );
    if (icon === null) return null;
    const style = getComputedStyle(icon);
    const probe = document.createElement("div");
    probe.style.color = getComputedStyle(document.documentElement)
      .getPropertyValue("--color-ink").trim();
    document.body.append(probe);
    const ink = getComputedStyle(probe).color;
    probe.remove();
    return {
      paint: style.backgroundColor,
      image: style.backgroundImage,
      filter: style.filter,
      masked: style.maskImage !== "none",
      ink,
    };
  });
};

const nightCtrl = await ctrlPaint("night");
check(
  "the map's own controls are painted from a mask, not inverted",
  nightCtrl?.masked === true && nightCtrl?.image === "none"
    && nightCtrl?.filter === "none",
);
check(
  `in the palette's own ink (${nightCtrl?.paint})`,
  nightCtrl?.paint !== undefined && nightCtrl.paint === nightCtrl.ink,
);
/* The complaint that started this: in a palette with no neutral in it, a
   neutral control is the one thing on screen still wearing no theme. */
const nightRGB = nightCtrl?.paint.match(/\d+/g)?.map(Number) ?? [];
check(
  "which in low light is warm, not the grey an inversion lands on",
  nightRGB.length >= 3 && nightRGB[0] > nightRGB[2],
);
const edgeCtrl = await ctrlPaint("edge-dark");
check(
  `and it moves with the palette (${edgeCtrl?.paint})`,
  edgeCtrl?.paint !== undefined && edgeCtrl.paint === edgeCtrl.ink
    && edgeCtrl.paint !== nightCtrl?.paint,
);

/* The application's OWN icons are the other way round: the lattice set is
   worn by the two palettes that cut their corners, and the plain three keep
   the shared one. A glyph drawn at 45 degrees on a square button is the same
   mismatch as a round one in a chamfered field, just pointing the other way.

   Read off the panel header, which holds four of them in every palette.
   `data-glyph` is on the local set and nothing else, so counting it against
   the number of glyphs present answers "which set" without naming a file. */
const iconSet = async (theme) => {
  await pickTheme(theme);
  return page.evaluate(() => ({
    attr: document.documentElement.getAttribute("data-icons"),
    local: document.querySelectorAll(".panel-head [data-glyph]").length,
    all: document.querySelectorAll(".panel-head svg").length,
  }));
};

const cutIcons = await iconSet("edge-dark");
check(
  `the edgerunner palettes draw the app's own icons (${cutIcons.local}/${cutIcons.all})`,
  cutIcons.attr === "cut" && cutIcons.all > 0
    && cutIcons.local === cutIcons.all,
);
for (const plain of ["light", "dark", "night"]) {
  const drawn = await iconSet(plain);
  check(
    `and ${plain} keeps the shared set (${drawn.local}/${drawn.all})`,
    drawn.attr === "plain" && drawn.all === cutIcons.all && drawn.local === 0,
  );
}
/* "Match my device" resolves to a plain palette, so it resolves to the plain
   set -- the attribute is written from the RESOLVED theme, not the chosen
   one. This browser reports a light preference. */
const deviceIcons = await iconSet("system");
check(
  "and matching the device follows what it resolves to, not what was picked",
  deviceIcons.attr === "plain" && deviceIcons.local === 0,
);
await pickTheme("edge-dark");

/* An overview and no region is the state every fresh install starts in, and
   two things have to be true of it at once. */

/* First: street zoom is undownloaded ground, so the note offering to fetch it
   has to be on screen. This fails if the detail source's advertised depth is
   made honest without moving the coverage clamp to the server: the question
   then drags down to the overview's own zoom, where the answer is "present"
   and the offer disappears in the one state where it is the whole point. */
await page.evaluate(() =>
  window.__tessarium_map?.jumpTo({ center: [-0.1, 51.5], zoom: 16 })
);
check(
  "with only an overview, street zoom still offers to download the area",
  await page.waitForSelector(".view-note-blank", { timeout: 20_000 })
    .then(() => true, () => false),
);

/* And it takes the theme's colours, both of them. Over the map it sat on a
   hardcoded white through the dark theme's whole first release -- white pill,
   near-white ink -- and every token audit missed it, because a literal in a
   component class list belongs to no palette.

   What makes that impossible now is that the row has NO ground of its own:
   it is text in the panel, on whatever the panel is painted. So the check is
   that it stays that way -- a row that grows a background is a row that can
   carry a literal again -- and the panel's own ground is judged by lightness
   under both themes, which is where the colour actually comes from.

   Named themes rather than "match my device": what that entry resolves to
   depends on the machine running the suite, and this is about the
   stylesheet. */
const rowGround = () =>
  page.locator(".view-note-blank").first()
    .evaluate((n) => getComputedStyle(n).backgroundColor);
const transparent = (color) =>
  color === "transparent" || /rgba\(\s*0,\s*0,\s*0,\s*0\s*\)/.test(color);
await pickTheme("dark");
check(
  `the note is on the panel's ground, not one of its own (${await rowGround()})`,
  transparent(await rowGround()),
);
check(
  `which goes dark with the theme (lightness ${
    (await surfaceLightness(".panel")).toFixed(2)
  })`,
  (await surfaceLightness(".panel")) < 0.5,
);
await pickTheme("light");
check(
  `and light with the light theme (lightness ${
    (await surfaceLightness(".panel")).toFixed(2)
  })`,
  (await surfaceLightness(".panel")) > 0.5,
);
check(
  `with the row still carrying no ground (${await rowGround()})`,
  transparent(await rowGround()),
);

/* Second: it must cost nothing to look around. The floor draws every tile on
   screen and there is no detail to ask for, so a pan should not fetch a single
   empty tile. It used to fetch a viewport of them per pan for as long as the
   install went without a region -- each one a round trip carrying no data,
   which is the cost that shows over a forwarded port. Counted rather than
   asserted, so the number is in the output. */
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

/* Back to the palette the app opens in. The section above left plain light
   behind, and the toast checks after the download are about what the DEFAULT
   paints -- a toast read under a light palette says nothing about the white
   the library used to inject. */
await pickTheme("edge-dark");

/* Second download: detail for the current view, over the world map. The card
   must no longer offer the world, and afterwards every tile from both
   downloads has to be reachable. */
const openButton = page.locator(".panel-download");
check(
  "the map carries its own download button",
  (await openButton.count()) === 1,
);
await openButton.click();
await page.waitForSelector(".download-card", { timeout: 10_000 });
check(
  "the card still offers no download of the planet",
  (await page.locator(".download-world").count()) === 0,
);
/* The world overview is the ground under every region, and nothing may offer
   to take it away.

   It is in the list, and it has no verbs. Leaving it out entirely was the
   opposite mistake: the panel's answer to "what maps do I have" skipped the
   largest file on disk, so a small download named for the viewport read as the
   world map, and its Remove button as the button that deletes the world.

   Asserted on the DOM rather than on the server's refusal, because the two
   locks are separate and a button that should not be there is the one that
   gets pressed. */
check(
  "the world overview is listed",
  (await page.locator(".ledger-row").count()) === 1,
);
check(
  "under a name that cannot be mistaken for somebody's download",
  ((await page.locator(".ledger-row .ledger-name").textContent()) ?? "")
    .trim() === "World map",
);
check(
  "with its size, and why it is there",
  ((await page.locator(".ledger-row .hint").textContent()) ?? "")
    .includes("the base map every region is drawn on"),
);
check(
  "and not one button on it: no Remove, no Export, no Update",
  (await page.locator(".ledger-row .ledger-remove").count()) === 0
    && (await page.locator(".ledger-row .ledger-export").count()) === 0
    && (await page.locator(".ledger-row .ledger-update").count()) === 0,
);

/* What the import section is FOR rides its heading, in the info icon, rather
   than standing as a paragraph between the heading and the control. Moving a
   sentence into a tooltip hides it, so three things have to hold at once: the
   icon is there, hovering it says the sentence on screen, and the sentence is
   the trigger's accessible name whether or not it is open -- React Aria
   describes a trigger with its tooltip only while the tooltip is showing, and
   a screen reader user who never hovers must still be told. */
const importInfo = page.locator(".download-import .info-tip");
const importHint = "Maps downloaded from another Tessarium instance";
check(
  "the import section explains itself from its heading",
  (await importInfo.count()) === 1,
);
check(
  "and spends no paragraph under it doing the same",
  (await page.locator(".download-import > .hint").count()) === 0,
);
check(
  "the explanation is the icon's name, open or not",
  ((await importInfo.getAttribute("aria-label")) ?? "").includes(importHint),
);
await importInfo.hover();
const importTip = await page
  .waitForSelector('[role="tooltip"]', { timeout: 5_000 })
  .then((el) => el.textContent(), () => "");
check(
  "and hovering it puts the explanation on screen",
  (importTip ?? "").includes(importHint),
);
/* Off the icon again: an open tooltip is a positioned overlay, and the checks
   below read the card underneath it. */
await page.mouse.move(0, 0);
await page.waitForFunction(
  () => document.querySelector('[role="tooltip"]') === null,
  null,
  { timeout: 5_000 },
);
check(
  "nor a staleness nudge it could not act on",
  (await page.locator(".ledger-row .ledger-stale").count()) === 0,
);
/* Back to grid zoom before the download, because the checks after it are
   about the overlay surviving the style swap and the grid is only drawn from
   zoom 18. The pans above left the camera at 16. This does not change what is
   downloaded: the card froze its region when it opened, which is the whole
   point of freezing it. */
await page.evaluate(() =>
  window.__tessarium_map?.jumpTo({ center: [-0.09, 51.51], zoom: 19 })
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
  () =>
    [...document.querySelectorAll(".app-toast")].some((t) =>
      (t.textContent ?? "").includes("Maps downloaded")
    ),
  null,
  { timeout: 30_000 },
);
check("the download completes with a toast", true);
check(
  "and the toast carries a close button for keyboard users",
  (await page.locator(".app-toast button").count()) >= 1,
);

/* The toast was drawn by a library that injected its own stylesheet -- white
   background, near-black text, 8px corners, all literals in a file this
   project does not own. So it stayed white in every theme and round in a theme
   that squares every corner: the same bug as MapLibre's controls, and
   invisible to the token audit for the same reason, that the colours belonged
   to no palette. It is this project's own markup now, and these two checks
   would notice it going back.

   Nothing has chosen a theme yet, so this is the default: dark. Read as
   painted and as geometry, because the fix is one stylesheet beating another
   and only the computed value says which won. */
const toastStyle = () =>
  page.locator(".app-toast").first().evaluate((n) => {
    const s = getComputedStyle(n);
    return {
      bg: s.backgroundColor,
      radius: s.borderTopLeftRadius,
      color: s.color,
    };
  });
const toast = await toastStyle();
const toastLight = (() => {
  const n = toast.bg.match(/-?[\d.]+/g)?.map(Number) ?? [];
  return toast.bg.startsWith("oklab") || toast.bg.startsWith("oklch")
    ? n[0]
    : (n[0] + n[1] + n[2]) / (3 * 255);
})();
check(
  `the toast is painted in the theme, not a library's white (${toast.bg})`,
  toastLight < 0.5,
);
check(
  `and squares its corners like everything else (${toast.radius})`,
  toast.radius === "0px",
);
/* And a SUCCESS takes itself away -- one short statement with nothing to
   re-read, unlike an error. Both halves of that pair have to hold: if success
   toasts stayed too, "an error waits to be dismissed" further down would be
   trivially true.

   Waited for rather than slept past, so this returns the moment the toast
   leaves -- two seconds earlier on a green run -- while its budget still ends
   past the timeout the toast was given. */
const successWentAway = await page.waitForFunction(
  () => document.querySelectorAll(".app-toast").length === 0,
  null,
  { timeout: SUCCESS_MS + 2000 },
).then(() => true, () => false);
check("a success toast takes itself away", successWentAway);
await page.waitForFunction(
  () => !document.querySelector(".download-card"),
  null,
  {
    timeout: 10_000,
  },
);
check("the card closes itself", true);

/* The grid overlay must survive the style swap that follows a completed
   download, and this is checked after the FIRST download deliberately. It once
   did not survive: when MapLibre's style diff succeeds it fires style.load
   synchronously inside the setStyle call, so a listener registered after that
   call has already missed it and the overlay was never re-added. Each missed
   listener stayed armed and repaired the NEXT swap, which made the loss
   invisible after two downloads and total after one -- the real-world case. */
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
/* And back to the zoom the pans left, which is what everything below reads:
   the loading bar over real tile traffic, and the card's answer for an area
   already held. */
await page.evaluate(() =>
  window.__tessarium_map?.jumpTo({ center: [-0.09, 51.51], zoom: 16 })
);

/* The loading bar, on real traffic: wait for quiet, delay every tile past the
   tracker's 300 ms threshold, then tell the vector source to reload its tiles
   (same URLs plus a marker param -- the app-visible way to force refetches
   without racing a download's style swap, which flaked). The bar must appear
   while tiles drip in and vanish at idle.

   RECORDED, not sampled. This used to race a `waitForSelector` against a bar
   whose whole life is the delay: measured at 318 ms up, 568 ms down, and a
   wait can miss a window that short. A missed window and a bar that never
   appeared then look the same, which is why this check was called flaky. An
   observer watching for the bar to be ADDED records what happened rather than
   what is on screen when it is asked, and its flag is cleared in the same
   evaluate that triggers the refetch, so an earlier bar cannot answer for this
   one.

   The premise is asserted too: if the interception did not take, no tile was
   ever slow, and "the bar did not appear" answers a question that was never
   posed. */
/* Quiet, and STAYING quiet, BEFORE the tile delay goes on.

   The bar lives about 300 ms up and 250 ms down, measured, and the tracker
   will not raise it again while one is already visible -- so a bar left over
   from the app's own loading closes the window this test needs. Waiting for
   absence to hold past that whole cycle is what empties it.

   Order matters: once every tile is delayed by half a second the map is almost
   never quiet, so this has to happen while traffic is still normal. */
await page.waitForFunction(
  async () => {
    const quiet = () => document.querySelector(".map-loading") === null;
    const still = async (n) => {
      if (!quiet()) return false;
      if (n === 0) return true;
      await new Promise((done) => setTimeout(done, 100));
      return still(n - 1);
    };
    return still(8);
  },
  null,
  { timeout: 60_000 },
);
await page.evaluate(() => {
  /* Added nodes, not a re-query: a callback runs at a microtask checkpoint,
     so a bar that went up and came down inside one would be invisible to an
     "is it there now" test. The label is read as it appears, which is the only
     moment it is certain to exist. */
  window.__barWatch = new MutationObserver((records) => {
    if (window.__barSeen) return;
    const bar = records
      .flatMap((record) => [...record.addedNodes])
      .filter((node) => node.nodeType === Node.ELEMENT_NODE)
      .map((node) =>
        node.matches?.(".map-loading")
          ? node
          : node.querySelector?.(".map-loading")
      )
      .find(Boolean);
    if (bar) {
      window.__barSeen = true;
      window.__barLabel = bar.getAttribute("aria-label");
    }
  });
  window.__barWatch.observe(document.body, { childList: true, subtree: true });
});
const delayedTiles = [];
await page.route("**/tiles/**", async (route) => {
  delayedTiles.push(route.request().url());
  await new Promise((done) => setTimeout(done, 500));
  try {
    await route.continue();
  } catch {
    /* The request died mid-delay: MapLibre aborts tiles that leave the view,
       and unroute below can beat a sleeping handler to its route. Either way
       there is nothing left to slow down. */
  }
});
/* Reset and refetch in ONE evaluate that first checks no bar is up, retrying
   if one is.

   Waiting for quiet and then triggering in a separate call leaves a gap: the
   map can raise a bar inside it, the reset clears the record of that bar, and
   the tracker will not raise a second one while the first is visible -- so the
   observation window opens onto a bar that can no longer be added. Doing the
   check, the reset and the trigger in one synchronous block removes the gap.
   The retry covers the quiet wait above ending just as a fetch began.

   Marked once, not once per attempt, so a retry cannot stack query parameters
   and change what is being asked for. */
const started = await until(() =>
  page.evaluate(() => {
    if (document.querySelector(".map-loading")) return false;
    window.__barSeen = false;
    window.__barLabel = null;
    const src = window.__tessarium_map.getSource("protomaps");
    src.setTiles(
      src.tiles.map((u) => u.includes("e2e_bar=1") ? u : `${u}&e2e_bar=1`),
    );
    return true;
  }), { tries: 6, delayMs: 600 });
check("the refetch was triggered against a quiet map", started);
const barSeen = await page
  .waitForFunction(() => window.__barSeen === true, null, { timeout: 30_000 })
  .then(() => true, () => false);
check(
  `the refetch actually went through the delay (${delayedTiles.length} tiles)`,
  delayedTiles.length > 0,
);
check("slow tiles raise the loading bar", barSeen);
/* Read off the bar as it appeared, not off the DOM afterwards. Asked
   afterwards the bar is almost always gone -- it lives about 250 ms -- and the
   old form said "labelled OR absent", which absent satisfies. A check that
   passes because its subject is missing is not coverage. */
check(
  "the bar names itself for the screen reader",
  ((await page.evaluate(() => window.__barLabel)) ?? "").length > 0,
);
await page.unroute("**/tiles/**");
/* Caught rather than thrown, so a bar that never comes down is reported as one
   failure instead of aborting the run and taking every later check with it.
   That is how it presented the first time: a timeout, no tally, and nothing
   saying which assertion had been reached. */
const settled = await page
  .waitForFunction(() => !document.querySelector(".map-loading"), null, {
    timeout: 60_000,
  })
  .then(() => true, () => false);
check("the bar hides once the map settles", settled);
await page.evaluate(() => window.__barWatch?.disconnect());

/* Beside, not merged. The world went to world.pmtiles and the region to a file
   of its own, and neither spans zoom 0 to 15 alone -- the union is a fact
   about the directory, which is what the map is told.

   Bytes 100-101 of a PMTiles header are its min and max zoom, so the region's
   own file is asked directly. It must reach 15, because a file carried to
   another machine has to hold what it claims on its own. */
const ledgerFiles = await (await postJson("basemap-ledger")).json();
/* The first DOWNLOAD, not the first row: the overview is listed above them and
   has no file to ask about. */
const regionFile = (ledgerFiles.entries ?? []).find((e) => !e.overview)?.file
  ?? "";
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
   this" rather than re-quote the price, and the download stays disabled. */
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
/* And it offers nothing to press. A "Keep track of this map" button used to be
   here, but the server path behind it was removed: a covered area writes no
   tiles, so the job it started always failed. A button that cannot succeed is
   worse than no button, so the held state is the hint alone. */
check(
  "and offers no action, because there is nothing left to download",
  (await page.locator(".download-view .hint.download-held").count()) === 1
    && (await page.locator(".download-view button").count()) === 0,
);

/* Third download: places picked by name from the tree, several at once, in ONE
   download. The fixture's tiles sit inside the United Kingdom's box, so
   picking the UK estimates real bytes; adding the city of London on top must
   NOT change the price, because the server dedups overlapping picks by tile
   id. The country name comes from Intl.DisplayNames, so this also pins the
   catalogue's ISO codes to something the browser recognises. */
await page.locator("#region-filter").fill("United Kingdom");
const ukEntry = page
  .locator(".region-tree .region-disclosure")
  .filter({ hasText: "United Kingdom" });
/* Pressed rather than checked: React Aria's checkbox keeps a real input and
   hides it, so `check()` refuses it as invisible. The label IS the control --
   clicking it is what a person does. */
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

   Layout is not usually worth an end-to-end check, but this broke silently and
   stayed broken: `.download-card label` set `display: block` at two-class
   specificity and outranked `.region-check`'s own `flex`, so every checkbox in
   the picker stacked over its text and nothing failed. Only geometry catches
   that -- a class-name assertion passes while the rule beating it sits
   somewhere else. */
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

/* And what a country discloses is indented past the country itself.

   Same reason as above, and the same blind spot: the states of the United
   States sat flush with the country that contains them, which reads as a flat
   list of peers -- Alabama beside the United States rather than inside it.
   Nothing failed; the tree was simply telling the user something untrue.
   Geometry again, because the indent is a stylesheet's to lose. */
const indented = await ukEntry.evaluate((entry) => {
  const country = entry.querySelector(".region-summary");
  const rows = [...entry.querySelectorAll(".region-check")];
  if (!country || rows.length === 0) return null;
  const parent = country.getBoundingClientRect().left;
  return {
    rows: rows.length,
    /* The narrowest indent of any row, so one stray flush row fails this. */
    least: Math.min(...rows.map((r) => r.getBoundingClientRect().left))
      - parent,
  };
});
check(
  `every row under a country is indented past it `
    + `(${indented?.rows} rows, narrowest ${
      Math.round(indented?.least ?? 0)
    }px)`,
  indented !== null && indented.least > 8,
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

/* A federation exposes its states and cities as checkboxes: the United States
   entry must offer more than forty states, plus named cities. */
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
   sharing one border polygon. Not Russia: its clipped land now affords full
   depth, and honestly planning it takes minutes.

   Fiji's only fixture tile is the world-spanning z0. It used to answer
   "covered", because the estimate diffed against the one archive everything
   merged into, and the world download had already put that tile there. It
   quotes a price now: a region is diffed against ITS OWN file, so it fetches
   its own shallow tiles rather than borrowing the overview's. A file carried
   to a machine with no overview has to draw on its own.

   Either way, what is proved is that the two-box polygon request survived
   validation, planning and the merge arithmetic -- so the assertion is that a
   real answer arrived, not which one. */
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
   leave the machine. Driven through the real search box, because the claim is
   that a person can type a place and land on it. */
const searched = await (await postJson("basemap-search", { q: "fixtu" }))
  .json();
check(
  "the index built from the download finds a place in it",
  searched.results?.[0]?.name === "Fixtureville"
    && searched.results[0].layer === "places",
);
/* The coordinates have to be real, not merely present: a swapped axis or a
   dropped projection still returns a row, and the fixture's tiles are the same
   everywhere, so only a bounds check catches it. */
check(
  "and places it somewhere on Earth",
  Math.abs(searched.results[0].lon) <= 180
    && Math.abs(searched.results[0].lat) <= 85.06,
);
/* The server enforces the limit, and stops scanning once it is reached. */
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

/* A place named the way people name places. "Fixtureville, ZZ" appears inside
   no name in any archive, and matching the query as one run of characters
   found nothing -- so being more specific made the search worse.

   The fixture holds one distinct name, so these prove the query SHAPE is
   accepted and say nothing about ranking. The ordering rules are pinned in the
   server suite, where the corpus is written by the test. */
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
/* The row must say where it goes, not just that it exists: the kind always,
   and how far away whenever the map is not already there. The containment
   context depends on where the fixture pretends to be, so only the parts true
   everywhere are pinned here; catalogue containment is unit-tested against
   real borders. */
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
/* Waited for rather than slept through: a flight takes as long as the distance
   says, so a fixed pause is a race either way. */
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
   cosmetic: a place name is looked up on the server, an address must never be.
   This watches the wire, because the claim is about what leaves the browser
   rather than about what is displayed -- nothing on screen would look wrong if
   the request went out anyway.

   The failure was live until this landed: typing an address searched the place
   index for it, which prefix-matched the first word and flew the map to a
   village in France. */
const searchRequests = [];
const watchSearch = (request) => {
  if (request.url().includes("/api/basemap-search")) {
    searchRequests.push(request.postData() ?? "");
  }
};
page.on("request", watchSearch);

const addressForSearch = sample.address;
/* The same address written with a different separator. address_of_string
   accepts every one of `, / - _ .` and space, and an earlier classifier looked
   only at dots -- so the dashed spelling sent three words and three of four
   digits to the index while it was being typed. One spelling would not have
   caught that. */
const addressDashed = sample.address.replace(/[.]/g, "-");

/* DEBOUNCE_MS in PlaceSearch is 250, so the delay here must be LONGER than
   that. Otherwise no partial value reaches the classifier and this only checks
   that the finished address is withheld. At 30 ms every keystroke reset the
   timer and exactly one value -- the complete address -- was ever classified,
   which passed against a version with no partial handling at all. */
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

/* The guarantee is NOT "nothing is sent". A lone "vacuum" is both a BIP-39
   word and an English one, and withholding every single word would take
   "orange", "river" and "city hall" off the place index for no privacy gain.
   The guarantee is that nothing recognisable as an ADDRESS is sent: never two
   of the three words, never the number, never the whole thing.

   Stated this precisely because the first version said "sends nothing" and
   passed only because it typed faster than the debounce. */
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
   on the square that address names, which is the vector's own point. */
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
/* And the box is empty afterwards. The search sits OVER the map, so an address
   left in it would be in every screenshot of the map -- the exposure the
   panel's conceal toggle exists to prevent, by the back door. A place name is
   kept deliberately; an address is not. */
check(
  "and the address does not stay sitting in the box over the map",
  (await page.locator("#place-search-input").inputValue()) === "",
);

/* A place name must still go out, or the feature is gone rather than fixed. A
   query string used nowhere else above: the place cache holds answers for five
   minutes, so reusing "fixtu" would be served from memory and prove nothing
   about the wire. */
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

/* A query naming its context asks for a WIDER slice, which is what makes
   answering the context possible at all.

   The server ranks by population and knows nothing of states -- no tile label
   knows its country -- so on the real United States index the Jasper in
   Georgia comes back sixth of the Jaspers, below the fold of a list of eight.
   The dropdown re-ranks using border data it already ships, but it can only
   re-rank rows it was given. Ask for eight and the right answer was never in
   the response. */
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

   The claim is not that something grey appears -- it is that the grey lands
   exactly where the tile endpoint has nothing. So the mask is checked against
   the tiles themselves, cell by cell, rather than against the code that drew
   it. Those two agreeing is the whole feature, and a mask that greys out
   ground the map is drawing would be worse than no mask. */
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

const cells = Array.from({ length: cover.h * cover.w }, (_, i) => ({
  row: Math.floor(i / cover.w),
  col: i % cover.w,
}));
/* Sequential on purpose, one request at a time. The fold carries the
   disagreements, so a failure names its cells instead of saying only that one
   exists. */
const disagreed = await cells.reduce(async (acc, { row, col }) => {
  const prior = await acc;
  const res = await fetch(
    `${base}/tiles/${cover.zoom}/${cover.x + col}/${cover.y + row}.mvt`,
  );
  await res.arrayBuffer();
  const served = res.status === 200;
  return served === (cover.present[row * cover.w + col] === "1")
    ? prior
    : [...prior, `${row},${col}`];
}, Promise.resolve([]));
check(
  `the mask agrees with the tile endpoint, cell for cell (off: ${
    disagreed.join(" ") || "none"
  })`,
  disagreed.length === 0,
);

/* The other side of the world: nothing at street level, but the world overview
   underneath is still real, which is why the note offers zooming out rather
   than claiming there is nothing at all. */
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
   what the app says once it has settled, and an animation only changes when
   that is. */
await page.evaluate(() =>
  window.__tessarium_map?.jumpTo({ center: [139.7, 35.68], zoom: 12 })
);
check(
  "panning off the downloaded region says so",
  await page.waitForSelector(".view-note-blank", { timeout: 15_000 })
    .then(() => true, () => false),
);
/* And says the one thing true wherever it appears. What the floor draws
   underneath ranges from a country map to a single stretched polygon depending
   on how far past its depth the camera has gone -- so a note promising a wider
   map cannot keep the promise, and one denying any map contradicts what is on
   screen. Read from the catalogue rather than copied here, so rewording it
   back into a claim fails this. */
check(
  "and claims only that the detail is missing",
  (await page.locator(".view-note-blank").innerText())
    === m("map_coverage_gap"),
);
/* The wash is the other half of that claim. It is 42% opaque, sized for ground
   with nothing drawn on it, so painting it over the floor would darken the map
   the floor exists to keep. Withheld, not faded: the rectangles are never
   handed to the source, which is what makes this answerable by asking what is
   on screen. */
check(
  "and does not wash out the map underneath it",
  await page.evaluate(() =>
    window.__tessarium_map.queryRenderedFeatures({
      layers: ["coverage-blank"],
    }).length
  ) === 0,
);

/* The other half of the same claim, and the state the wash still exists for:
   no floor at all. Stubbed rather than staged. Which archives make a floor is
   settled in the server's own suite, against archives built to have and to
   lack one; what is left here is that the app reacts to the answer. The
   archive that produces it -- one holding not even the single zoom-0 tile of
   the planet -- is not one a download can leave behind. Without this check the
   wash could be deleted outright and everything above would still pass. */
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
await page.waitForSelector(".view-note-blank", { timeout: 15_000 });
/* The note is the only way out of a blank screen, and it points rather than
   acts: the button it names is the panel's own, one row above it. So the
   check is that pressing THAT reaches the downloader from this state, and
   that the note stands down once it has -- a row telling someone to press a
   button they have already pressed is worse than no row. */
await page.locator(".panel-download").click();
check(
  "the button the note names opens the download card",
  await page.waitForSelector(".download-card", { timeout: 10_000 })
    .then(() => true, () => false),
);
check(
  "and the note stands down while the card is open",
  await page.waitForFunction(
    () => !document.querySelector(".view-note-blank"),
    null,
    { timeout: 10_000 },
  ).then(() => true, () => false),
);
await page.locator(".panel-download").click();
await page.waitForFunction(
  () => !document.querySelector(".download-card"),
  null,
  {
    timeout: 10_000,
  },
);

/* ------------------------------ the small wait ----------------------------

   The estimate is real planning work on the server and takes as long as the
   area is large, so the card sits on one sentence -- "checking how much there
   is to fetch" -- with nothing moving. The application's other loading
   indicator is the bar across the top of the map, which is about the whole
   view and says nothing about a section of a card waiting on its own.

   Four squares filling in turn, in the shape the application already draws:
   the grid's empty squares, the reticle, the cut corners. Held open here by
   delaying the estimate, because the real wait is too short to catch and too
   long to leave unmarked.

   Read as geometry and computed style rather than by class alone: a mark
   whose rule did not reach it is four invisible spans, which looks exactly
   like the bug this replaces. */
await page.route("**/api/basemap-estimate", async (route) => {
  await new Promise((done) => setTimeout(done, 3000));
  try {
    await route.continue();
  } catch {
    /* Same as the tile delay above: unroute can beat a sleeping handler to
       its route, and continuing a route already handled throws from a
       promise nothing is awaiting -- which takes the whole suite down rather
       than failing a check. */
  }
});
/* Somewhere nothing else in this file prices, and closer in than the jumps
   above. The estimate is cached against the region asked for and kept fresh
   for five minutes, so reopening the card where it was last open answers out
   of the cache with nothing pending -- no wait, and rightly no mark. The
   check needs a real one. */
await page.evaluate(() =>
  window.__tessarium_map?.jumpTo({ center: [139.78, 35.7], zoom: 14 })
);
await page.waitForTimeout(600);
await page.locator(".panel-download").click();
await page.waitForSelector(".download-card", { timeout: 10_000 });
const waiting = await page
  .waitForSelector(".estimating .loading-tiles", { timeout: 10_000 })
  .then(() => true, () => false);
check("a section waiting on its own says so with a mark of its own", waiting);
const mark = await page.evaluate(() => {
  const el = document.querySelector(".estimating .loading-tiles");
  if (!el) return null;
  const squares = [...el.children];
  const box = el.getBoundingClientRect();
  return {
    squares: squares.length,
    hidden: el.getAttribute("aria-hidden"),
    announced: document.querySelector(".estimating")?.getAttribute("role"),
    width: Math.round(box.width),
    height: Math.round(box.height),
    animated: squares.map((sq) => getComputedStyle(sq).animationName),
    delays: squares.map((sq) => getComputedStyle(sq).animationDelay),
  };
});
check(`it is four squares (${mark?.squares})`, mark?.squares === 4);
check(
  `laid out square, at the size of the text beside it (${mark?.width}x${mark?.height})`,
  mark !== null && mark.width === mark.height && mark.width > 8
    && mark.width < 24,
);
check(
  "each of them actually animating",
  mark !== null && mark.animated.every((name) => name === "loading-tile"),
);
/* Clockwise, which is what makes it read as filling rather than flashing: a
   2x2 laid out 1 2 / 3 4 turns 1, 2, 4, 3. */
check(
  `in turn rather than together (${mark?.delays.join(", ")})`,
  mark !== null && new Set(mark.delays).size === 4
    && mark.delays[0] === "0s" && mark.delays[1] === "0.15s"
    && mark.delays[3] === "0.3s" && mark.delays[2] === "0.45s",
);
/* The sentence carries the meaning and its region announces itself, so the
   mark must not speak as well -- and the region has to announce at all,
   which it did not before this. */
check(
  `and saying nothing of its own (${mark?.hidden})`,
  mark?.hidden === "true",
);
check(
  `beside a sentence that is announced (${mark?.announced})`,
  mark?.announced === "status",
);
check(
  "and the mark goes when the answer lands",
  await page.waitForFunction(
    () => !document.querySelector(".estimating"),
    null,
    { timeout: 20_000 },
  ).then(() => true, () => false),
);
await page.unroute("**/api/basemap-estimate");

await page.locator(".panel-download").click();
await page.waitForFunction(
  () => !document.querySelector(".download-card"),
  null,
  { timeout: 10_000 },
);

/* An answer that arrives late must not paint over a newer one.

   React Query hands back a cached view in a microtask while a fresh request is
   still in flight, so returning to a place you left seconds ago resolves
   BEFORE the place you passed through. The older answer then landed last and
   won, clearing the wash and the note while the camera sat on blank ground --
   the app saying nothing at all. Delayed here on purpose, but the ordering
   needs no help in the field. */
await page.route("**/api/basemap-coverage", async (route) => {
  await new Promise((done) => setTimeout(done, 2000));
  await route.continue();
});
await page.evaluate(() =>
  window.__tessarium_map?.jumpTo({ center: [139.7, 35.68], zoom: 12 })
);
await page.waitForSelector(".view-note-blank", { timeout: 20_000 });
/* Out to covered ground, whose answer is now 2 s away. The pause is what makes
   this a race: two jumps back to back settle as one move, so the request being
   outrun would never be sent. */
await page.evaluate(() =>
  window.__tessarium_map?.jumpTo({ center: [-0.12, 51.5], zoom: 12 })
);
await new Promise((done) => setTimeout(done, 700));
/* And straight back, where the answer is cached and returns at once, so the
   older question is still in flight behind it. */
await page.evaluate(() =>
  window.__tessarium_map?.jumpTo({ center: [139.7, 35.68], zoom: 12 })
);
await new Promise((done) => setTimeout(done, 4000));
check(
  "an answer for a view already left cannot wipe the current one",
  await page.locator(".view-note-blank").count() === 1,
);
await page.unroute("**/api/basemap-coverage");

/* The grid overlay had the same hazard and no guard.

   Its answers come from the worker rather than the network, so the delay goes
   into the worker script. That script is fetched over HTTP and created once
   per page, so the delay has to be in place before the page loads -- hence a
   page of its own, and a longitude range nothing else in this suite visits, so
   only this check pays for it. */
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

/* The westmost longitude the overlay holds. Read from the source's own data
   rather than from the screen: cells painted for a viewport already left are
   off-screen, which is the whole complaint. */
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

/* London first, so its answer is in the query cache and returns in a microtask
   on the way home. */
await gridPage.evaluate(() =>
  window.__tessarium_map?.jumpTo({ center: [-0.12, 51.5], zoom: 19 })
);
await gridSettled();
/* Out to a longitude the worker holds back 2.5 s. The pause is what makes it a
   race: two jumps back to back settle as one move, and the request being
   outrun would never be sent. */
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

/* The note goes away on its own when tiles land or a fly-to settles. That
   used to be a hazard: the note carried the download button, and a focused
   button vanishing dropped the page to <body>, where the keyboard does
   nothing. It carries no control at all now, so there is nothing to drop --
   which is why the keyboard is checked to be where it was left rather than
   handed anywhere. */
await page.locator(".panel-download").focus();
await page.evaluate(() =>
  window.__tessarium_map?.jumpTo({ center: [-0.12, 51.5], zoom: 12 })
);
check(
  "returning to downloaded ground takes the note away again",
  await page.waitForFunction(
    () => !document.querySelector(".view-note-blank"),
    undefined,
    { timeout: 15_000 },
  ).then(() => true, () => false),
);
check(
  "without disturbing the keyboard, which was never on the note",
  await page.evaluate(() =>
    document.activeElement?.classList.contains("panel-download") ?? false
  ),
);

/* ------------------------- the download ledger ----------------------------

   Every REGION download above was recorded inside the detail archive itself
   -- name, date, size -- and the list, the reminder setting and Remove are all
   driven through the real card. The world overview is not among them: it went
   to its own file and wrote no entry, which is what makes it un-removable.

   A patch inside an already-downloaded region used to be ADOPTED: the tiles
   were in the one shared archive, nothing was fetched, and an entry landed
   claiming them with "age unknown". There is no shared archive to adopt out of
   any more. The patch is its own region with its own file, so it is its own
   download. That is the trade this layout makes, and the reason a file can be
   carried away on its own. */
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
const downloads1 = (ledger1.entries ?? []).filter((e) => !e.overview);
/* The name a download of the current view gets. Nothing was picked from the
   list, so it is named after where its middle is -- the difference between a
   row that says which download it is and one that says only that a download
   happened. The generic phrase this replaced is what got the row mistaken for
   the map underneath everything. */
check(
  `a download of the view is named after where it is (${
    downloads1.map((e) => e.name).join(", ")
  })`,
  downloads1.some((e) => e.name === "London"),
);
check(
  "the archive records every region download by name",
  downloads1.length === 3
    && ["London", "United Kingdom and London", "Overlapping patch"]
      .every((n) => downloads1.some((e) => e.name === n)),
);
/* The overview is in the list and is not one of them. It is flagged, and the
   flag is what every caller sorts by -- never the name, which on an install
   from before the split is whatever the picker happened to say. */
check(
  "and the world overview is beside them rather than among them",
  (ledger1.entries ?? []).filter((e) => e.overview).length === 1,
);
const patchEntry = downloads1.find((e) => e.name === "Overlapping patch");
check(
  "it gets a file of its own, not a share of somebody else's",
  (patchEntry?.file ?? "") !== ""
    && downloads1.every((e) => e.file !== "")
    && new Set(downloads1.map((e) => e.file)).size === 3,
);
check(
  "every download records when and how much",
  downloads1.filter((e) => e.completed > 0 && e.bytes > 0).length === 3,
);

await openButton.click();
await page.waitForSelector(".download-ledger", { timeout: 10_000 });
/* The list refetches on mount. Wait for the new row rather than racing the
   request. */
const listedRows = await page
  .waitForFunction(
    () => document.querySelectorAll(".ledger-row").length === 4,
    null,
    { timeout: 30_000 },
  )
  .then(() => true, () => false);
check("the card lists the downloaded maps, and the map under them", listedRows);
/* Three rows can be removed and one cannot, which is why the fourth is
   there. */
check(
  "Remove is on every download and on nothing else",
  (await page.locator(".ledger-row .ledger-remove").count()) === 3,
);

/* A row's name is the same `panel-label` the region picker's own label wears
   -- one role, two places. Read here rather than up with the others because
   this is the first point in the run where a downloaded region exists to have
   a name. */
const namedRole = await page.evaluate(() => {
  const face = (selector) => {
    const el = document.querySelector(selector);
    if (el === null) return null;
    const style = getComputedStyle(el);
    return {
      family: style.fontFamily,
      transform: style.textTransform,
      size: style.fontSize,
      weight: style.fontWeight,
      color: style.color,
    };
  };
  return {
    name: face(".ledger-row .ledger-name"),
    picker: face('label[for="region-filter"]'),
  };
});
check(
  `a row's name is the panel's one label for a thing (${namedRole.name?.size} ${namedRole.name?.weight})`,
  sameRole(namedRole.name, namedRole.picker),
);

/* And the quiet buttons light the same way. The accent border on hover lived
   on the two that are an <a> and a <label> rather than a <button>, so "Save a
   copy" and "Choose a file" lit up and "Update" and "Remove" beside them did
   not. It belongs to the button, not to the element it is made of. */
const hoverBorder = async (selector) => {
  await page.locator(selector).hover();
  await page.waitForTimeout(120);
  return page.locator(selector).evaluate((el) =>
    getComputedStyle(el).borderTopColor
  );
};
const litUp = await hoverBorder(".ledger-update >> nth=0");
const litLink = await hoverBorder(".ledger-export >> nth=0");
check(
  `every quiet button lights the same on hover (${litUp})`,
  litUp === litLink,
);
check(
  "in the accent, not in the line it rests at",
  litUp
    === await page.evaluate(() => {
      const probe = document.createElement("span");
      probe.style.color = getComputedStyle(document.documentElement)
        .getPropertyValue("--color-accent").trim();
      document.body.append(probe);
      const value = getComputedStyle(probe).color;
      probe.remove();
      return value;
    }),
);
await page.mouse.move(0, 0);
/* The rule behind that count, checked against the server's own answer rather
   than a number: a row may offer Remove only if its entry has an archive of
   its own to unlink. An empty `file` means the tiles are in map.pmtiles,
   shared with the base map, and removing one of those rewrites or unlinks the
   file the whole app draws from.

   Cross-referenced by name, because that is what a person reads off the row.
   This would have caught "Map view" -- a merged London box offering Remove,
   indistinguishable from the base map in the panel and part of it on disk. */
const rowVerbs = await page.$$eval(".ledger-row", (els) =>
  els.map((el) => ({
    name: el.querySelector(".ledger-name")?.textContent?.trim() ?? "",
    removable: el.querySelector(".ledger-remove") !== null,
    updatable: el.querySelector(".ledger-update") !== null,
  })));
const ownsFile = new Map(
  (ledger1.entries ?? []).map((e) => [
    e.overview ? "World map" : e.name,
    e.file !== "",
  ]),
);
check(
  `no row without a file of its own offers to remove or update it (${
    rowVerbs
      .filter((r) => (r.removable || r.updatable) && !ownsFile.get(r.name))
      .map((r) => r.name).join(", ") || "none do"
  })`,
  rowVerbs.length === 4
    && rowVerbs.every((r) =>
      ownsFile.get(r.name) === true
        ? r.removable && r.updatable
        : !r.removable && !r.updatable
    ),
);
check(
  "nothing just downloaded is flagged for update",
  (await page.locator(".ledger-stale").count()) === 0,
);
/* Every row offers its file directly. Nothing is built and nothing is waited
   on: the download already wrote the file this points at, which the export
   step used to spend minutes producing. */
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
  ((await page.locator(".ledger-row")
    .filter({ has: page.locator(".ledger-name", { hasText: /^London$/ }) })
    .locator(".hint").textContent()) ?? "").includes("updated"),
);

/* The reminder threshold lives on the server, next to the archive it describes
   -- localStorage stays empty, as asserted at the end -- so the choice must
   survive closing the card. */
check(
  "the update reminder defaults to 90 days",
  ((await dropdownIn(".ledger-reminder").textContent()) ?? "").includes("90"),
);
await chooseFrom(".ledger-reminder", "30");
/* The save is a request. Let the server confirm it before the card closes, or
   the reopened card honestly reads the old value. */
check(
  "the reminder write reaches the server",
  await until(async () =>
    (await (await postJson("basemap-settings")).json())
      .update_reminder_days === 30, { tries: 40, delayMs: 250 }),
);
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
   The view download's tiles sit inside the United Kingdom pick, so removing it
   must keep the archive intact -- entries own records, not tiles.

   Matched on the name cell exactly. "London" is a substring of the pick named
   "United Kingdom and London", so hasText on the row would find two. */
const londonRow = {
  has: page.locator(".ledger-name", { hasText: /^London$/ }),
};
const viewRow = page.locator(".ledger-row").filter(londonRow);

/* The name needs a column to sit in. Unwrapped, the row's three buttons took
   the full width and left the name a few pixels, which `overflow-wrap` then
   honoured by breaking it one letter per line -- a tall thin stack of
   characters. Wider than it is tall is the cheap way to say "this is a line of
   text". */
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
/* Three, not two: the overview row is one of them and stays. */
const rowGone = await page
  .waitForFunction(
    () => document.querySelectorAll(".ledger-row").length === 3,
    null,
    { timeout: 30_000 },
  )
  .then(() => true, () => false);
check("the removed entry leaves the list", rowGone);
const removedToast = await page
  .waitForFunction(
    () =>
      [...document.querySelectorAll(".app-toast")].some((t) => {
        const text = t.textContent ?? "";
        /* Either wording is correct: bytes freed, or every tile shared. */
        return text.includes("Maps removed") || text.includes("Map removed");
      }),
    null,
    { timeout: 10_000 },
  )
  .then(() => true, () => false);
check("removal announces what it freed", removedToast);
const ledger2 = await (await postJson("basemap-ledger")).json();
const downloads2 = (ledger2.entries ?? []).filter((e) => !e.overview);
check(
  "the archive agrees the entry is gone",
  downloads2.length === 2
    && !downloads2.some((e) => e.name === "London"),
);
/* A removal leaves the floor untouched, which is why the overview has its own
   file. */
check(
  "removing a region leaves the world overview alone",
  (await fetch(`${base}/basemap/world.pmtiles`, { method: "HEAD" })).status
    === 200,
);
/* The other regions are untouched too, and that is now a fact about files
   rather than about a rewrite: a removal unlinks one archive and cannot reach
   into the others. */
const survivors = await Promise.all(
  downloads2.map(async (e) =>
    (await fetch(`${base}/basemap/${e.file}`, { method: "HEAD" })).status
  ),
);
check(
  "every region that was not removed still has its file",
  survivors.length > 0 && survivors.every((s) => s === 200),
);

/* ---------------- a row that lives in the base archive --------------------

   The shape this rule exists for, and one no download can produce any more:
   an entry whose tiles are inside map.pmtiles, with no file of its own. That
   is what an install from before the one-file-per-region split looks like, and
   what tools/fetch-basemap.sh leaves behind -- the base map the server draws
   from, carrying a record named whatever the picker said at the time. On the
   install that prompted this it said "Map view", and it offered Remove.

   Dropped in from the fixture rather than downloaded, because downloading one
   is what stopped being possible. Taken away again afterwards, so the
   assertions below meet the directory they expect.

   The DOM only. The server's own refusal is driven in
   ocaml/server/test/test_regions.ml, which can assert the reason it gives. A
   refused removal here would still be a job, and every later check on this
   server counts job generations. */
const basemapDir = new URL("../../_build/e2e-basemap/", import.meta.url);
const reopenCard = async () => {
  const close = page.locator(
    ".download-card > .panel-section-head .panel-section-action button",
  );
  if (await close.count()) await close.click();
  await openButton.click();
  await page.waitForSelector(".download-ledger", { timeout: 10_000 });
};
copyFileSync(
  new URL("../../_build/e2e-fixture/map-legacy.pmtiles", import.meta.url),
  new URL("map.pmtiles", basemapDir),
);
await reopenCard();
const legacyRow = page.locator(".ledger-row").filter({ hasText: "Map view" });
await legacyRow.waitFor({ state: "visible", timeout: 20_000 });
check(
  "an entry inside the base archive is listed like anything else",
  (await legacyRow.count()) === 1,
);
check(
  "and offers nothing that would rewrite the file it shares",
  (await legacyRow.locator(".ledger-remove").count()) === 0
    && (await legacyRow.locator(".ledger-update").count()) === 0,
);
/* Carrying it away is not deleting it, and extraction is the only way one of
   these reaches another machine. That stays. */
check(
  "but can still be carried off, which is how a merged region escapes",
  (await legacyRow.locator(".ledger-export").count()) === 1,
);
rmSync(new URL("map.pmtiles", basemapDir), { force: true });
await reopenCard();

/* Update through the card, on the clipped country pick: the one deliberate way
   to refresh held tiles, exercised over a polygon region. The card closes
   itself when the job completes, like any download. */
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
   (--tile-budget 1024,256,8), so a request the production budget would swallow
   whole is forced down the giant path: split into parts, fetched one at a
   time, each merged and renamed atomically. Driven over the API, because the
   interesting claims are the server's. */
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
const finalJob3 = async (generation) =>
  (await until(async () => {
    const status = await (await post3("basemap-status")).json();
    return status.generation === generation
        && !["planning", "fetching", "assets", "removing", "idle"].includes(
          status.job?.state,
        )
      ? status.job
      : false;
  }, { tries: 120, delayMs: 250 })) || null;
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
   found covered and skipped. The download writes nothing and says so. */
await post3("basemap-download", { regions: [world] });
const again3 = await finalJob3(2);
check(
  "a re-download skips every held part and says so",
  again3?.state === "failed" && /already have/.test(again3.reason ?? ""),
);

/* The same ledger, over the API. The scripted download above carried no name,
   so the server coined one from its box. */
const led3 = await (await post3("basemap-ledger")).json();
check(
  "a scripted download is recorded under its box",
  led3.entries?.length === 1
    && led3.entries[0].name === "-179.90, -84.00 - 179.90, 84.00"
    && led3.entries[0].completed > 0,
);
/* The entry records what the network delivered, never archive-copy volume. For
   a multi-part download the quote deliberately double-counts seam tiles the
   later parts skip, so fetched <= quoted; the copy volume re-counts every
   earlier part, so fetched < Done's total. The old bug recorded the latter. */
check(
  "the recorded bytes are network bytes, not copy volume",
  led3.entries?.[0]?.bytes > 0
    && led3.entries[0].bytes <= est3.total_bytes
    && led3.entries[0].bytes < done3.total_bytes,
);
const id3 = led3.entries?.[0]?.id ?? "";
/* Update re-fetches the region tile for tile, and under the tiny budget it
   does so in parts again. */
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
   file it describes, so the two leave together and nothing is left behind
   holding tiles nobody can name. */
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

/* A request past even the split ceiling is clamped to a shallower granted
   depth. The ledger must record the depth that was FETCHED, not the one asked
   for, or Remove and Update would speak of tiles that never existed. */
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

   Opt in, look at a place, and its tiles are cached: server-side gate,
   anonymous tiles, and -- on this server's one-byte compaction threshold --
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
/* The depth actually written travels back with the answer. The client compares
   it against what its map advertises to decide whether deeper tiles arrived,
   so a wrong or missing number is a map that never fills in. */
check("the browse answers with the depth it wrote", browsed.zoom === 15);
/* The one-byte threshold compacts immediately. Wait for the writer to rest. */
check(
  "the cache folds into the main archive past the threshold",
  await until(async () => {
    const st = await (await post3("basemap-status")).json();
    return !["planning", "fetching", "assets", "removing", "compacting"]
      .includes(st.job?.state)
      && (await fetch(`${base3}/basemap/cache.pmtiles`, { method: "HEAD" }))
          .status === 404;
  }, { tries: 120, delayMs: 250 }),
);
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

/* And it never comes back. This is the exact state that used to bring the
   offer up -- an archive on disk, no world overview beside it -- and the rule
   now is that the card says nothing about the planet in it either. A package
   ships the overview; a store without one is a developer's, and no button in
   the app can make it appear.

   Two things asserted, because a missing offer could just be an offer whose
   estimate never answered: nothing is drawn, AND the card never asks what the
   planet would cost. The ask is recognised by its box, so a region estimate
   passing through is not mistaken for one. */
const worldPage = await context.newPage();
const isWorldAsk = (data) => {
  try {
    const body = JSON.parse(data ?? "{}");
    const r = body.regions?.[0];
    return body.regions?.length === 1 && r?.min_lon === -180
      && r?.max_lon === 180 && r?.min_lat === -85;
  } catch {
    /* not JSON, so not ours */
    return false;
  }
};
let worldAsks = 0;
await worldPage.route("**/api/basemap-estimate", async (route) => {
  if (isWorldAsk(route.request().postData())) worldAsks++;
  await route.continue();
});
await worldPage.goto(base3, { waitUntil: "networkidle" });
await worldPage.locator("#phrase").fill(sampleMnemonic);
await worldPage.waitForSelector(".valid", { timeout: 30_000 });
await worldPage.locator("button[type=submit]").click();
await worldPage.waitForSelector(".map-wrap", { timeout: 60_000 });
await worldPage.locator(".panel-download").click();
await worldPage.waitForSelector(".download-card", { timeout: 10_000 });
/* The view offer prices itself on mount; give the card the time an offer
   takes, so "nothing asked" is a settled answer rather than an early one. */
await worldPage.waitForSelector(".download-view .hint", { timeout: 30_000 });
check(
  "with maps on disk and no overview, no world download is offered",
  (await worldPage.locator(".download-world").count()) === 0,
);
check(
  `and the card never asks what the planet would cost (${worldAsks})`,
  worldAsks === 0,
);
check(
  "the view offer is what leads the card",
  await worldPage.evaluate(() => {
    const options = [...document.querySelectorAll(".download-option")];
    return options[0]?.classList.contains("download-view") === true;
  }),
);
await worldPage.close();

/* Let the swapped style fetch and render its tiles. Anything it logs from here
   on fails the final console check. */
await page.waitForTimeout(2500);

/* Going to an address, through the one box that takes both an address and a
   place name. It replaced a dedicated lookup form in the panel. The address is
   classified in the browser, so nothing about it is sent anywhere, and the
   offered row is taken the way a place result is. */
const goToAddress = async (address) => {
  await page.locator("#place-search-input").fill("");
  await page.waitForTimeout(350);
  await page.locator("#place-search-input").fill(address);
  await page.waitForSelector(".place-option", { timeout: 15_000 });
  await page.locator(".place-option").first().click();
  /* At most a 1.2 s flight, and no flight at all for anything off-screen --
     see ui/src/core/camera.ts. Either way this wait is long enough. */
  await page.waitForTimeout(2000);
};

/* The round trip the whole project is for, driven entirely through the UI:
   paste an address, fly to the square it names, click that square, and get the
   same address back. No test hook on the map -- going through the real
   controls is what makes this evidence that a person can do it. */
await goToAddress(sample.address);

const lookupFailed = await page.locator(".app-toast[data-kind=error]")
  .count();
check(`looking up ${sample.address} succeeds`, lookupFailed === 0);

/* flyTo centres on the decoded point, so the centre pixel is inside the square
   that address names. Clicking it must give the same address back. */
const box = await page.locator(".map").boundingBox();
await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
await page.waitForTimeout(1500);

/* The coordinates are what pin the browser's KEY to the vectors, and nothing
   else in the suite does. Looking up an address and clicking the square it
   lands on is a round trip through decode-then-encode, which returns the
   address you started with under ANY key: a wrong key decodes it to a
   different place on Earth and re-encodes that place back to the same words.
   The coordinates are the only output that differs.

   They start hidden, like the address, because they name where someone is. The
   mask must be in the DOM in place of the value, not over it. */
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

/* ---------------------------------------- what a toast has to keep doing

   Two behaviours here are TUNED rather than default, so they are the two a
   change of library would silently undo. Located through this project's own
   `app-toast` class rather than the current library's data attributes, so
   these assertions outlive it.

   The first: an error waits to be dismissed. Sonner's default five seconds is
   shorter than a long message being read aloud, and the message vanished
   mid-sentence. A screenshot cannot show that; it needs a clock.

   Provoked by making the clipboard refuse, which is a real failure -- a
   permissions policy or a non-secure context does exactly this -- and the only
   error path in the app that can be triggered on demand. */
const anyToast = page.locator(".app-toast");
/* The coordinates' own copy control, revealed above. */
const toastCopy = page.locator(".coords-row .icon-button").nth(1);
await page.evaluate(() => {
  globalThis.__realWrite = navigator.clipboard.writeText.bind(
    navigator.clipboard,
  );
  navigator.clipboard.writeText = () => Promise.reject(new Error("refused"));
});
await toastCopy.click();
check(
  "a failed copy is reported as a toast",
  await anyToast.first().waitFor({ state: "visible", timeout: 10_000 })
    .then(() => true, () => false),
);

/* Legible before it is timed: toast text is 13px, and the library's tinted
   palette put it under AA, which is why richColors is off. Computed, because
   the colours live in a stylesheet this project does not own and no token
   audit can reach them. */
const toastContrast = await anyToast.first().evaluate((box) => {
  const n = box.querySelector(".app-toast-message") ?? box;
  const s = getComputedStyle(n);
  const parse = (c) => (c.match(/-?[\d.]+/g) ?? []).map(Number).slice(0, 3);
  const lin = (v) => {
    const x = v / 255;
    return x <= 0.04045 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4;
  };
  const lum = (c) => {
    const [r, g, b] = parse(c).map(lin);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  };
  const bg = getComputedStyle(box).backgroundColor;
  const [hi, lo] = [lum(s.color), lum(bg)].sort((a, b) => b - a);
  return {
    ratio: (hi + 0.05) / (lo + 0.05),
    fg: s.color,
    bg,
  };
});
check(
  `toast text passes AA (${
    toastContrast.ratio.toFixed(2)
  }:1, ${toastContrast.fg} on ${toastContrast.bg})`,
  toastContrast.ratio >= 4.5,
);

/* Past the success duration, and still there. The one wait here that cannot be
   a condition: nothing happens at the end of it, so the only way to know an
   error stayed is to be past the moment a success would have gone. Half a
   second past, not two -- the margin covers the queue's own timer, not a slow
   machine. */
await page.waitForTimeout(SUCCESS_MS + 500);
check(
  "an error toast is still on screen after a success would have gone",
  (await anyToast.count()) >= 1,
);

/* And it can be dismissed, which is what makes waiting acceptable. A toast
   that never leaves and cannot be dismissed traps anyone who cannot reach for
   a pointer. */
const closer = anyToast.first().locator("button").first();
check("it carries a control to dismiss it", (await closer.count()) === 1);
/* By its own text, not by "a toast is gone": the queue shows one at a time, so
   anything waiting behind takes the closed one's place and a bare count would
   read as nothing having happened. */
const dismissing = (await anyToast.first().textContent() ?? "").trim();
await closer.click();
const dismissed = await page.waitForFunction(
  (text) =>
    ![...document.querySelectorAll(".app-toast")]
      .some((t) => (t.textContent ?? "").trim() === text),
  dismissing,
  { timeout: 10_000 },
).then(() => true, () => false);
check(
  `and dismissing it works (left: ${
    (await anyToast.allTextContents()).join(" | ") || "nothing"
  })`,
  dismissed,
);

/* The real clipboard back, so the copy checks below read the browser's own
   rather than the stub left by this one. */
await page.evaluate(() => {
  navigator.clipboard.writeText = globalThis.__realWrite;
});

/* Announced, or it is not a message at all: a toast reports the outcome of
   something a person just did, and someone not looking at that corner of the
   screen has only the live region. */
check(
  "toasts are announced through a live region",
  (await page.locator("[aria-live]").count()) >= 1,
);

/* Zoomed out, a ~3 m square is sub-pixel, so a pin has to mark it or a fresh
   lookup shows an empty map. Checked by rendering, not by layer presence: the
   layer existing and drawing nothing was the failure. */
const pinVisible = await page.evaluate(async () => {
  const map = window.__tessarium_map;
  if (!map) return false;
  /* Bounded, so a hang fails one check rather than wedging the suite. */
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

/* The grid version the panel names has to be the one this build speaks. An
   address carries no version inside it, so a code issued under an older grid
   decodes to a different and entirely plausible square with nothing to say
   why. Naming the grid lets someone label the codes they keep with the grid
   those codes belong to. Held to the VECTORS rather than to a copy of the
   string in this file, so a panel showing a stale version fails here. */
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

/* A decoded point lands somewhere in the ~3 m cell, so this is generous about
   rounding and merciless about a wrong key, which would put the point on
   another continent. */
const nearly = (a, b) => Math.abs(a - b) < 0.0001;

const eye = page.locator(".address-row .icon-button").first();
const copyButton = page.locator(".address-row .icon-button").nth(1);

/* Privacy mode is ON by default, so the address is not on screen yet. "Not on
   screen" has to mean absent from the document rather than styled out of
   sight, because anything reading the page is what it is hidden from. */
check(
  "a newly selected address is concealed by default",
  !(await page.locator(".selected").innerHTML()).includes(sample.address),
);
check(
  "the concealed address is masked rather than blank",
  ((await page.locator(".address").textContent()) ?? "").includes("\u2022"),
);

/* Copying works while concealed: putting an address on the clipboard is not
   putting it on the screen. This is also how the right address is confirmed to
   be there before it is revealed. */
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

/* And it is painted in the colour the palettes reserve for it.
   --color-accent-alt is the address's own colour -- cyan in dark, deep cyan in
   light, soft red in low light -- and it painted NOTHING. The element carried
   `text-accent-alt` as a base class and `text-accent-text` in the revealed
   branch, so the later class won whenever the address was on screen and the
   token was spent only in the state where the text is blurred out anyway.
   Every palette defined it, contrast.mjs audited it as "the address itself",
   and no pixel had ever been that colour.

   Compared against the resolved custom property rather than a literal, so this
   says "the address wears its own token" and survives a repaint. */
const paintedAs = async (prop) =>
  await page.evaluate((p) => {
    const el = document.querySelector(".address");
    if (!el) return ["", ""];
    const want = getComputedStyle(document.documentElement)
      .getPropertyValue(p).trim();
    /* Resolved through a throwaway element, so the token's hex and the
       computed colour are in the same notation before being compared. */
    const probe = document.createElement("span");
    probe.style.color = want;
    document.body.appendChild(probe);
    const normalised = getComputedStyle(probe).color;
    probe.remove();
    return [getComputedStyle(el).color, normalised];
  }, prop);
const [addressInk, altToken] = await paintedAs("--color-accent-alt");
check(
  `the revealed address is painted in its own token (${addressInk} vs ${altToken})`,
  addressInk === altToken && altToken !== "",
);

/* Version skew, asked of the worker rather than the DOM. The served worker,
   the served core and the committed vectors must agree on the grid and
   derivation versions. A server upgraded behind a surviving tab, or a worker
   rebuilt against a different core, breaks exactly this. */
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

/* The map never writes addresses onto the squares. Checked while the address
   IS revealed, so it cannot pass merely because privacy mode is hiding it.
   This catches a DOM label; a label drawn into the WebGL canvas would not
   appear here either way, which is what the "no bulk address operation" check
   above covers. Between them they cover the mechanism and the result. */
check(
  "no address is rendered onto the map",
  !(await page.locator(".map-wrap").innerHTML()).includes(sample.address),
);

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
   centre square. BOTH need something else selected first, or they pass against
   a build that does neither: the panel already says `sample.address` from the
   click above, so asserting that it says so again is true whatever the code
   does. That is how the first version of this passed with the feature removed.

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

/* Typing an address is asking to be told about that square, and it used to
   move the camera and leave the panel on whatever was selected before. The
   camera is already there, so only the selection can make this true. */
await goToAddress(sample.address);
check(
  `arriving at ${sample.address} selects its square without a click`,
  (await page.locator(".address").textContent()) === sample.address,
);

/* Keyboard access. The map is the one control the search box cannot reach, so
   Enter on the focused canvas must select the centre square -- the same square
   flyTo just centred, and the same address as the click. */
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

/* Language. Switching must translate the interface, leave the address alone --
   it is BIP-39 English in every locale -- and, because this app persists
   nothing, write no cookie or storage key to remember the choice.

   The explainer is located by name, not as "the first paragraph in the
   footer": a warning was once added above it and silently became what this
   read. */
const englishFooter = await page.locator(".panel-explainer").textContent();

/* The map has to follow too. Its labels are asked for in the interface
   language, and the style reads that language once, when it is built -- so
   switching afterwards used to translate the controls and leave an English map
   underneath until a download rebuilt the style. Asserted on the style the map
   holds, not on pixels: the fixture's tiles carry no labels to read. */
const labelLang = (lang) =>
  page.evaluate(
    (l) =>
      JSON.stringify(window.__tessarium_map?.getStyle()?.layers ?? [])
        .includes(`name:${l}`),
    lang,
  );
/* Only the absence is checkable. Protomaps keeps `name:en` in every style as
   the fallback for a place with no name in the chosen language, so its
   presence says nothing. The language asked for is the one that appears
   alongside it. */
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
/* A refusal, said in French. This is the point of the code-and-catalogue
   split: the message comes from the worker and the OCaml core, neither of
   which can see a locale, so a French user used to meet English at the exact
   moment something went wrong.

   The address below is well formed and names nothing -- about 35% of word
   combinations do not, which is what makes a typo obvious -- so the refusal
   comes from the wasm core as a code. Matched on French words rather than on
   "not the English", because a blank box is also not the English. */
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

/* And the same refusal in English, so the check above tests the catalogue
   rather than a box that says "combinaisons" whatever happens. */
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

/* Locking, and the key that replaces the one it forgets.

   Locking asks before it forgets a key nothing here can recover, and a second
   phrase really does replace the first -- including the concealment the panel
   resets on every unlock, and the promise the gate makes in as many words:
   the same address under another phrase names somewhere else entirely.

   A DIFFERENT phrase, so this is a key being replaced rather than re-derived;
   the block below is the one that asks for the same phrase twice. */
const otherMnemonic =
  vectors.key_derivation.find((k) => k.name === "ones").mnemonic;
check(
  "the second phrase really is a different one",
  otherMnemonic !== sampleMnemonic,
);

/* The words are held now rather than wiped, so the panel can hand them back.
   Read off the real clipboard and compared to the phrase this session
   actually unlocked with: a control that says it copied and copied nothing --
   or copied the wrong thing -- is the failure worth catching, and the value
   never passes through this thread on its way there.

   In the header, beside the lock that forgets them. It was a labelled row in
   the footer; the sentence that stood beside the glyph is its tooltip now, so
   the words it copies are still named -- checked below. */
check(
  "the phrase copy sits in the header, with the download and the lock",
  (await page.locator(".panel-head .panel-phrase-copy").count()) === 1
    && (await page.locator(".panel-foot .panel-phrase-copy").count()) === 0,
);
/* Nothing left open from an earlier press: `[role="tooltip"]` finds whatever
   is on screen, and a stale one answers this check with the wrong button's
   words. */
await page.mouse.move(0, 0);
await page.waitForFunction(
  () => document.querySelector('[role="tooltip"]') === null,
  null,
  { timeout: 5_000 },
);
await page.locator(".panel-head .panel-phrase-copy").hover();
const phraseTip = await page
  .waitForFunction(
    () => document.querySelector('[role="tooltip"]')?.textContent || null,
    null,
    { timeout: 10_000 },
  )
  .then((handle) => handle.jsonValue(), () => null);
check(
  `and says what it copies, which a bare copy glyph does not (${phraseTip})`,
  /seed phrase/i.test(phraseTip ?? ""),
);
await page.mouse.move(0, 0);
await page.waitForFunction(
  () => document.querySelector('[role="tooltip"]') === null,
  null,
  { timeout: 5_000 },
);
await page.evaluate(() => navigator.clipboard.writeText("not the phrase"));
await page.locator(".panel-head .panel-phrase-copy").click();
await page.waitForFunction(
  (want) => navigator.clipboard.readText().then((t) => t === want),
  sampleMnemonic,
  { timeout: 10_000 },
).then(() => true, () => false);
check(
  "the panel copies the phrase the map was opened with",
  (await page.evaluate(() => navigator.clipboard.readText()))
    === sampleMnemonic,
);
/* And the standing note that said this was impossible is gone with it. */
check(
  "and the note that said the words could never be shown is gone",
  (await page.locator(".panel-foot .phrase-note").count()) === 0,
);

/* Locking asks first: it forgets a key that cannot be recovered from anything
   this app holds. Cancel is the safe answer and the dialog is dismissable, so
   only the destructive button locks. */
await page.locator(".panel-head .lock").click();
await page.waitForSelector(".modal-dialog", { timeout: 10_000 });
check(
  "locking asks before it forgets the key",
  (await page.locator(".modal-dialog .warning").count()) === 1,
);
/* This press is the last moment the words exist anywhere, so the dialog
   offers to take them rather than only saying it is too late to. */
check(
  "and offers the copy in the dialog, where the last chance to take it is",
  (await page.locator(".modal-dialog .lock-phrase-copy").count()) === 1,
);
check(
  "saying so in the warning above it",
  /last chance/i.test(
    (await page.locator(".modal-dialog .warning").textContent()) ?? "",
  ),
);
/* The confirm wears the primary action's gradient rather than a flat accent
   fill: same weight as "Open my map", which is the other press in this
   application that cannot be undone. */
check(
  "and the confirm is painted like the app's other irreversible press",
  (await page.locator(".modal-actions button.danger").evaluate((el) =>
    getComputedStyle(el).backgroundImage
  )).includes("gradient"),
);
await page.locator(".modal-actions button.danger").click();
await page.waitForSelector("#phrase", { timeout: 30_000 });
await page.locator("#phrase").fill(otherMnemonic);
await page.waitForSelector(".valid", { timeout: 30_000 });
await page.locator("button[type=submit]").click();
await page.waitForSelector(".map-wrap", { timeout: 60_000 });

/* A second unlock replaces what the worker holds. Whether it was CLEARED in
   between cannot be asked from here -- a locked tab holding the words looks
   exactly like one that forgot them, which is the point of the boundary and
   why test/secrets.mjs reads that half off the source. */
await page.evaluate(() => navigator.clipboard.writeText("not the phrase"));
await page.locator(".panel-head .panel-phrase-copy").click();
await page.waitForFunction(
  (want) => navigator.clipboard.readText().then((t) => t === want),
  otherMnemonic,
  { timeout: 10_000 },
).then(() => true, () => false);
check(
  "and after locking, the copy hands back the NEW phrase, not the old one",
  (await page.evaluate(() => navigator.clipboard.readText()))
    === otherMnemonic,
);

/* The same words, typed into a map derived from other words. They resolve --
   which combinations name nothing is decided by the permutation, and this one
   is committed, so this is deterministic rather than lucky -- and they resolve
   somewhere else. */
await goToAddress(sample.address);
const otherBox = await page.locator(".map").boundingBox();
await page.mouse.click(
  otherBox.x + otherBox.width / 2,
  otherBox.y + otherBox.height / 2,
);
await page.waitForTimeout(1500);
await page.locator(".address-row .icon-button").first().click();
/* Locking must have hidden the coordinates again: concealment is a per-unlock
   default, and a broken reset would leave the previous session's choice in
   place -- the state a shoulder-surfing user thought they had left behind. */
check(
  "locking hides the coordinates again",
  (await page.locator(".coords dd").allTextContents()).every((t) =>
    t.includes("•")
  ),
);
await page.locator(".coords-row .icon-button").first().click();
const [otherLat, otherLon] = await panelCoords();
check(
  `the same address under another phrase names somewhere else `
    + `(${otherLat}, ${otherLon} vs ${sample.lat_ns / 1e9}, ${
      sample.lon_ns / 1e9
    })`,
  Math.abs(otherLat - sample.lat_ns / 1e9) > 0.001
    || Math.abs(otherLon - sample.lon_ns / 1e9) > 0.001,
);

/* ------- the same phrase, the same address, the same place, every time -----

   Reported from use: save two addresses in a notepad, lock, type the same
   phrase back in, and the two addresses no longer land where they were saved
   from -- inconsistently, so a single lookup looks fine and only repeating it
   shows the drift.

   Nothing above catches that. The suite unlocks once at the top and locks
   exactly once, to a DIFFERENT phrase, so "the same phrase twice" was never
   asked. js/worker-differential.mjs cannot ask it either: it drives the worker
   in one process, and a key that changed across a lock is invisible from
   inside the worker holding it.

   So this locks and re-enters the SAME phrase three times, holding two
   addresses saved at the start to the place they were saved from. Three cycles
   rather than one, because the report was that it was inconsistent rather than
   always wrong.

   Two things are compared, and they fail differently:
     - where the address takes the CAMERA. That is decode under the key, so a
       changed key moves it.
     - what the square at the original point is CALLED. A changed key decodes
       an address to a new place and re-encodes that place back to the same
       words, so the camera check alone can be satisfied by a wrong key. This
       is the half that cannot be.

   The tolerance is 1e-6 degrees, about 11 cm, deliberately far tighter than
   the ~3 m cell: at cell width this would pass while pointing at the wrong
   square. The panel prints 7 fraction digits, so the parsed value is good to
   about 1e-7 and the margin is real.

   If the grid or the constants change on purpose, saved addresses SHOULD stop
   lining up and this must fail: the two points come from the committed
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
   across squares, so this reveals only what is masked. Pressing
   unconditionally would hide them again on the second square. */
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

/* Whether the panel is showing the square for the point just clicked, rather
   than the one selected before it. The panel prints the square's low corner,
   so a point inside its own square sits at or above that corner by less than
   one square's width. The bound is deliberately loose: it only has to tell
   "our point" from "the other saved point", a hemisphere away. The precise
   comparison belongs to the caller. */
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

/* Click one exact point and read back what the panel says about it. Always the
   same physical point across cycles: the panel prints the square's LOW CORNER,
   and re-clicking that corner is a coin toss between four squares.

   Two guards here are about load, and both were seen. Selecting is a click
   plus a round trip into the worker, and under `make test`, alongside
   everything else, the click can land while the map is still settling and
   select nothing -- so it is retried. And waiting for `.address` is not
   enough: the PREVIOUS square's address is still on screen, so the wait
   returns at once and the read races the update. `showsSquareFor` is what
   decides the panel has caught up. */
const inspectAt = async (lat, lon) => {
  const box = await page.locator(".map").boundingBox();
  const attempt = async () => {
    await page.evaluate(([la, lo]) => {
      const map = window.__tessarium_map;
      if (!map) return;
      /* Cancel any flight still running: a jumpTo during one is overtaken by
         it, and the click would land on a different square. */
      map.stop();
      map.jumpTo({ center: [lo, la], zoom: 20 });
    }, [lat, lon]);
    await page.waitForTimeout(600);
    await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
    const showed = await page
      .waitForSelector(".address", { timeout: 10_000 })
      .then(() => true, () => false);
    if (!showed) return null;
    await reveal();
    return until(() => showsSquareFor(lat, lon), { tries: 20, delayMs: 250 });
  };
  const corner = (await until(attempt, { tries: 3, delayMs: 0 })) || null;
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
   read off the map rather than off the panel. */
const flyToAddress = async (address) => {
  await goToAddress(address);
  return await page.evaluate(() => {
    const c = window.__tessarium_map.getCenter();
    return { lat: c.lat, lon: c.lng };
  });
};

/* Two ordinary points, opposite hemispheres on both axes, chosen by COORDINATE
   rather than by address: addresses move whenever the constants do, while the
   coordinates are the generator's inputs and do not. Deliberately not the
   vector list's first two, which are (0, 0) and a pole -- a dropped sign is
   invisible at the origin. */
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

/* Saved the way a user saves them: click the square, write down what the panel
   says, and note where looking that address back up goes. */
const saved = await savedPoints.reduce(async (acc, point) => {
  const prior = await acc;
  const at = { lat: point.lat_ns / 1e9, lon: point.lon_ns / 1e9 };
  const seen = await inspectAt(at.lat, at.lon);
  check(
    `saving ${seen.address} agrees with the committed vector `
      + `(${point.address})`,
    seen.address === point.address,
  );
  return [...prior, { at, ...seen, landed: await flyToAddress(seen.address) }];
}, Promise.resolve([]));

for (const cycle of [1, 2, 3]) {
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
   for, watch it zoom in cleanly, then watch the map you were looking at be
   replaced by grey.

   MapLibre keeps a stretched coarse tile on screen only while the finer tile
   has NO data -- and an empty answer IS data, meaning "this square is
   genuinely blank", so it wins and the coarse map goes. A 404 does not help:
   the vector source swallows a 404 by design and files it as the same empty
   tile. What decides this is the source's maxzoom. While it claims more depth
   than the archive holds, MapLibre keeps asking for tiles that will never
   come; when it tells the truth, MapLibre overzooms the coarse tile instead,
   which is what a user wants to see.

   This needs an archive that CLAIMS depth it does not have everywhere, which
   is what this server holds: London to zoom 15, and a thinner cone of low
   zooms around it. The source advertises maxzoom 15, MapLibre asks for zoom 15
   wherever you go, and just west of the downloaded box there is nothing to
   answer with. The shallow-archive server cannot stand in: there the source
   advertises zoom 6, MapLibre never asks for more, and nothing is ever
   missing.

   Asserted through querySourceFeatures, which reads the tiles the source is
   RENDERING FROM, rather than off the screen: the fixture's tiles are
   deliberately unstyled, so nothing is drawn either way and a screenshot could
   not tell the two outcomes apart. */
const thinLon = -0.30;
const thinLat = 51.50;
const deepThin = tileAt(thinLon, thinLat, 15);
const coarseThin = tileAt(thinLon, thinLat, 8);

/* The premise, stated rather than assumed: this really is a place with a
   coarse map and no detail. Without both halves the checks below pass for the
   wrong reason. */
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
  /* Either source counts: the question is whether the basemap is still drawing
     ground here, not which layer supplied it. Past the downloaded depth the
     answer must come from the floor. */
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
/* And it is still there after zooming past everything that was downloaded.
   That is the whole point: the screen must not go blank under you. */
const deepDrawn = await drawnFrom(16);
check(
  `zooming past what was downloaded keeps it (${deepDrawn} features rendered)`,
  deepDrawn > 0,
);

/* ------------------------ the server going away --------------------------

   The failure this answers: with no server the gate still renders, the phrase
   still validates and the checksum still goes green -- all three run in the
   browser -- so the app looks fine right up until "Open my map", which failed
   with "Could not open the map." That blames the phrase. Nothing said the
   server was missing.

   Not an exotic state, either: it is what `pnpm run dev` is in every time
   without the backend behind it, because the two wasm modules the key is
   derived with are embedded in the server binary rather than served from
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
/* Reloading drops the key, so this lands on the gate -- the screen a person is
   looking at when they cannot get in. */
await page.reload({ waitUntil: "domcontentloaded" });
await page.waitForSelector("#phrase", { timeout: 30_000 });
check(
  "an unreachable server is reported in a banner, at the gate",
  await bannerSays("Cannot reach the server"),
);

/* And pressing the button anyway must not blame the phrase. argon2.wasm is
   refused too, so unlocking genuinely fails -- the case that used to answer
   "Could not open the map" over a phrase whose checksum had gone green one
   second earlier. */
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
      [...document.querySelectorAll(".app-toast")].some((t) =>
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
/* And it goes away by itself: a banner that outlives its cause teaches people
   to ignore banners. */
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

   The card used to render its own progress bar and cancel button while a job
   ran, and MapProgress renders both -- per region, which is the richer report
   -- one section up the same panel. While the card floated over the map those
   were two places; once both were in the panel they were the same download
   said twice, with two ways to cancel it.

   The job is faked rather than started: a real one against the fixture server
   finishes between polls, so there is no running state to look at. What is
   under test is what the panel DRAWS for a running job, which is what the fake
   supplies. Installed before the reload, because the status query stops
   polling once a job is idle and the fetch on mount is the one that has to see
   it.

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
/* Two cancel buttons for one download is the worse half: whichever is pressed,
   the other stays on screen offering to do it again. */
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
   full. Over a forwarded port that was about ten megabytes and twenty seconds,
   on a map the browser already had.

   A browser rather than a protocol test, because the claim is about a browser:
   that it stores these responses, revalidates them, and is told they have not
   changed. A server emitting a correct ETag that no client ever sends back
   would pass a protocol test and fix nothing a user would notice.

   Two visits in one context, so the second meets the first one's cache. Bytes
   off the wire, not status codes: a response the browser never asked for is a
   better outcome than a 304, and counting 304s would score it as a failure. */
const revisitBrowser = await chromium.launch();
const revisitContext = await revisitBrowser.newContext({
  viewport: { width: 1280, height: 900 },
});

const visit = async () => {
  const p = await revisitContext.newPage();
  /* Two whole app sessions run here -- gate, worker, core, map. Unwatched,
     their CSP violations and page errors would be invisible. */
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
               cache -- the best outcome -- comes back NEGATIVE, by the size of
               headers that were never received. Clamped for the totals, and
               kept raw too, because "how many were free" is worth asserting
               rather than inferring. */
            bytes: Math.max(0, size.responseBodySize),
            fromCache: size.responseBodySize < 0,
          });
        })
        .catch(() => {}),
    );
  });
  /* All the way in, both times. A bare page load reaches neither heavy thing:
     the core loads when the worker is first asked a question, and the map does
     not exist until the phrase is accepted. A visit that stopped at the gate
     would report a saving on a fifth of what a visit costs. */
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
  /* Awaited again after the close: `pending` grows, and the first await only
     covers what had landed by then. Closing the page is what guarantees no
     more will arrive. */
  await Promise.all(pending);
  return rows;
};

const firstVisit = await visit();
const secondVisit = await visit();
/* GETs only, because those are what a cache can answer: the app's POSTs to
   /api are uncacheable by construction. They are held to a size of their own
   below rather than dropped, so the headline number cannot be improved by
   traffic moving out of it. */
const bodyBytes = (rows) =>
  rows.filter((r) => r.method === "GET").reduce((n, r) => n + r.bytes, 0);
const otherBytes = (rows) =>
  rows.filter((r) => r.method !== "GET").reduce((n, r) => n + r.bytes, 0);
const first = bodyBytes(firstVisit);
const second = bodyBytes(secondVisit);

/* Printed as well as asserted: the project makes a claim about this number,
   and a threshold that passes says nothing about the room left under it. */
console.log(
  `  revisit ${Math.round(second / 1024)} KB against ${
    Math.round(first / 1024)
  } KB, ${firstVisit.length} requests, ${
    secondVisit.filter((r) => r.fromCache).length
  } straight from cache`,
);

/* Floors, not budgets. They exist so "coming back costs nothing" is measured
   against a visit that actually paid for something. ui/test/payload.mjs is
   where size is held to account, and the only place that should fail when
   something grows.

   Lowered from 512 KB and 100 KB when the js_of_ocaml bundle went from
   1,058 KB on the wire to 181 KB. Neither was near firing -- a first visit is
   around 735 KB and the bundle is well over 100 KB either way -- but both were
   sized against a payload that no longer exists. Set low enough that making
   the app smaller still is not a test failure. */
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
/* Named separately, because it is what the complaint was about. It is not only
   the verified core: ocaml/lib's BIP-39, NFKD and KDF inputs, the band table,
   digestif, uunf and the js_of_ocaml runtime are all in there, and it moves
   when any of them does. */
const coreAgain = secondVisit.filter((r) =>
  r.path === "/tessarium.js" && r.bytes > 0
);
check(
  `the core is not sent again (${coreAgain.length} resends)`,
  coreAgain.length === 0,
);
/* Name whatever the second visit did pay for, so a regression that
   re-downloads one large thing is legible rather than a total that drifted. */
if (second >= first / 20) {
  secondVisit.filter((r) => r.bytes > 4096)
    .sort((a, b) => b.bytes - a.bytes)
    .slice(0, 8)
    .forEach((r) => {
      console.log(`    re-sent ${Math.round(r.bytes / 1024)} KB  ${r.path}`);
    });
}

/* The map's bytes are most of the weight, so a run where the map never asked
   for a tile would report a saving it did not make. */
const firstTiles = firstVisit.filter((r) =>
  r.path.startsWith("/tiles/") && r.bytes > 0
);
check(
  `the map fetched tiles on the way in (${firstTiles.length})`,
  firstTiles.length > 0,
);
/* Sent, not asked for. The browser asks about every one of them -- that is
   what `no-cache` plus a validator means. */
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
/* The saving must be the cache doing its job, not the second visit doing
   less. */
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
   what this app ships, none of it is reachable until a phrase is accepted, and
   a static import put all of it in the entry chunk -- 551 KB on the wire,
   measured, on the one screen a visitor sees before deciding whether to use
   this at all. The map is a separate chunk now; see
   ui/src/components/mapChunk.ts.

   A cold context, because the claim is about a first visit. Nothing is typed
   at first: the gate starts the map download as soon as a phrase passes its
   checksum, so typing one would measure the warm-up rather than the gate.

   So this is the cost of REACHING a phrase field that can be typed into, not
   the cost of using it. The verified core (/tessarium.js, about 181 KB) and
   the map chunk both follow, as the phrase is typed and as it validates.

   Two checks, because either alone can be satisfied the wrong way. The budget
   fails if the map returns to the entry chunk. The second fails if someone
   meets the budget by breaking the map instead -- the chunk has to still
   arrive on the way in, or there is no saving, only a smaller app that does
   less. */
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
   line, and the point of the number is where it stops. */
const atGate = gateRows.slice();
const gateBytes = atGate
  .filter((r) => r.method === "GET")
  .reduce((n, r) => n + r.bytes, 0);

console.log(
  `  gate ${Math.round(gateBytes / 1024)} KB over ${
    atGate.filter((r) => r.method === "GET").length
  } requests`,
);

/* 200 KB against a measured 178 over the wire (173 under gzip -9; the server's
   compressor emits a little more, and this budget is the wire).

   Raised from 176 when the language picker became a React Aria Select. That
   put the library's shared core -- collections, overlays, focus management --
   in the entry chunk, because the gate renders a dropdown. Measured: the gate
   went up 38,617 bytes and the map chunk came DOWN 49,222, because the map no
   longer carries its own copy. A whole session is 10,605 bytes cheaper and
   only the first screen pays more. That cost was taken deliberately, for one
   interaction library rather than two, and is recorded here rather than
   absorbed silently.

   Raised again, from 200 to 215, when the edgerunner wordmark got its own
   face. Measured: the gate went from 190 KB over four requests to 205 over
   five, and the fifth is the 15 KB woff2 -- already compressed, so gzip takes
   nothing further off it. It is fetched on the gate because the gate is where
   the wordmark is, and the palette the app opens in is a edgerunner one. A
   subset cut to the letters of the name would be about 2 KB and was not
   taken: it turns a rename into a wordmark that falls back mid-word, with
   nothing saying so.

   The remaining gap is room for the gate to grow, and it is still nowhere near
   the 551 KB a static map import costs, which is the regression this catches.
   Raise it only with a measurement saying why -- the same rule
   ui/test/payload.mjs sets. */
check(
  `the phrase screen costs ${Math.round(gateBytes / 1024)} KB`,
  gateBytes < 215 * 1024,
);
/* Named, so a regression is legible rather than a total that drifted. */
if (gateBytes >= 215 * 1024) {
  atGate.filter((r) => r.bytes > 4096)
    .sort((a, b) => b.bytes - a.bytes)
    .forEach((r) => {
      console.log(`    ${Math.round(r.bytes / 1024)} KB  ${r.path}`);
    });
}

const jsAssets = (rows) =>
  rows.filter((r) =>
    r.path.startsWith("/assets/") && r.path.endsWith(".js") && r.bytes > 0
  );
check(
  `and pulls one script to do it (${jsAssets(atGate).length})`,
  jsAssets(atGate).length === 1,
);

/* Now all the way in, on the same page, so the second half is measured against
   the same cold cache. Matched on size rather than on the chunk's name: what
   matters is that the map arrives separately and is the big half, not what
   Vite called the file. */
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
/* The saving is real only if the split did not just move the whole app later.
   The gate has to be the smaller half. */
check(
  `and it is the larger half`,
  mapChunks.reduce((n, r) => n + r.bytes, 0) > gateBytes,
);

/* The fallback, which needs the download to be slow enough to see. Nothing
   else in this suite renders it -- on a local server the chunk arrives between
   frames -- and an unrendered loading state rots into a blank panel or an
   untranslated string without anyone noticing. Delayed on purpose, and read
   for its text as well as its presence, so a missing catalogue entry fails
   rather than showing an empty box. */
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
   the root, and it is right: the segment holds no separator and no NUL. It is
   simply longer than NAME_MAX, which is 255 on Linux, so statx answers
   ENAMETOOLONG. That exception used to travel up as a connection error, so one
   unauthenticated request took the connection down instead of being answered.
   Name length is a fact about the directory, and F* is never told about
   directories, so this gets a test rather than a lemma.

   Both routes, because they answer differently and only one is a 404: a
   segment with no extension is an SPA route, so the UI path serves index.html,
   and the basemap path has no such fallback. Node's fetch does not normalise a
   long segment the way it collapses `..`, so the server sees what is written
   here. */
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
   this passes even against the bug above, which took one socket down rather
   than the server. It catches the worse version, where an unhandled error on a
   request path ends the process. */
const afterLong = await fetch(`${base}/healthz`).then(
  (r) => r.status,
  (e) => `threw: ${e.message}`,
);
check(
  `and the server is still answering afterwards (${afterLong})`,
  afterLong === 200,
);

/* The conditional request itself, at the protocol level: the properties a
   browser depends on but does not reveal when it is working. */
const conditional = async (path) => {
  const plain = await fetch(`${base}${path}`);
  /* Decoded, not wire bytes: node's fetch asks for gzip and inflates before
     handing the body over, so this is several times what crossed the socket.
     It shows the resource is not empty, which is all it can show. */
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
       policy as the body it stands in for. Nothing else would notice it
       stopping: the browser reuses the stored response, so a missing policy
       here shows up as a security hole rather than as a broken page. */
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
   other one: it would decode gzip as UTF-8. */
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
   hash. The sprite sheet, because the fixture's one glyph file is empty and a
   304 for it would be indistinguishable from a 200. */
const sprite = await conditional("/basemap/sprites/v4/light.png");
check(
  `a file off disk revalidates too (${sprite.decoded} decoded, then ${sprite.length})`,
  sprite.tag !== null && sprite.status === 304 && sprite.decoded > 0
    && sprite.length === 0,
);

/* Two If-None-Match field lines rather than one comma-joined value. An
   intermediary may split what a browser sent as one, and RFC 9110 5.3 says the
   two forms mean the same thing -- but the header API hands back only the LAST
   line, so a server that reads one value tells a client holding the bytes to
   download them again. Sent through node:http, because fetch's Headers joins
   duplicates before they reach the socket. */
const twoLines = async (path, tags) =>
  await new Promise((resolve) => {
    const url = new URL(`${base}${path}`);
    http.request({
      hostname: url.hostname,
      port: url.port,
      path: url.pathname,
      /* The same encoding the tag was taken under. Ask for identity and the
         gzip tag correctly does not match -- the encoding suffix working,
         which would look like this check failing. */
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
   z/x/y. Tiles are most of the bytes, and their tag is taken over the bytes
   because the archive under them can be replaced while the server runs. */
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

/* A Range whose validator has moved on is answered with the whole file, not a
   window into different bytes. The downloader rewrites map.pmtiles in place,
   so splicing a stale 206 into a partial copy would join two archives. */
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

   The rule the browse cache lives by: a completed download OWNS its region and
   prunes any browsed copy of the tiles it covers, because the tile endpoint
   reads the cache first and a stale browsed tile would shadow freshly
   downloaded bytes forever. Testable only HERE: this server runs the real
   compaction threshold, so the cache persists between operations, while the
   multipart server's one-byte threshold folds it away the moment it exists.
   Driven over the API -- the page is gone, so nothing auto-browses underneath
   these steps. */
const awaitRemoved = async (generation) =>
  (await until(async () => {
    const status = await (await postJson("basemap-status")).json();
    return status.generation === generation && status.job?.state === "removed"
      ? "removed"
      : status.job?.state === "failed"
      ? "failed"
      : false;
  })) === "removed";
const cacheStatus = async () =>
  (await fetch(`${base}/basemap/cache.pmtiles`, { method: "HEAD" })).status;
const deepTile = async () =>
  (await fetch(`${base}/tiles/15/${lt.x}/${lt.y}.mvt`)).status;

/* Open a hole: removing the UK entry drops the deep London tiles no kept entry
   fetched, which is what a browse can then fill. */
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

/* Refill, then download the same region. Completion must prune the cache --
   emptied entirely here, so the file itself goes -- and the tile must keep
   serving, now from bytes the download fetched fresh. */
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
    && (prunedLedger.entries ?? []).filter((e) => !e.overview).length === 2,
);
await postJson("basemap-settings", { browse_cache: false });

/* ------------- a download that stops early still owns its region ----------

   Every part renamed into the archive owns what it published from that moment
   on, so the browse cache must lose those tiles whether the run finished or
   not: the tile endpoint reads the cache FIRST, and an older browsed copy
   would shadow the fresh bytes forever. The completed case is covered above;
   this is the cancelled one.

   This server reads through the delaying proxy, which is what makes "halfway"
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

/* The whole fixture, which covers that corner, in pieces small enough that the
   first lands early and several remain. */
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
/* A part having landed is what makes the run own a region, and it can be asked
   directly: the record is published with every part, not only the last, so an
   entry appearing IS a part on disk. That is what makes a cancelled download
   resumable, and why this no longer waits on a file name it had to know in
   advance. */
check(
  "a part of the download reached the archive",
  await until(
    async () =>
      ((await (await post5("basemap-ledger")).json()).entries ?? []).length
        > 0,
    { tries: 600, delayMs: 25 },
  ),
);
check(
  "cancelling it is accepted",
  (await (await post5("basemap-cancel")).json()).ok === true,
);
const stopped = (await until(async () => {
  const state = (await (await post5("basemap-status")).json()).job?.state ?? "";
  return ["cancelled", "done", "failed"].includes(state) ? state : false;
}, { tries: 300, delayMs: 100 })) || "still running";
/* Finishing first would make the next check vacuous rather than wrong, so this
   fails loudly instead of passing quietly. */
check(
  `the download stopped as cancelled (got ${stopped})`,
  stopped === "cancelled",
);
check(
  "a cancelled download still prunes the region it published",
  (await cancelHas("cache.pmtiles")) === 404,
);
/* What it leaves behind, which used to be nothing anyone could name. The parts
   that landed are in a file of the region's own, and the record inside it says
   so, because the record is published with every part. Tiles from a cancelled
   download used to sit in the shared archive claimed by no entry: unlistable,
   unremovable, and invisible to everything except the map drawing them. */
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
const removedPartial = (await until(async () => {
  const state = (await (await post5("basemap-status")).json()).job?.state ?? "";
  return ["removed", "failed"].includes(state) ? state : false;
}, { tries: 300, delayMs: 100 })) || "still running";
check(
  `an interrupted download can be removed (got ${removedPartial})`,
  removedPartial === "removed"
    && (await cancelHas(partial?.file ?? "nothing")) === 404,
);
await post5("basemap-settings", { browse_cache: false });

/* ------------------ a source that changed compression ---------------------

   Tile bytes are copied verbatim and the header says how to read them, so an
   archive built from a gzipped source and then MERGED with an uncompressed one
   would relabel every tile it already held. Unreadable, silently, and only at
   render time. This server's source disagrees with the archive seeded beside
   it, so every path that would merge them has to refuse.

   That is now fewer paths. A region download merges with nothing: it writes
   its own file, and the tile endpoint reads every file through that file's own
   header, so two regions in two compressions are two files that both draw.
   Refusing there would refuse on behalf of a merge that cannot happen. A
   browse still writes into the cache, and the cache is still folded into
   map.pmtiles, so that one still refuses. */
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

   `serve_file` writes the status line and `content-length` first, the body
   afterwards. It used to open the file in the body callback, so a file renamed
   in between produced `200 OK, content-length: N` followed by a closed socket
   with nothing in it -- and a truncated body against a promised length is the
   one failure a client cannot tell from a network fault. The app opens that
   window itself: the downloader renames every region archive into place under
   the very root this endpoint serves.

   Driven the way it was measured. A file under the basemap root is moved away
   and back while it is fetched in a loop, and the rule is that every 200
   delivers exactly what it promised. A 404 is a fine answer -- the name really
   is absent for part of each cycle -- and so is any other status. What is not
   fine is a 200 that under-delivers.

   The counts are reported whether or not it passes, because "0 truncated" is
   only worth reading next to how many 200s happened. */
const racyRoot = new URL("../../_build/e2e-basemap/", import.meta.url);
const racyPath = new URL("racy.bin", racyRoot);
const racyAside = new URL("racy.bin.aside", racyRoot);
const racyBytes = Buffer.alloc(128 * 1024, 7);
writeFileSync(racyPath, racyBytes);

/* 600 rather than a round hundred, because the window is narrow. Measured
   against the unfixed server, 2 of 300 requests truncated, so a short loop
   would clear a broken build about one run in eight. 600 puts that under 2%.
   Still a probabilistic check, which is why the fix is structural and this
   only watches it. */
const ROUNDS = 600;

/* Away and back, so the name is genuinely absent for part of every cycle.
   Replacing it in place would not do: the old code would open the replacement,
   stream a file of the same length, and look correct. */
const flip = async (n) => {
  if (n === 0) return;
  try {
    renameSync(racyPath, racyAside);
    renameSync(racyAside, racyPath);
  } catch { /* lost a race with ourselves; the next round re-tries */ }
  await new Promise((resolve) => setTimeout(resolve, 1));
  return flip(n - 1);
};
const flipper = flip(ROUNDS);

/* One round, one verdict. undici rejects a body shorter than the promised
   length, which is the failure being looked for, so that throw counts as a
   truncation rather than as an error in this harness. */
const racyRound = async () => {
  const res = await fetch(`${base}/basemap/racy.bin`).catch(() => null);
  if (res === null) return "other";
  const promised = Number(res.headers.get("content-length"));
  const got = await res.arrayBuffer().then((b) => b.byteLength, () => -1);
  if (res.status === 404) return "missing";
  if (res.status !== 200) return "other";
  return got === promised && promised === racyBytes.length
    ? "complete"
    : "truncated";
};
/* Sequential, with the fold carrying the verdicts: the point is many separate
   requests racing the flipper, not one burst racing it once. */
const racyVerdicts = await Array.from({ length: ROUNDS }).reduce(
  async (acc) => {
    const prior = await acc;
    return [...prior, await racyRound()];
  },
  Promise.resolve([]),
);
await flipper;
rmSync(racyPath, { force: true });
rmSync(racyAside, { force: true });

const racy = (verdict) => racyVerdicts.filter((v) => v === verdict).length;
check(
  `a file renamed mid-flight never truncates a promised body `
    + `(${racy("complete")} complete, ${racy("truncated")} truncated, `
    + `${racy("missing")} absent, ${racy("other")} other, of ${ROUNDS})`,
  racy("truncated") === 0,
);
/* Keeps the check above from passing because nothing was ever served: a loop
   that only saw 404s proves nothing about promised bodies. */
check(
  `and the loop actually served the file (${racy("complete")} times)`,
  racy("complete") > 0,
);

slowProxy.close();

problems.forEach((p) => {
  console.log(`  PAGE  ${p}`);
});
check(
  "no console errors, CSP violations or failed requests",
  problems.length === 0,
);

const failed = results.filter((r) => !r.ok).length;
console.log(`\n${results.length} checks, ${failed} failures`);
process.exit(failed ? 1 : 0);
