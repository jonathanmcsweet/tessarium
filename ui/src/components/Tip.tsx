/* The tooltip, and the two things that wear one.

   React Aria supplies the behaviour -- hover, keyboard focus, Escape to
   dismiss, collision handling, the aria wiring. Like every tooltip worth
   using it does not open on touch, because hover does not exist there, so the
   one thing added here is a long press. That is the only gesture a touch user
   has for "what is this?".

   The shell is a component rather than markup copied into each caller: the
   overlay, its arrow and the long press are one behaviour, and a second copy
   is how a tooltip that dismisses differently or points the wrong way gets
   into the application. `Tip` renders the overlay and hands its caller the
   press handlers the long press needs; what the caller draws is its own.

   This was Radix; moving it is what let the Radix dependency go, leaving one
   interaction library. `onPressStart` reports the pointer type, so the long
   press needs no pointer-event handlers of its own. */

import { Info } from "lucide-react";
import { type ReactNode, useRef, useState } from "react";
import {
  Button,
  OverlayArrow,
  Tooltip,
  TooltipTrigger,
} from "react-aria-components";

const LONG_PRESS_MS = 450;

/* What a trigger must spread onto itself for the long press to work. Handed
   out rather than applied here, because the trigger is the caller's element
   and React Aria needs it to be TooltipTrigger's own child. */
export type PressHold = {
  onPressStart: (event: { pointerType: string; }) => void;
  onPressEnd: () => void;
};

export function Tip(
  { label, children }: {
    /* Shown in the overlay. Callers also make it the trigger's accessible
       name: React Aria describes the trigger with the tooltip only while it
       is open, so a name that depends on the tooltip being open is no name
       at all to a screen reader. */
    label: string;
    children: (hold: PressHold) => ReactNode;
  },
) {
  const [open, setOpen] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const clearTimer = () => {
    if (timer.current !== null) {
      clearTimeout(timer.current);
      timer.current = null;
    }
  };

  return (
    <TooltipTrigger isOpen={open} onOpenChange={setOpen} delay={300}>
      {children({
        onPressStart: (event) => {
          if (event.pointerType !== "touch") return;
          clearTimer();
          timer.current = setTimeout(() => setOpen(true), LONG_PRESS_MS);
        },
        onPressEnd: clearTimer,
      })}
      {
        /* The arrow is drawn here because React Aria positions an
          OverlayArrow and leaves its shape to the caller, where Radix
          shipped one. Eight pixels wide, filled to match the tooltip, and
          rotated to whichever side it landed on -- the shape points DOWN, so
          the default placement above the trigger needs no rotation. `fill` is
          inherited, so setting it on the wrapper reaches the path inside. */
      }
      <Tooltip
        className="z-40 max-w-65 bg-ink px-2.5 py-1.5 text-xs leading-snug text-on-ink shadow-card"
        offset={6}
        containerPadding={8}
      >
        <OverlayArrow className="fill-ink leading-none placement-bottom:rotate-180 placement-left:-rotate-90 placement-right:rotate-90">
          <svg
            width={8}
            height={8}
            viewBox="0 0 8 8"
            aria-hidden="true"
            className="block"
          >
            <path d="M0 0 L4 4 L8 0 Z" />
          </svg>
        </OverlayArrow>
        {label}
      </Tooltip>
    </TooltipTrigger>
  );
}

/* A sentence that belongs to a heading rather than to the reader's next
   decision: what a section is for, said once, out of the way of the controls
   under it. It presses to nothing on purpose -- the whole content is the
   label, which is why the label is also the accessible name and not a
   generic "more information".

   Small and unbordered, unlike IconButton: this sits inside a line of text
   and must not read as a fourth control in a row of three. */
export function InfoTip({ label }: { label: string; }) {
  return (
    <Tip label={label}>
      {(hold) => (
        <Button
          className="info-tip focus-ring ms-1 inline-flex h-5 w-5 flex-none cursor-help items-center justify-center border-0 p-0 align-middle text-ink-soft hover:text-ink"
          aria-label={label}
          {...hold}
        >
          <Info size={14} aria-hidden />
        </Button>
      )}
    </Tip>
  );
}
