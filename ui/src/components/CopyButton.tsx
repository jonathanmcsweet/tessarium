/* Copy, with the answer on the button.

   A toast said "copied" from the top of the screen, which is a long way from
   the thing that was copied and disappears on its own. A tick in place of the
   icon is the pattern people already know from GitHub and everywhere else: it
   appears where the press happened, and it says the clipboard actually took
   it rather than that the attempt was made.

   The label changes with the icon, so a screen reader hears the confirmation
   too -- an icon swap on its own would announce nothing. Failure keeps the
   toast: it needs to say what to do instead, which is more than a button can
   hold.

   The timer is cleared on unmount. Locking the map removes this button while
   the tick is up, and a setState on a gone component is a warning in the
   console and a leak in principle. */

import { Check, Copy } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { toastError } from "../toast";
import { IconButton } from "./IconButton";

const SHOWN_MS = 2000;

export function CopyButton(
  { label, copiedLabel, text, onFailure }: {
    label: string;
    /* Named per caller rather than one generic "Copied": the address and the
       coordinates are different things and a screen reader should hear which
       one landed. */
    copiedLabel: string;
    /* Read at press time, not at render time: the value can be concealed,
       and a concealed value is absent from the DOM rather than merely
       invisible, so there is nothing on screen to select instead. */
    text: () => string | null;
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
    if (value === null) return;
    try {
      await navigator.clipboard.writeText(value);
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
      {...(copied ? { className: "copied" } : {})}
      icon={copied
        ? <Check size={18} aria-hidden />
        : <Copy size={18} aria-hidden />}
    />
  );
}
