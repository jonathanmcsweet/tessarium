import { m } from "../paraglide/messages";
import { useAppStore } from "../store";

export function SheetGrab() {
  const collapsed = useAppStore((s) => s.panelCollapsed);
  const togglePanel = useAppStore((s) => s.togglePanel);

  return (
    <div className="sheet-grab absolute inset-x-0 z-6 drawer:hidden">
      <button
        type="button"
        className="sheet-grab-button focus-ring flex w-full items-start justify-center bg-card"
        aria-label={collapsed ? m.panel_show() : m.panel_hide()}
        aria-expanded={!collapsed}
        aria-controls="panel"
        onClick={togglePanel}
      >
        <span className="grab-pill" aria-hidden />
      </button>
    </div>
  );
}
