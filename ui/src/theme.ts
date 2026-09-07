/* Which palette, and who decides.

   Six entries, five palettes. "Match my device" is a deferral rather than a
   sixth colour, and it must stay distinguishable from having chosen light,
   so a device that flips to dark in the evening carries the app with it. It
   defers to the two PLAIN palettes: an operating system says light or dark,
   it does not say cyberpunk.

   The default is cyberpunk dark, and the default is the palette that wears
   no attribute: the stylesheet's @theme block paints before any attribute
   is set, so whatever is written there IS the default.

   Nothing is stored. Reloading returns to the default -- the same rule the
   language menu follows, and for the same reason: this application persists
   nothing about the user.

   `color-scheme` travels with each palette in the stylesheet. It tells the
   browser to draw its OWN pieces dark: scrollbars, the caret, form controls
   before our styles reach them, and the canvas behind the page during a
   reload. Without it a dark page keeps a white scrollbar and flashes white
   on every navigation. */

import { useEffect, useState } from "react";

export const themes = [
  "cyber-dark",
  "cyber-light",
  "dark",
  "light",
  "night",
  "system",
] as const;
export type Theme = (typeof themes)[number];

/* The palette @theme paints, and so the one that wears no attribute. */
export const DEFAULT_THEME: Theme = "cyber-dark";

/* A theme with the "who decides" taken out. "night" is the low-light
   palette -- red on black, to keep night vision -- and only ever arrives by
   choice: resolveTheme returns neither it nor either cyberpunk palette for
   "system", because no media query knows its user is in the dark. */
export type ResolvedTheme = Exclude<Theme, "system">;

/* Sets one attribute and nothing else. Every palette lives in the
   stylesheet, `color-scheme` included, so there is no inline style to keep
   in step. No attribute means the default. */
export function applyTheme(theme: Theme) {
  const root = document.documentElement;
  if (theme === DEFAULT_THEME) root.removeAttribute("data-theme");
  else root.setAttribute("data-theme", theme);
}

/* What is on screen right now, which is what an icon has to show: offering
   "switch to dark" on a device that is already dark is worse than offering
   nothing. Reads the media query when nobody has chosen. */
function resolveTheme(theme: Theme): ResolvedTheme {
  if (theme !== "system") return theme;
  return globalThis.matchMedia?.("(prefers-color-scheme: dark)").matches
    ? "dark"
    : "light";
}

/* The resolved scheme, kept current while the device changes its mind.

   Someone on "system" at dusk should have the application follow rather
   than wait for a reload they will not do -- this page holds a derived key,
   and reloading means typing 24 words again. So the media query is
   subscribed to, not read once. Once a person has chosen, the subscription
   stays live and its answer is ignored. */
export function useResolvedTheme(theme: Theme): ResolvedTheme {
  const [device, setDevice] = useState(() => resolveTheme("system"));
  useEffect(() => {
    const query = globalThis.matchMedia?.("(prefers-color-scheme: dark)");
    if (!query) return;
    const listen = () => setDevice(query.matches ? "dark" : "light");
    listen();
    query.addEventListener("change", listen);
    return () => query.removeEventListener("change", listen);
  }, []);
  return theme === "system" ? device : theme;
}
