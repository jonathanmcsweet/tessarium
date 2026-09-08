/* The shared icon-only button.

   An icon alone tells a sighted mouse user very little and a screen reader
   user nothing, so the text is mandatory: `label` is required and becomes
   both the tooltip and the `aria-label`. There is no way to render one
   without the other.

   React Aria supplies the behaviour -- hover, keyboard focus, Escape to
   dismiss, collision handling, the aria wiring. Like every tooltip worth
   using it does not open on touch, because hover does not exist there, so
   the one thing added here is a long press. That is the only gesture a
   touch user has for "what is this?".

   This was Radix; moving it is what let the Radix dependency go, leaving one
   interaction library. `onPressStart` reports the pointer type, so the long
   press needs no pointer-event handlers of its own. */

import { type ReactNode, useRef, useState } from "react";
import {
  Button,
  OverlayArrow,
  Tooltip,
  TooltipTrigger,
} from "react-aria-components";

const LONG_PRESS_MS = 450;

/* 44px, the smallest target most touch guidance accepts. The icon inside is
   18px; the rest is what a thumb needs. No background of its own, so a
   caller that needs one (the reopen tab, which floats over the map) can add
   it without fighting a class here for the same property. */
const BASE =
  "icon-button icon-cut focus-ring inline-flex h-11 w-11 flex-none items-center "
  + "justify-center border border-line p-0 "
  + "hover:not-disabled:bg-hover hover:not-disabled:text-ink "
  + "aria-pressed:border-ink-soft aria-pressed:text-ink";

/* Colour is a prop rather than a class the caller passes in: two utilities
   setting the same property resolve by their order in the generated sheet,
   not by the order written in the markup, and a state the button can be in
   should not be decided there. */
const TONES = {
  /* Quiet: these sit beside the address, which is the one thing on the
     panel that should draw the eye. */
  default: "text-ink-soft",
  /* The tick after a copy. Green rather than the accent, because the accent
     here means "this is the address" and this means "that worked". */
  ok: "border-ok-strong text-ok-strong",
} as const;

type Props = {
  /* Shown in the tooltip and announced as the accessible name. Required. */
  label: string;
  icon: ReactNode;
  onClick: () => void;
  /* For toggles, so assistive technology announces the state as well as the
     name. Leave unset for plain actions. */
  pressed?: boolean;
  disabled?: boolean;
  tone?: keyof typeof TONES;
  className?: string;
};

export function IconButton({
  label,
  icon,
  onClick,
  pressed,
  disabled,
  tone = "default",
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
        className={`${BASE} ${TONES[tone]}${className ? ` ${className}` : ""}`}
        onPress={onClick}
        isDisabled={disabled ?? false}
        aria-label={label}
        {
          /* Spread rather than passed: `exactOptionalPropertyTypes` makes an
            explicit `undefined` a type error, and a plain action button must
            not carry `aria-pressed` at all -- an unset toggle state and "not
            a toggle" are different claims to a screen reader. */
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
        /* The arrow is drawn here because React Aria positions an
          OverlayArrow and leaves its shape to the caller, where Radix
          shipped one. Eight pixels wide, filled to match the tooltip, and
          rotated to whichever side it landed on -- the shape points DOWN, so
          the default placement above the button needs no rotation. `fill` is
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
