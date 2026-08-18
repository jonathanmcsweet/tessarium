/* Toast timing, tuned for screen readers.

   Sonner announces through a live region, and a five-second auto-dismiss is
   shorter than a long error read aloud -- the message vanished mid-sentence.
   Errors therefore stay until dismissed (the Toaster's closeButton is
   load-bearing here); successes are short statements and keep the default. */

import { toast } from "sonner";

export const toastError = (message: string): void => {
  toast.error(message, { duration: Number.POSITIVE_INFINITY });
};
