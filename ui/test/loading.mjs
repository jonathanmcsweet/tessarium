/* The loading tracker's whole reason to exist is what it does NOT show:
   a burst that settles before the delay must never flash the bar. Fake
   clocks, so the timing rules are asserted exactly. */

import { createLoadingTracker } from "../src/core/loading.ts";

let checks = 0;
let failures = 0;
const check = (name, ok) => {
  checks++;
  if (!ok) {
    failures++;
    console.log(`  FAIL  ${name}`);
  }
};

function clock() {
  let now = 0;
  let seq = 0;
  const pending = new Map();
  return {
    setT: (fn, ms) => {
      const id = ++seq;
      pending.set(id, { at: now + ms, fn });
      return id;
    },
    clearT: (id) => pending.delete(id),
    advance: (ms) => {
      now += ms;
      for (const [id, t] of [...pending]) {
        if (t.at <= now) {
          pending.delete(id);
          t.fn();
        }
      }
    },
  };
}

{
  const shown = [];
  const c = clock();
  const t = createLoadingTracker((on) => shown.push(on), 300, c.setT, c.clearT);
  t.loading();
  c.advance(299);
  check("nothing shows before the delay", shown.length === 0);
  c.advance(1);
  check(
    "shows once the delay elapses",
    shown.length === 1 && shown[0] === true,
  );
  t.idle();
  check("hides immediately on idle", shown.length === 2 && shown[1] === false);
}

{
  const shown = [];
  const c = clock();
  const t = createLoadingTracker((on) => shown.push(on), 300, c.setT, c.clearT);
  t.loading();
  c.advance(200);
  t.idle();
  c.advance(1000);
  check("a burst that settles early never flashes", shown.length === 0);
}

{
  const shown = [];
  const c = clock();
  const t = createLoadingTracker((on) => shown.push(on), 300, c.setT, c.clearT);
  t.loading();
  c.advance(100);
  t.loading(); /* repeat events must not restart the delay */
  c.advance(200);
  check("repeat loading events do not restart the clock", shown.length === 1);
  t.idle();
  t.idle();
  check("repeat idles do not double-hide", shown.length === 2);
}

{
  const shown = [];
  const c = clock();
  const t = createLoadingTracker((on) => shown.push(on), 300, c.setT, c.clearT);
  t.loading();
  t.dispose();
  c.advance(1000);
  check("nothing fires after dispose", shown.length === 0);
}

{
  const shown = [];
  const c = clock();
  const t = createLoadingTracker((on) => shown.push(on), 300, c.setT, c.clearT);
  t.loading();
  c.advance(300);
  t.idle();
  t.loading();
  c.advance(300);
  check(
    "a second episode shows again",
    shown.length === 3 && shown[2] === true,
  );
}

console.log(`\nloading indicator: ${checks} checks, ${failures} failures`);
if (failures > 0) process.exit(1);
