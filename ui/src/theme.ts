/* Light or dark, and who decides.

   Three states, not two. "system" is not a third colour -- it is the absence
   of a choice, and it has to stay distinguishable from having chosen light,
   because a device that flips to dark in the evening should carry the app
   with it unless someone said otherwise. So the root element carries
   `data-theme` only when a person picked one, and the stylesheet reads
   `prefers-color-scheme` the rest of the time.

   Nothing is stored. Reloading returns to the device's own answer, which is
   the same rule the language menu follows and for the same reason: this
   application persists nothing, and a colour scheme is not worth being the
   exception that makes that sentence untrue. The cost is one preference
   forgotten per reload; the thing it buys is that "we store nothing about
   you" needs no footnote.

   `color-scheme` travels with each palette in the stylesheet, and it is not
   decoration: it is what tells the browser to draw its OWN pieces dark --
   scrollbars, the caret, form controls before our styles reach them, and
   the canvas behind the page during a reload. Without it a dark page keeps
   a white scrollbar and flashes white on every navigation. */

import { useEffect, useState } from "react";

export const themes = ["system", "light", "dark", "night"] as const;
export type Theme = (typeof themes)[number];

/* What is actually on screen: a theme with the "who decides" taken out.
   "night" is the low-light palette -- red on black, for keeping night
   vision -- and only ever arrives by choice; resolveTheme never returns it
   for "system", because no media query can know its user is in the dark. */
export type ResolvedTheme = Exclude<Theme, "system">;

/* Sets one attribute and nothing else. The stylesheet does the rest -- both
   palettes live there, including `color-scheme`, so there is no inline style
   to keep in step and no path where the colours and the browser's own
   chrome disagree. Absent means nobody chose. */
export function applyTheme(theme: Theme) {
  const root = document.documentElement;
  if (theme === "system") root.removeAttribute("data-theme");
  else root.setAttribute("data-theme", theme);
}

/* What is actually on screen right now, which is what an icon has to show:
   a control offering "switch to dark" while the device is already dark is
   worse than no control. Reads the media query when nobody has chosen. */
function resolveTheme(theme: Theme): ResolvedTheme {
  if (theme !== "system") return theme;
  return globalThis.matchMedia?.("(prefers-color-scheme: dark)").matches
    ? "dark"
    : "light";
}

/* The resolved scheme, kept current while the device changes its mind.

   Someone on "system" at dusk should have the application follow, not wait
   for a reload it will not get -- this page holds a derived key and
   reloading it means typing 24 words again. So the media query is
   subscribed to rather than read once. When a person has chosen, the
   subscription is still live but its answer is ignored, which is the whole
   meaning of having chosen. */
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
