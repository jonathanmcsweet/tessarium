/* The screenshots in README.md, taken from the real app.

   Run through `make screenshots`, which starts a server against the basemap
   `make run` uses -- the shots are of a real map, so the region they show has
   to be downloaded first.

   Deterministic where it can be: a fixed phrase from the test vectors, a
   fixed place, a fixed zoom, and every map shot waits for the tiles to stop
   changing rather than for a timeout. */

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { chromium } from "playwright";

const arg = (name, fallback) => {
  const hit = process.argv.find((a) => a.startsWith(`--${name}=`));
  return hit === undefined ? fallback : hit.slice(name.length + 3);
};

const base = process.argv[2] ?? "http://127.0.0.1:7380";
const outDir = arg("out", new URL("../../screenshots/", import.meta.url).pathname);
const place = arg("place", "atlanta, ga");
/* Absolute, not a number of clicks: every theme has to frame the same view,
   and the grid squares only draw from z18. */
const zoom = Number(arg("zoom", "18.5"));
/* `make screenshots` always passes the flag, empty when ONLY is unset. */
const only = arg("only", "") || null;

/* A published test vector, so nothing here is anyone's phrase. It is masked
   in every shot regardless. */
const vectors = JSON.parse(
  readFileSync(new URL("../../vectors/vectors.json", import.meta.url), "utf8"),
);
const mnemonic = vectors.key_derivation[0].mnemonic;

/* 16:10, the shape of a laptop screen. The tablet shots this replaced were
   1225x942, which is no device. */
const LAPTOP = { name: "laptop", zoom: 18.5, viewport: { width: 1440, height: 900 } };
/* A real handset: 360 CSS px is what a 1080-wide Android panel reports at a
   device pixel ratio of 3, which is most of them. The zoom is shallower than
   the laptop's because a phone shows a fifth of the ground at the same one,
   and the grid still draws at z18. */
const PHONE = {
  name: "phone",
  zoom: 18,
  select: false,
  /* A plain window at the handset's size, not Playwright's device
     descriptor. Chromium's mobile emulation blanks the map canvas the same
     way headless does, and the layout here follows width alone. */
  viewport: { width: 360, height: 732 },
  /* The panel's own ratio is 3, which is 1080x2196 of PNG for a picture read
     at a third of that; 2 is still retina where these are viewed. */
  deviceScaleFactor: 2,
};

const THEMES = ["edge-dark", "edge-light", "dark", "light", "night"];
const DEFAULT_THEME = "edge-dark";

const shots = [];
const record = (path) => {
  shots.push(path);
  console.log(`  ${path.replace(outDir, "").replace(/^\/*/, "")}`);
};

/* maplibre asks for a WebGL context without preserveDrawingBuffer, so the
   buffer is cleared once a frame has been composited and a capture taken
   after the map goes idle reads an empty one. A big map is busy enough that
   a frame is nearly always in flight, which is why this only showed up on
   the phone. redraw() paints synchronously, so the buffer is live when the
   screenshot lands; triggerRepaint only schedules one and is too late.

   Every screenshot goes through this, map or not: on the gate there is no
   map and it does nothing. */
/* Wait for the map to stop working, through its own idle event. An earlier
   version compared successive screenshots of the canvas, which is worse than
   slow: reading the canvas that way empties it, and the shot that followed
   came back blank. */
const settle = async (page) => {
  await page.evaluate(() =>
    new Promise((done) => {
      const map = window.__tessarium_map;
      if (map === undefined) return done();
      if (map.isStyleLoaded() && map.areTilesLoaded()) return done();
      map.once("idle", done);
      setTimeout(done, 30_000);
    }));
  await page.waitForTimeout(1_500);
  return true;
};

const chooseTheme = async (page, theme) => {
  if (theme === DEFAULT_THEME) return;
  await page.locator(".theme .dropdown-button").first().click();
  await page.locator(`[data-value="${theme}"]`).click();
  await page.waitForFunction(
    (t) => document.documentElement.getAttribute("data-theme") === t,
    theme,
    { timeout: 10_000 },
  );
};

const unlock = async (page) => {
  await page.locator("#phrase").fill(mnemonic);
  await page.waitForSelector(".valid", { timeout: 60_000 });
  await page.locator("button[type=submit]").click();
  await page.waitForSelector(".map-wrap", { timeout: 120_000 });
};

const goToPlace = async (page, viewport) => {
  await page.locator("#place-search-input").fill(place);
  /* PlaceSearch debounces at 250 ms, so the first option is not there yet. */
  const first = page.locator(".place-results .place-option").first();
  await first.waitFor({ state: "visible", timeout: 30_000 });
  await first.click();
  /* The results popover stays open over a quarter of the map otherwise. */
  await page.locator("#place-search-input").press("Escape");
  await page.locator(".place-results").waitFor({
    state: "hidden",
    timeout: 10_000,
  });
  /* Through the map's own handle rather than the zoom control, which the
     panel resizer overlays at this width, and which zooms by whole steps
     from wherever the search happened to land. */
  await page.waitForFunction(() => window.__tessarium_map !== undefined, null, {
    timeout: 30_000,
  });
  /* Centre the place in the part of the map a reader can SEE. Below the
     drawer breakpoint the sheet covers the map's lower half, so an unpadded
     centre puts the place behind it and frames a block interior instead. */
  const map = await page.locator(".map-wrap").boundingBox();
  const panel = await page.locator(".panel").boundingBox();
  const covered = panel !== null && panel.x <= map.x + 1
      && panel.width >= map.width - 1
    ? map.y + map.height - panel.y
    : 0;
  await page.evaluate(({ z, bottom }) => {
    const m = window.__tessarium_map;
    if (m === undefined) return;
    const centre = m.getCenter();
    m.setPadding({ top: 0, left: 0, right: 0, bottom });
    m.jumpTo({ center: centre, zoom: z });
  }, { z: viewport.zoom ?? zoom, bottom: Math.round(covered) });
  await settle(page);
  /* Pick the square under the centre, so the panel shows an address rather
     than its "tap any square" placeholder.

     Not on a narrow viewport. Selecting there leaves the map canvas blank in
     every capture that follows, by a mechanism nothing here could pin down:
     the map reports itself loaded with 531 features rendered, the WebGL
     context is alive and error-free, the console is clean, and the pixels
     are simply absent from the image. It survives a resize, a repaint, a
     later camera move, and a fresh capture, and it happens whether the
     selection comes from a real press or from the map's own event. The same
     selection on a laptop-width window renders. Left unselected rather than
     shipping a blank map. */
  if (viewport.select === false) return;
  await page.evaluate(() => {
    const map = window.__tessarium_map;
    if (map === undefined) return;
    const centre = map.getCenter();
    map.fire("click", { lngLat: centre, point: map.project(centre) });
  });
  await page.locator(".address").first().waitFor({ timeout: 30_000 });
  /* Reveal it. The panel conceals an address by default, which is the right
     default and a poor advertisement: the masked panel says nothing about
     what this application produces. The phrase is a published test vector,
     so the address on screen is nobody's. */
  await page
    .locator('[aria-label="Show everything hidden here"]')
    .first()
    .click();
  await page.waitForFunction(
    () => !/^[\u2588\u2591\s.]*$/.test(
      document.querySelector(".address")?.textContent ?? "",
    ),
    null,
    { timeout: 10_000 },
  );
  await settle(page);
};

const shoot = async (page, path) => {
  mkdirSync(path.slice(0, path.lastIndexOf("/")), { recursive: true });
  await page.screenshot({ path });
  record(path);
};

const session = async (browser, viewport, theme) => {
  const context = await browser.newContext({
    viewport: viewport.viewport,
    deviceScaleFactor: viewport.deviceScaleFactor ?? 1,
    reducedMotion: "reduce",
  });
  const page = await context.newPage();
  await page.goto(base);
  /* This is a desktop window at a handset's size, so an overflowing panel
     draws a scrollbar no phone would. */
  await page.addStyleTag({
    content: "*::-webkit-scrollbar{width:0!important;height:0!important}",
  }).catch(() => {});
  await page.waitForSelector("#phrase", { timeout: 60_000 });
  await chooseTheme(page, theme);
  return { context, page };
};

const themeGallery = async (browser) => {
  console.log("\nthemes, on a laptop screen:");
  for (const theme of THEMES) {
    const { context, page } = await session(browser, LAPTOP, theme);
    await unlock(page);
    await goToPlace(page, LAPTOP);
    await shoot(page, `${outDir}/themes/${theme}.png`);
    await context.close();
  }
};

const walkthrough = async (browser, viewport) => {
  console.log(`\n${viewport.name}, in the default theme:`);
  const { context, page } = await session(browser, viewport, DEFAULT_THEME);
  await shoot(page, `${outDir}/${viewport.name}/01-unlock.png`);

  await page.locator(".generate .btn").click();
  await page.waitForFunction(
    () => (document.querySelector("#phrase")?.value ?? "").split(/\s+/).length === 24,
    null,
    { timeout: 60_000 },
  );
  await shoot(page, `${outDir}/${viewport.name}/02-generated.png`);

  await unlock(page);
  await goToPlace(page, viewport);
  await shoot(page, `${outDir}/${viewport.name}/03-map.png`);

  /* The confirmation, not the gate behind it: the gate is shot twice above
     already, and this is the screen that says what locking costs. */
  await page.locator("button.lock").click();
  await page.locator(".modal-dialog").waitFor({ timeout: 30_000 });
  await shoot(page, `${outDir}/${viewport.name}/04-lock.png`);
  await context.close();
};

/* Headed, on the X display `make screenshots` starts for it. Headless
   Chromium paints the map canvas blank wherever another element overlaps it,
   which is every phone shot, because the panel is a sheet across the map's
   lower half there rather than a column beside it. Nothing else moved it:
   not preserveDrawingBuffer, not --use-angle=gl or swiftshader, not
   triggerRepaint, redraw or resize, not layer promotion on either element,
   and not CDP's own capture with fromSurface off. */
const browser = await chromium.launch({ headless: false });
try {
  if (only === null || only === "themes") await themeGallery(browser);
  if (only === null || only === "laptop") await walkthrough(browser, LAPTOP);
  if (only === null || only === "phone") await walkthrough(browser, PHONE);
} finally {
  await browser.close();
}

writeFileSync(
  `${outDir}/MANIFEST.txt`,
  `${shots.length} screenshots, ${place}, zoom ${zoom}\n`
    + shots.map((p) => p.replace(outDir, "").replace(/^\/*/, "")).sort().join("\n")
    + "\n",
);
console.log(`\n${shots.length} screenshots under ${outDir}`);
