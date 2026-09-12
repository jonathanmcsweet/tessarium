import { useEffect, useRef, useState } from "react";
import { toastError } from "../toast";
import { IconButton } from "./IconButton";
import { Check, Copy } from "./icons";

const SHOWN_MS = 2000;

const isPending = (
  value: string | null | Promise<string | null>,
): value is Promise<string | null> =>
  typeof value === "object" && value !== null && "then" in value;

export function CopyButton(
  { label, copiedLabel, text, onFailure, disabled, className }: {
    label: string;
    className?: string;
    disabled?: boolean;
    copiedLabel: string;
    /* Read at press time, not at render time: the value can be concealed,
       and a concealed value is absent from the DOM rather than merely
       invisible, so there is nothing on screen to select instead. */
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
