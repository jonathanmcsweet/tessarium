/* Copy, with the answer on the button.

   A toast said "copied" from the top of the screen, a long way from the
   thing that was copied. A tick in place of the icon appears where the press
   happened, and says the clipboard actually took it.

   The label changes with the icon, so a screen reader hears the confirmation
   too. Failure keeps the toast: it has to say what to do instead, which is
   more than a button can hold.

   The timer is cleared on unmount, because locking the map removes this
   button while the tick is up. */

import { Check, Copy } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { toastError } from "../toast";
import { IconButton } from "./IconButton";

const SHOWN_MS = 2000;

const isPending = (
  value: string | null | Promise<string | null>,
): value is Promise<string | null> =>
  typeof value === "object" && value !== null && "then" in value;

export function CopyButton(
  { label, copiedLabel, text, onFailure, disabled, className }: {
    label: string;
    /* A hook for the end-to-end suite, which cannot name this button by its
       label without pinning one locale. */
    className?: string;
    /* For a caller whose value is not ready yet -- the gate's phrase before
       it is 24 words. Disabled rather than absent, so the row does not change
       width under the pointer on the last word typed. */
    disabled?: boolean;
    /* Named per caller rather than one generic "Copied": the address and the
       coordinates are different things and a screen reader should hear which
       one landed. */
    copiedLabel: string;
    /* Read at press time, not at render time: the value can be concealed,
       and a concealed value is absent from the DOM rather than merely
       invisible, so there is nothing on screen to select instead.

       May answer with a promise, for the source that is not on this thread
       at all -- the seed phrase, which lives in the worker and is fetched by
       the press rather than held here waiting for one. */
    text: () => string | null | Promise<string | null>;
    onFailure: string;
  },
) {
  const [copied, setCopied] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => () => {
    if (timer.current !== null) clearTimeout(timer.current);
  }, []);

  async function copy() {
    const value = text();
    try {
      if (isPending(value)) {
        {
          /* A promise handed straight to the clipboard rather than awaited
             first. Awaiting spends the user gesture before the write, which
             Safari refuses outright; `ClipboardItem` takes the promise and
             the browser waits for it inside the gesture that started it. */
        }
        await navigator.clipboard.write([
          new ClipboardItem({
            "text/plain": value.then((text) => {
              if (text === null) throw new Error("nothing held to copy");
              return new Blob([text], { type: "text/plain" });
            }),
          }),
        ]);
      } else {
        if (value === null) return;
        await navigator.clipboard.writeText(value);
      }
      setCopied(true);
      if (timer.current !== null) clearTimeout(timer.current);
      timer.current = setTimeout(() => setCopied(false), SHOWN_MS);
    } catch {
      toastError(onFailure);
    }
  }

  return (
    <IconButton
      label={copied ? copiedLabel : label}
      onClick={copy}
      disabled={disabled ?? false}
      {...(className === undefined ? {} : { className })}
      {...(copied ? ({ tone: "ok" } as const) : {})}
      icon={copied
        ? <Check size={18} aria-hidden />
        : <Copy size={18} aria-hidden />}
    />
  );
}
