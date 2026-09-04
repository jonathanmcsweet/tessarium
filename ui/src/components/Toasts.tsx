/* What a toast looks like. The queue and its two timings are in ../toast.

   Top centre, so it sits over neither the address panel on desktop nor a
   thumb on mobile -- the same placement the previous library was configured
   for, and the reason is the layout rather than the library.

   Every colour here is a token and every corner is square, which is the
   point of drawing it ourselves: a toast is now audited by the same
   contrast test as the rest of the application, and follows a theme change
   with no rule of its own. */

import { X } from "lucide-react";
/* The `UNSTABLE_` prefix is the library saying this API may change shape in a
   MINOR release, which is inside what a caret range accepts. So
   react-aria-components is pinned to an exact version in package.json rather
   than carried on `^`: an unannounced rename would otherwise arrive with a
   routine `pnpm update` and take the toasts out with it. Moving it is a
   deliberate edit, and the end-to-end suite is what says whether the move
   was safe. */
import {
  Button,
  UNSTABLE_Toast as Toast,
  UNSTABLE_ToastContent as ToastContent,
  UNSTABLE_ToastList as ToastList,
  UNSTABLE_ToastRegion as ToastRegion,
} from "react-aria-components";
import { m } from "../paraglide/messages";
import { type ToastBody, toasts } from "../toast";

export function Toasts() {
  return (
    <ToastRegion
      queue={toasts}
      aria-label={m.a11y_toast_region()}
      /* The region is a landmark and is only in the document while a toast
         is up, so it can be fixed without ever covering anything. */
      className="fixed top-4 left-1/2 z-[60] flex -translate-x-1/2 flex-col
        gap-2 outline-none"
    >
      <ToastList<ToastBody> className="flex list-none flex-col gap-2 p-0">
        {({ toast }) => (
          <Toast
            toast={toast}
            /* Which kind, as data rather than as a colour class: the suite
               has to find an error toast, and finding it by the utility
               that happens to paint it would break the next time the
               painting changed. */
            data-kind={toast.content.kind}
            /* `app-toast` is this application's own name for a toast: the
               end-to-end suite reads it, so its assertions never name a
               library and survived this very move. */
            className="app-toast flex w-[min(28rem,calc(100vw-2rem))]
              items-start gap-3 border border-line-strong bg-card px-4 py-3
              text-sm leading-normal shadow-card"
          >
            <ToastContent className="min-w-0 flex-1">
              <span
                className={`app-toast-message block break-words ${
                  /* An error is the accent as TEXT, which is the token that
                     holds 4.5:1 in every palette -- the non-text accent does
                     not, and this is 13px. A success is ordinary ink: the
                     tick that raised it already said which it was, and a
                     second colour saying the same thing is noise. */
                  toast.content.kind === "error"
                    ? "font-semibold text-accent-text"
                    : "text-ink"}`}
              >
                {toast.content.message}
              </span>
            </ToastContent>
            {
              /* Not the shared IconButton: that one carries a tooltip, and a
                 tooltip on a control inside a message that is itself
                 transient is a second transient thing to chase. The label is
                 still required, still translated, and still announced. */
            }
            <Button
              slot="close"
              aria-label={m.a11y_dismiss_toast()}
              className="focus-ring -mt-0.5 -mr-1 flex h-8 w-8 flex-none
                cursor-pointer items-center justify-center border-0 bg-transparent
                text-ink-soft hover:text-ink"
            >
              {
                /* The shared icon set, at the size the other dismiss controls
                  use -- see Banner and MapProgress, which close the same way. */
              }
              <X size={16} aria-hidden />
            </Button>
          </Toast>
        )}
      </ToastList>
    </ToastRegion>
  );
}

export type { ToastBody };
