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
  + "hover:not-aria-disabled:bg-hover hover:not-aria-disabled:text-ink "
  + "aria-disabled:cursor-not-allowed "
  + "aria-pressed:border-ink-soft aria-pressed:text-ink";

const TONES = {
  default: "text-ink-soft",
  ok: "border-ok-strong text-ok-strong",
} as const;

type Props = {
  label: string;
  icon: ReactNode;
  onClick: () => void;
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
          onPress={() => {
            if (disabled !== true) onClick();
          }}
          aria-label={label}
          {...(disabled === true ? { "aria-disabled": true } : {})}
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
