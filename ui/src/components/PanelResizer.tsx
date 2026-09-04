/* The drag handle between the map and the side panel.

   The interaction comes from react-aria's `useMove`, which is already in the
   tree: react-aria-components depends on react-aria 3.51.0, so naming it
   directly reuses that exact copy rather than adding a second one. `useMove`
   normalises mouse, touch and KEYBOARD into one stream of deltas -- the last
   of those is the point, because a splitter that only answers to a pointer
   is a control that half the people using it cannot reach.

   What the hook does not supply is the widget semantics, and those are not
   optional: the WAI-ARIA window splitter is `role="separator"` with a tab
   stop, an orientation, and the three `aria-value*` numbers, so the width is
   ANNOUNCED rather than merely changed. Those stay here, where they belong. */

import type { KeyboardEvent } from "react";
import { useMove } from "react-aria";
import { m } from "../paraglide/messages";
import { PANEL_DEFAULT, PANEL_MAX, PANEL_MIN, useAppStore } from "../store";

/* useMove reports one pixel per arrow press, which would take four hundred
   presses to cross the range. Scaled up for the keyboard only; a pointer
   drag already carries real distance. Shift moves in bigger jumps. */
const STEP = 16;
const COARSE = 64;

/* The part a pointer has to hit: 24px wide, because that is the WCAG 2.5.8
   minimum for a pointer target and a splitter people cannot hit is a splitter
   people cannot use. Nearly all of it is transparent.

   `touch-none` matters more than it looks. Without it a touch drag here
   scrolls the page instead of moving the handle, and the control simply does
   not work on a phone. It is hidden below the drawer breakpoint, where the
   panel is a sheet across the bottom and there is no vertical edge to
   drag. */
const TARGET = "absolute inset-y-0 right-[var(--panel-offset,340px)] z-6 w-6 "
  + "cursor-col-resize touch-none border-0 p-0 outline-none max-drawer:hidden";

/* The part that is drawn: a short grab handle at the middle of the edge,
   not a line down the whole of it. A full-height rule reads as a second
   border beside the panel's own and says nothing about being draggable; a
   stub in the middle is the affordance every resizable panel uses, and it
   is where a hand reaches anyway. It takes the accent on hover and on
   keyboard focus -- there is no outline, because the handle IS the mark and
   the mark is what answers. */
const HANDLE = "before:absolute before:top-1/2 before:left-1/2 before:h-8 "
  + "before:w-1 before:-translate-x-1/2 before:-translate-y-1/2 "
  + "before:bg-line-strong before:content-[''] "
  + "before:transition-colors before:duration-100 "
  + "hover:before:bg-accent focus-visible:before:bg-accent";

export function PanelResizer() {
  const panelWidth = useAppStore((s) => s.panelWidth);
  const setPanelWidth = useAppStore((s) => s.setPanelWidth);

  const { moveProps } = useMove({
    onMove(event) {
      /* Read through the store rather than the render closure: a fast drag
         delivers several moves inside one React batch, and a stale closure
         would apply each delta to the same starting width. */
      const current = useAppStore.getState().panelWidth;
      const scale = event.pointerType === "keyboard"
        ? (event.shiftKey ? COARSE : STEP)
        : 1;
      /* Minus, because the panel is on the RIGHT: the handle moving left is
         a negative deltaX and has to make the panel wider. */
      setPanelWidth(current - event.deltaX * scale);
    },
  });

  /* Composed rather than replacing: useMove owns the arrow keys, and these
     two are the rest of the splitter pattern -- jump to either end. */
  function onKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (event.key === "Home" || event.key === "End") {
      event.preventDefault();
      setPanelWidth(event.key === "Home" ? PANEL_MAX : PANEL_MIN);
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
      /* A double-click on a splitter conventionally restores the default. */
      onDoubleClick={() => setPanelWidth(PANEL_DEFAULT)}
    />
  );
}
