/* The gear in the panel header.

   One place for choices about the application rather than about the map.
   Today that is the colour scheme. The language menu stays at the foot of
   the panel, where someone who cannot read the current language will find
   it: a settings gear is a poor place for the control that fixes "I cannot
   read this".

   A popover rather than a menu of actions, because what is inside is a
   labelled control with a current value, and a menu item holding state is
   harder to announce than a select that says what it is set to.

   The gear is icon-only, so it goes through the shared IconButton and gets
   an accessible name and a tooltip from the same string. */

import { Settings } from "lucide-react";
import { Dialog, DialogTrigger, Popover } from "react-aria-components";
import { m } from "../paraglide/messages";
import { IconButton } from "./IconButton";
import { ThemePicker } from "./ThemePicker";

export function SettingsMenu() {
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
          {
            /* The gate's control, not a second one built the same way. The
               width and the class are this placement's; everything about the
               choice itself lives in the component. */
          }
          <ThemePicker className="settings-theme w-80" />
        </Dialog>
      </Popover>
    </DialogTrigger>
  );
}
