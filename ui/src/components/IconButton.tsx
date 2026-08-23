/* The shared icon-only button.

   An icon on its own tells a sighted mouse user very little and a screen
   reader user nothing at all, so this component makes the text mandatory
   rather than optional: `label` is required, it becomes both the tooltip and
   the `aria-label`, and there is no way to render one without the other.

   React Aria supplies the behaviour -- hover, keyboard focus, Escape to
   dismiss, collision handling, and the aria wiring. Like every tooltip
   implementation worth using it deliberately does not open on touch, because
   on a touchscreen hover does not exist, so the one thing added here is a
   long-press to open it. That is the only gesture a touch user has for "what
   is this?".

   This was Radix, and moving it is what let the Radix dependency go: the
   search box is React Aria (components/PlaceSearch.tsx), and one library for
   interaction behaviour is the point. `onPressStart` reports the pointer
   type, so the long press no longer needs its own pointer-event handlers to
   find out whether it is on a touchscreen. */

import { type ReactNode, useRef, useState } from "react";
import {
  Button,
  OverlayArrow,
  Tooltip,
  TooltipTrigger,
} from "react-aria-components";

const LONG_PRESS_MS = 450;

type Props = {
  /* Shown in the tooltip and announced as the accessible name. Required. */
  label: string;
  icon: ReactNode;
  onClick: () => void;
  /* For toggles, so assistive technology announces the state as well as the
     name. Leave unset for plain actions. */
  pressed?: boolean;
  disabled?: boolean;
  className?: string;
};

export function IconButton({
  label,
  icon,
  onClick,
  pressed,
  disabled,
  className,
}: Props) {
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
      <Button
        className={className ? `icon-button ${className}` : "icon-button"}
        onPress={onClick}
        isDisabled={disabled ?? false}
        aria-label={label}
        {
          /* Spread rather than passed, because `exactOptionalPropertyTypes`
            makes an explicit `undefined` a type error and a plain action
            button must not carry `aria-pressed` at all -- an unset toggle
            state and "not a toggle" are different claims to a screen
            reader. */
          ...(pressed === undefined ? {} : { "aria-pressed": pressed })
        }
        onPressStart={(e) => {
          if (e.pointerType !== "touch") return;
          clearTimer();
          timer.current = setTimeout(() => setOpen(true), LONG_PRESS_MS);
        }}
        onPressEnd={clearTimer}
      >
        {icon}
      </Button>
      {
        /* The arrow is drawn here rather than by the library: React Aria
          positions an OverlayArrow and leaves its shape to the caller, where
          Radix shipped one. Eight pixels wide, filled by `.tooltip-arrow`,
          and rotated by the library to whichever side it landed on. */
      }
      <Tooltip className="tooltip" offset={6} containerPadding={8}>
        <OverlayArrow className="tooltip-arrow">
          <svg width={8} height={8} viewBox="0 0 8 8" aria-hidden="true">
            <path d="M0 0 L4 4 L8 0 Z" />
          </svg>
        </OverlayArrow>
        {label}
      </Tooltip>
    </TooltipTrigger>
  );
}
