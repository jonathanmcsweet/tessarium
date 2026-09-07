/* The lock button, and the question it asks first.

   Locking forgets the derived key, and getting back in means typing the 24
   words again. The application cannot show them: it wipes the phrase the
   moment the key is derived and keeps only the key, in a worker. So this
   says so at the one moment it matters, which is the press.

   A refresh does the same thing and cannot be intercepted politely -- the
   browser's own "leave site?" prompt takes no wording -- so the panel
   carries a standing note as well. This dialog is for the deliberate
   case. */

import { Lock } from "lucide-react";
import {
  Button,
  Dialog,
  DialogTrigger,
  Heading,
  Modal,
  ModalOverlay,
} from "react-aria-components";
import { m } from "../paraglide/messages";

export function LockDialog({ onConfirm }: { onConfirm: () => void; }) {
  return (
    <DialogTrigger>
      <Button className="lock btn btn-quiet gap-1.5 px-3 text-ink-soft">
        <Lock size={15} aria-hidden="true" />
        {m.panel_lock()}
      </Button>
      {
        /* Dismissable, because cancelling is the safe answer and Escape or a
          press outside should reach it. The destructive one is a button and
          only a button. */
      }
      <ModalOverlay
        className="fixed inset-0 z-60 flex items-center justify-center bg-[rgb(15_23_32/0.45)] p-4"
        isDismissable
      >
        <Modal className="max-h-[90vh] w-[min(27.5rem,100%)] overflow-y-auto border border-line-strong bg-card shadow-[0_8px_32px_rgb(0_0_0/0.3)]">
          <Dialog className="modal-dialog p-5 outline-none">
            {({ close }) => (
              <>
                <Heading slot="title" className="mb-2.5 text-lg font-semibold">
                  {m.lock_title()}
                </Heading>
                <p className="mb-3 text-sm leading-relaxed">{m.lock_body()}</p>
                <p className="warning mb-3">
                  <strong>{m.lock_warning_title()}</strong>{" "}
                  {m.lock_warning_body()}
                </p>
                {
                  /* Cancel first in the DOM, so Tab reaches it first and a
                    screen reader reads it first -- and first on screen too,
                    with the destructive button last, where a pointer expects
                    the action it came to take. `flex-row-reverse` does the
                    opposite: it puts the FIRST child on the right, which put
                    Cancel under the thumb. */
                }
                <div className="modal-actions mt-4 flex justify-end gap-2">
                  <Button
                    className="btn btn-quiet border-line-strong"
                    onPress={close}
                  >
                    {m.lock_cancel()}
                  </Button>
                  <Button
                    className="danger btn btn-danger"
                    onPress={() => {
                      close();
                      onConfirm();
                    }}
                  >
                    {m.lock_confirm()}
                  </Button>
                </div>
              </>
            )}
          </Dialog>
        </Modal>
      </ModalOverlay>
    </DialogTrigger>
  );
}
