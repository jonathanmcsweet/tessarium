/* The toast queue, and the two timings that are not defaults.

   React Aria's toast state is a plain queue object that lives outside React:
   `add` may be called from anywhere -- a mutation's onError, a worker
   callback -- and the region subscribed to it re-renders. That is why this
   is a module and not a hook, and it is what lets a component raise a toast
   without holding a reference to the thing that draws it.

   Sonner did this job before. Moving off it left the application with one
   behaviour library instead of two, and took the toasts inside the
   stylesheet: sonner shipped its own injected CSS with white, near-black
   and 8px written as literals, which is a second source of truth for
   colour that the contrast audit structurally could not see, and which had
   to be beaten on specificity to theme at all. What is drawn now is this
   project's own markup wearing this project's own utilities.

   Two timings, tuned for screen readers rather than taken as given.
   Omitting `timeout` is what makes a toast wait to be dismissed, and errors
   do: a five-second auto-dismiss is shorter than a long error read aloud,
   and the message vanished mid-sentence. Successes keep the timeout -- one
   short statement, nothing to re-read. Both are asserted end to end
   (test/e2e.mjs, "what a toast has to keep doing"), because a screenshot
   cannot tell them apart and the difference is the whole point. */

import { UNSTABLE_ToastQueue as ToastQueue } from "react-aria-components";

/* How long a success stays. Named because the end-to-end suite waits past
   it to prove an error does not. */
export const SUCCESS_MS = 5000;

export type ToastKind = "error" | "success" | "note";
export type ToastBody = { message: string; kind: ToastKind; };

/* Three at once, which is what the previous library showed and is not a
   cosmetic choice. This queue does not DROP what it cannot show, it holds
   it -- so a lower ceiling turns a burst into a backlog that drains one
   five-second timeout at a time, and a message about something the user did
   half a minute ago arrives as if it had just happened. Showing a burst as a
   burst is the honest version, and it is what the suite exercises: several
   downloads in a row each report their own outcome. */
export const toasts = new ToastQueue<ToastBody>({ maxVisibleToasts: 3 });

/* No timeout: an error waits to be dismissed. The region draws a close
   control for exactly this reason -- a message that cannot be got rid of
   is a trap for anyone who cannot reach for a pointer. */
export const toastError = (message: string): void => {
  toasts.add({ message, kind: "error" });
};

export const toastSuccess = (message: string): void => {
  toasts.add({ message, kind: "success" }, { timeout: SUCCESS_MS });
};

/* Neither an outcome to celebrate nor one to worry about: a download the
   user themselves cancelled. It goes on its own like a success, because
   there is nothing to re-read. */
export const toastNote = (message: string): void => {
  toasts.add({ message, kind: "note" }, { timeout: SUCCESS_MS });
};
