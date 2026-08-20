import { readFileSync } from "node:fs";
import { chromium } from "playwright";

const vectors = JSON.parse(readFileSync(new URL("../../vectors/vectors.json", import.meta.url), "utf8"));
const mnemonic = vectors.key_derivation[0].mnemonic;
const base = "http://127.0.0.1:7390";

const browser = await chromium.launch();
const page = await browser.newPage();
await page.goto(base, { waitUntil: "networkidle" });
await page.locator("#phrase").fill(mnemonic);
await page.waitForSelector(".valid", { timeout: 30_000 });
await page.locator("button[type=submit]").click();
await page.waitForSelector(".map-wrap", { timeout: 60_000 });
await page.waitForTimeout(3000);

// instrument events
await page.evaluate(() => {
  window.__diag = { dataloading: 0, sourcedataloading: 0, idle: 0, bar: [] };
  const map = window.__tessarium_map;
  map.on("dataloading", () => window.__diag.dataloading++);
  map.on("sourcedataloading", () => window.__diag.sourcedataloading++);
  map.on("idle", () => window.__diag.idle++);
  new MutationObserver(() => {
    window.__diag.bar.push(document.querySelector(".map-loading") !== null);
  }).observe(document.querySelector(".map-wrap"), { childList: true });
});

await page.route("**/tiles/**", async (route) => {
  await new Promise((d) => setTimeout(d, 600));
  try { await route.continue(); } catch { /* aborted */ }
});

const before = await page.evaluate(() => ({ ...window.__diag, bar: [...window.__diag.bar] }));
await page.evaluate(() => {
  const src = window.__tessarium_map.getSource("protomaps");
  window.__diag.tiles = src?.tiles;
  if (src?.setTiles) src.setTiles(src.tiles.map((u) => `${u}&e2e_bar=1`));
  else window.__diag.noSetTiles = true;
});
await page.waitForTimeout(3000);
const after = await page.evaluate(() => ({ ...window.__diag, bar: [...window.__diag.bar] }));
console.log("before:", JSON.stringify(before));
console.log("after:", JSON.stringify(after));
console.log("bar ever shown:", after.bar.some((b) => b));
await browser.close();
