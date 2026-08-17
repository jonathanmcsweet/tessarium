/* The shared icon-only button.

   An icon on its own tells a sighted mouse user very little and a screen
   reader user nothing at all, so this component makes the text mandatory
   rather than optional: `label` is required, it becomes both the tooltip and
   the `aria-label`, and there is no way to render one without the other.

   Radix's Tooltip supplies the behaviour -- hover, keyboard focus, Escape to
   dismiss, collision handling, and the aria wiring. It deliberately does not
   open on touch, because on a touchscreen hover does not exist, so the one
   thing added here is a long-press to open it. That is the only gesture a
   touch user has for "what is this?". */

import * as Tooltip from "@radix-ui/react-tooltip";
import { type ReactNode, useRef, useState } from "react";

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
    <Tooltip.Root open={open} onOpenChange={setOpen} delayDuration={300}>
      <Tooltip.Trigger asChild>
        <button
          type="button"
          className={className ? `icon-button ${className}` : "icon-button"}
          onClick={onClick}
          disabled={disabled}
          aria-label={label}
          aria-pressed={pressed}
          onPointerDown={(e) => {
            if (e.pointerType !== "touch") return;
            clearTimer();
            timer.current = setTimeout(() => setOpen(true), LONG_PRESS_MS);
          }}
          onPointerUp={clearTimer}
          onPointerCancel={clearTimer}
          onPointerLeave={clearTimer}
        >
          {icon}
        </button>
      </Tooltip.Trigger>
      <Tooltip.Portal>
        <Tooltip.Content
          className="tooltip"
          sideOffset={6}
          collisionPadding={8}
        >
          {label}
          <Tooltip.Arrow className="tooltip-arrow" />
        </Tooltip.Content>
      </Tooltip.Portal>
    </Tooltip.Root>
  );
}
