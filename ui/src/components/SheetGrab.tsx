/* The handle on the bottom sheet, and the only way back to it on a phone.

   Below --breakpoint-drawer the panel is a sheet across the bottom, where the
   desktop pair -- a "close the drawer" icon in the panel's header, and a tab
   floating at the map's right edge to bring it back -- are both the wrong
   gesture. A sheet is pulled, and a phone reader knows the pill at its top
   edge means so before reading anything.

   It lives outside the panel rather than in its header, because the control
   that reopens the sheet cannot travel with it. `--sheet-offset` is how much
   of the bottom edge the sheet is covering, so riding on it puts the handle
   on the sheet's top edge when it is open and on the map's bottom edge when
   it is shut, with one transition and no second position to keep in step.

   A button, with a name that says which way it goes and `aria-expanded` for
   what it did: the pill is a shape, and a shape is not a label. */

import { m } from "../paraglide/messages";
import { useAppStore } from "../store";

export function SheetGrab() {
  const collapsed = useAppStore((s) => s.panelCollapsed);
  const togglePanel = useAppStore((s) => s.togglePanel);

  return (
    <div className="sheet-grab absolute inset-x-0 z-6 drawer:hidden">
      <button
        type="button"
        className="sheet-grab-button focus-ring flex h-9 w-full items-center justify-center border-t border-line bg-card"
        aria-label={collapsed ? m.panel_show() : m.panel_hide()}
        aria-expanded={!collapsed}
        aria-controls="panel"
        onClick={togglePanel}
      >
        <span className="sheet-grab-bar" aria-hidden />
      </button>
    </div>
  );
}
