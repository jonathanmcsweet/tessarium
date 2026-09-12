import { m } from "../paraglide/messages";
import { useAppStore } from "../store";
import { type Theme, themes } from "../theme";
import { Dropdown } from "./Dropdown";
import { Palette } from "./icons";

const themeLabel: Record<Theme, () => string> = {
  "edge-dark": () => m.theme_edge_dark(),
  "edge-light": () => m.theme_edge_light(),
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
