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
        /* `sheet` is what every floating surface in the application is made
          of -- the dropdown's list, and this. It was the inverted pair,
          `bg-ink` on `text-on-ink`, which in the four dark palettes is a
          pale box with black text: a system tooltip sitting on top of the
          theme rather than in it.

          The arrow is drawn here because React Aria positions an
          OverlayArrow and leaves its shape to the caller, where Radix
          shipped one. Two paths, because the surface now has a border: one
          filled triangle, one stroked V that does NOT close along the base,
          since a closed path would draw a line across the mouth of the
          arrow. The negative margin pulls the base a pixel into the tooltip,
          over the border segment it would otherwise sit under. `fill` and
          `stroke` are inherited, so setting them on the wrapper reaches both
          paths. Rotated to whichever side it landed on -- the shape points
          DOWN, so the default placement above the trigger needs none. */
      }
      <Tooltip
        className="app-tip sheet max-w-65 px-2.5 py-1.5 text-xs leading-snug text-ink"
        offset={6}
        containerPadding={8}
      >
        <OverlayArrow className="fill-card stroke-line-strong leading-none placement-bottom:rotate-180 placement-left:-rotate-90 placement-right:rotate-90">
          <svg
            width={10}
            height={6}
            viewBox="0 0 10 6"
            aria-hidden="true"
            className="-mt-px block"
          >
            <path d="M0 0 L5 5 L10 0 Z" stroke="none" />
            <path d="M0 0 L5 5 L10 0" fill="none" />
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
          className="info-tip focus-ring ms-1 inline-flex h-5 w-5 flex-none items-center justify-center border-0 p-0 align-middle text-ink-soft hover:text-ink"
          aria-label={label}
          {...hold}
        >
          <Info size={14} aria-hidden />
        </Button>
      )}
    </Tip>
  );
}
