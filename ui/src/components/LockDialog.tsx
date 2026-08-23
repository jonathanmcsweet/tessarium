/* The lock button, and the question it now asks first.

   Locking forgets the derived key, and getting back in means typing the 24
   words again -- which this application does not have and cannot show,
   because it wipes the phrase the moment the key is derived and keeps only
   the key, in a worker. That is the design and it is not changing here. What
   was missing was anyone SAYING so at the one moment it matters, which is
   the press that makes it true.

   A refresh does the same thing and cannot be intercepted politely -- the
   browser's own "leave site?" prompt takes no wording and is widely ignored
   -- so the panel carries a standing note as well; this dialog is for the
   case the user chose. */

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
      <Button className="lock">
        <Lock size={15} aria-hidden="true" />
        {m.panel_lock()}
      </Button>
      {
        /* Dismissable, because cancelling is the safe answer and Escape or a
          press outside should reach it. The destructive one is a button and
          only a button. */
      }
      <ModalOverlay className="modal-overlay" isDismissable>
        <Modal className="modal">
          <Dialog className="modal-dialog">
            {({ close }) => (
              <>
                <Heading slot="title">{m.lock_title()}</Heading>
                <p>{m.lock_body()}</p>
                <p className="warning">
                  <strong>{m.lock_warning_title()}</strong>{" "}
                  {m.lock_warning_body()}
                </p>
                <div className="modal-actions">
                  <Button onPress={close}>{m.lock_cancel()}</Button>
                  <Button
                    className="danger"
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
