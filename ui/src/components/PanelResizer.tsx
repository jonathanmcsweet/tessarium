import type { KeyboardEvent, RefObject } from "react";
import { useRef } from "react";
import { useMove } from "react-aria";
import { m } from "../paraglide/messages";
import {
  clampPanelWidth,
  PANEL_DEFAULT,
  PANEL_MAX,
  PANEL_MIN,
  useAppStore,
} from "../store";

const STEP = 16;
const COARSE = 64;
const TARGET = "absolute inset-y-0 right-[var(--panel-offset,340px)] z-6 w-6 "
  + "cursor-col-resize touch-none border-0 p-0 outline-none max-drawer:hidden";
const HANDLE = "before:absolute before:top-1/2 before:left-1/2 before:h-8 "
  + "before:w-1 before:-translate-x-1/2 before:-translate-y-1/2 "
  + "before:bg-line-strong before:content-[''] "
  + "before:transition-colors before:duration-100 "
  + "hover:before:bg-accent focus-visible:before:bg-accent";

export function PanelResizer(
  {
    /* The element carrying the panel's width. Handed down rather than looked
       up, so the one thing this component reaches outside itself is a ref its
       parent chose to give it. */
    surface,
  }: { surface: RefObject<HTMLDivElement | null>; },
) {
  const panelWidth = useAppStore((s) => s.panelWidth);
  const setPanelWidth = useAppStore((s) => s.setPanelWidth);
  const dragging = useRef<number | null>(null);

  const paint = (width: number) => {
    const node = surface.current;
    if (!node) return;
    node.style.setProperty("--panel-w", `${width}px`);
  };

  const { moveProps } = useMove({
    onMoveStart() {
      dragging.current = useAppStore.getState().panelWidth;
    },
    onMove(event) {

      const from = dragging.current ?? useAppStore.getState().panelWidth;
      const scale = event.pointerType === "keyboard"
        ? (event.shiftKey ? COARSE : STEP)
        : 1;

      const next = clampPanelWidth(from - event.deltaX * scale);
      dragging.current = next;
      if (event.pointerType === "keyboard") setPanelWidth(next);
      else paint(next);
    },
    onMoveEnd() {
      if (dragging.current !== null) setPanelWidth(dragging.current);
      dragging.current = null;
    },
  });


  function onKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (event.key === "Home" || event.key === "End") {
      event.preventDefault();
      setPanelWidth(event.key === "Home" ? PANEL_MIN : PANEL_MAX);
      return;
    }
    moveProps.onKeyDown?.(event);
  }

  return (
    // biome-ignore lint/a11y/useSemanticElements: <hr> carries this role but is neither focusable nor resizable, and a window splitter must take focus and carry aria-value*, so the role belongs on a div here.
    <div
      {...moveProps}
      onKeyDown={onKeyDown}
      className={`panel-resizer ${TARGET} ${HANDLE}`}
      role="separator"
      tabIndex={0}
      aria-orientation="vertical"
      aria-label={m.panel_resize()}
      aria-valuenow={panelWidth}
      aria-valuemin={PANEL_MIN}
      aria-valuemax={PANEL_MAX}
      onDoubleClick={() => setPanelWidth(PANEL_DEFAULT)}
    />
  );
}
