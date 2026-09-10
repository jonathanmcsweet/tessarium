/* The shared icon-only button.

   An icon alone tells a sighted mouse user very little and a screen reader
   user nothing, so the text is mandatory: `label` is required and becomes
   both the tooltip and the `aria-label`. There is no way to render one
   without the other.

   The tooltip itself -- the overlay, its arrow, the long press that stands in
   for hover on a touch screen -- is `Tip`, which the heading info icon also
   wears. Two tooltips drawn by two files is how one of them ends up
   dismissing differently. */

import type { ReactNode } from "react";
import { Button } from "react-aria-components";
import { Tip } from "./Tip";

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
  return (
    <Tip label={label}>
      {(hold) => (
        <Button
          className={`${BASE} ${TONES[tone]}${
            className ? ` ${className}` : ""
          }`}
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
          {...hold}
        >
          {icon}
        </Button>
      )}
    </Tip>
  );
}
