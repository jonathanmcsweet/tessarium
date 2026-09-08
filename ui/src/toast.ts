/* The toast queue, and the two timings that are not defaults.

   React Aria's toast state is a plain queue object living outside React:
   `add` can be called from anywhere -- a mutation's onError, a worker
   callback -- and the region subscribed to it re-renders. So this is a
   module rather than a hook, and a component can raise a toast without
   holding a reference to the thing that draws it.

   Sonner did this job before. It shipped injected CSS with white,
   near-black and 8px as literals -- a second source of colour the contrast
   audit could not see, and one that had to be beaten on specificity to
   theme at all. What is drawn now is this project's own markup and
   utilities.

   Two timings, tuned for screen readers. Omitting `timeout` makes a toast
   wait to be dismissed, and errors do: a five-second auto-dismiss is
   shorter than a long error read aloud, so the message vanished
   mid-sentence. Successes keep the timeout -- one short statement, nothing
   to re-read. Both are asserted end to end (test/e2e.mjs, "what a toast has
   to keep doing"). */

import { UNSTABLE_ToastQueue as ToastQueue } from "react-aria-components";

/* How long a success stays. Named because the end-to-end suite waits past
   it to prove an error does not. */
export const SUCCESS_MS = 5000;

export type ToastKind = "error" | "success" | "note";
export type ToastBody = { message: string; kind: ToastKind; };

/* Three at once. This queue HOLDS what it cannot show rather than dropping
   it, so a lower ceiling turns a burst into a backlog that drains one
   five-second timeout at a time -- and a message about something done half
   a minute ago arrives as if it had just happened. The suite exercises
   this: several downloads in a row each report their own outcome. */
export const toasts = new ToastQueue<ToastBody>({ maxVisibleToasts: 3 });

/* No timeout: an error waits to be dismissed. The region draws a close
   control for exactly this reason -- a message that cannot be got rid of is
   a trap. */
export const toastError = (message: string): void => {
  toasts.add({ message, kind: "error" });
};

export const toastSuccess = (message: string): void => {
  toasts.add({ message, kind: "success" }, { timeout: SUCCESS_MS });
};

/* Neither good news nor bad: a download the user cancelled themselves. It
   goes on its own, like a success -- there is nothing to re-read. */
export const toastNote = (message: string): void => {
  toasts.add({ message, kind: "note" }, { timeout: SUCCESS_MS });
};
