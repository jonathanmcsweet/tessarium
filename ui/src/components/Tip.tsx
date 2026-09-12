import { type ReactNode, useRef, useState } from "react";
import {
  Button,
  OverlayArrow,
  Tooltip,
  TooltipTrigger,
} from "react-aria-components";
import { Info } from "./icons";

const LONG_PRESS_MS = 450;

export type PressHold = {
  onPressStart: (event: { pointerType: string; }) => void;
  onPressEnd: () => void;
};

export function Tip(
  { label, children }: {
    /* Shown in the overlay. Callers also make it the trigger's accessible
       name: React Aria describes the trigger with the tooltip only while it
       is open */
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
