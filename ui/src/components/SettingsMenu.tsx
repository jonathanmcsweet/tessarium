/* The gear in the panel header.

   One place for the choices that are about the application rather than about
   the map. Today that is the colour scheme; the language menu stays at the
   foot of the panel, where it has always been and where someone who cannot
   read the current language will still find it -- a settings gear is a poor
   place to put the control that fixes "I cannot read this".

   A popover rather than a menu of actions: what is inside is a labelled
   control with a current value, and a menu item that silently holds state is
   harder to announce than a select that says what it is set to.

   The gear itself is icon-only, so it carries the same contract every other
   icon in this application does -- an accessible name and a tooltip, both
   from the same string, via the shared IconButton. */

import { Settings } from "lucide-react";
import { Dialog, DialogTrigger, Popover } from "react-aria-components";
import { m } from "../paraglide/messages";
import { useAppStore } from "../store";
import { type Theme, themes } from "../theme";
import { Dropdown } from "./Dropdown";
import { IconButton } from "./IconButton";

/* Named per option rather than generated, so a translator sees three
   sentences instead of a key pattern. "Match my device" is deliberately not
   called "System": it says whose decision it is. */
const themeLabel: Record<Theme, () => string> = {
  system: () => m.theme_system(),
  light: () => m.theme_light(),
  dark: () => m.theme_dark(),
};

export function SettingsMenu() {
  const theme = useAppStore((s) => s.theme);
  const setTheme = useAppStore((s) => s.setTheme);

  return (
    <DialogTrigger>
      <IconButton
        className="panel-settings"
        label={m.a11y_settings()}
        icon={<Settings size={18} aria-hidden />}
        /* Opening is the DialogTrigger's job, not this handler's -- React
           Aria wires the press through. The prop is required, so this says
           so rather than pretending to do the work. */
        onClick={() => {}}
      />
      <Popover className="settings-popover sheet p-4">
        <Dialog className="outline-none" aria-label={m.a11y_settings()}>
          <Dropdown<Theme>
            className="settings-theme w-56 flex-col items-start gap-1.5"
            label={m.settings_theme()}
            value={theme}
            onChange={setTheme}
            options={themes.map((t) => ({
              value: t,
              label: themeLabel[t](),
            }))}
          />
        </Dialog>
      </Popover>
    </DialogTrigger>
  );
}
