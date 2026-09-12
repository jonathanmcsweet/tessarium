import {
  Button,
  UNSTABLE_Toast as Toast,
  UNSTABLE_ToastContent as ToastContent,
  UNSTABLE_ToastList as ToastList,
  UNSTABLE_ToastRegion as ToastRegion,
} from "react-aria-components";
import { m } from "../paraglide/messages";
import { type ToastBody, toasts } from "../toast";
import { X } from "./icons";

export function Toasts() {
  return (
    <ToastRegion
      queue={toasts}
      aria-label={m.a11y_toast_region()}
      className="fixed top-4 left-1/2 z-[60] flex -translate-x-1/2 flex-col
        gap-2 outline-none"
    >
      <ToastList<ToastBody> className="flex list-none flex-col gap-2 p-0">
        {({ toast }) => (
          <Toast
            toast={toast}
            data-kind={toast.content.kind}
            className="app-toast flex w-[min(28rem,calc(100vw-2rem))]
              items-start gap-3 border border-line-strong bg-card px-4 py-3
              text-sm leading-normal shadow-card"
          >
            <ToastContent className="min-w-0 flex-1">
              <span
                className={`app-toast-message block break-words ${
                  toast.content.kind === "error"
                    ? "font-semibold text-accent-text"
                    : "text-ink"
                }`}
              >
                {toast.content.message}
              </span>
            </ToastContent>
            <Button
              slot="close"
              aria-label={m.a11y_dismiss_toast()}
              className="focus-ring -mt-0.5 -mr-1 flex h-8 w-8 flex-none
                cursor-pointer items-center justify-center border-0 bg-transparent
                text-ink-soft hover:text-ink"
            >
              <X size={16} aria-hidden />
            </Button>
          </Toast>
        )}
      </ToastList>
    </ToastRegion>
  );
}

export type { ToastBody };
