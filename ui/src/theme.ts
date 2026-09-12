import { useEffect, useState } from "react";

export const themes = [
  "edge-dark",
  "edge-light",
  "dark",
  "light",
  "night",
  "system",
] as const;
export type Theme = (typeof themes)[number];

export const DEFAULT_THEME: Theme = "edge-dark";
export type ResolvedTheme = Exclude<Theme, "system">;
const CHAMFERED: readonly ResolvedTheme[] = ["edge-dark", "edge-light"];

export const glyphSet = (theme: ResolvedTheme): "cut" | "plain" =>
  CHAMFERED.includes(theme) ? "cut" : "plain";

/* Sets two attributes and nothing else. Every palette lives in the
   stylesheet, `color-scheme` included, so there is no inline style to keep
   in step. No `data-theme` means the default.

   `data-icons` is the one thing about a palette a stylesheet cannot work out
   for itself, because the answer is about a RESOLVED theme and "match my
   device" resolves through a media query. Written here rather than from an
   effect so it is right on the first paint; the provider in icons.tsx keeps
   it current if the device changes its mind while nobody has chosen. */
export function applyTheme(theme: Theme) {
  const root = document.documentElement;
  if (theme === DEFAULT_THEME) root.removeAttribute("data-theme");
  else root.setAttribute("data-theme", theme);
  root.setAttribute("data-icons", glyphSet(resolveTheme(theme)));
}

function resolveTheme(theme: Theme): ResolvedTheme {
  if (theme !== "system") return theme;
  return globalThis.matchMedia?.("(prefers-color-scheme: dark)").matches
    ? "dark"
    : "light";
}

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
