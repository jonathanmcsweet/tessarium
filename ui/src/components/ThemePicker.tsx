/* The appearance menu. One of them.

   Both places that offer a theme render THIS: the foot of the panel and the
   foot of the gate. Not two dropdowns wired to the same store -- that is how
   the option names, the icon and the ordering start disagreeing, one place at
   a time.

   It is on the gate because the gate is a screen someone can be stuck on -- a
   phrase read off paper, in a room the device's own guess about light is
   wrong about -- and the panel only exists once a map is open. The language
   menu is at the foot of both for the same class of reason, and this sits
   beside it in both.

   `labelHidden` is the Dropdown's own prop passed through. The label EXISTS
   either way -- a dropdown with no accessible name is unusable. */

import { Palette } from "lucide-react";
import { m } from "../paraglide/messages";
import { useAppStore } from "../store";
import { type Theme, themes } from "../theme";
import { Dropdown } from "./Dropdown";

/* Named per option rather than generated, so a translator sees sentences
   instead of a key pattern. "Match my device" is deliberately not called
   "System": it says whose decision it is. */
const themeLabel: Record<Theme, () => string> = {
  "cyber-dark": () => m.theme_cyber_dark(),
  "cyber-light": () => m.theme_cyber_light(),
  dark: () => m.theme_dark(),
  light: () => m.theme_light(),
  night: () => m.theme_night(),
  system: () => m.theme_system(),
};

const themeOptions = () =>
  themes.map((t) => ({ value: t, label: themeLabel[t]() }));

export function ThemePicker(
  { className, labelHidden }: { className?: string; labelHidden?: boolean; },
) {
  const theme = useAppStore((s) => s.theme);
  const setTheme = useAppStore((s) => s.setTheme);

  return (
    <div
      className={`theme flex items-center gap-1.5 text-ink-soft${
        className ? ` ${className}` : ""
      }`}
    >
      <Palette size={16} aria-hidden />
      <Dropdown<Theme>
        label={m.settings_theme()}
        labelHidden={labelHidden ?? false}
        value={theme}
        onChange={setTheme}
        options={themeOptions()}
      />
    </div>
  );
}
