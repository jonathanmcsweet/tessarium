/* The lock button, and the question it asks first.

   Locking forgets the derived key AND the words it came from, so getting
   back in means typing the 24 words again. The worker holds them until this
   press and nothing else does, which makes this dialog the last moment they
   can be taken -- so it offers to, rather than only warning that it is too
   late.

   A refresh forgets them the same way and cannot be intercepted politely:
   the browser's own "leave site?" prompt takes no wording. This dialog is
   for the deliberate case; the panel's footer carries the same copy control
   for the other one. */

import { Lock } from "lucide-react";
import {
  Button,
  Dialog,
  DialogTrigger,
  Heading,
  Modal,
  ModalOverlay,
} from "react-aria-components";
import { core } from "../core/queries";
import { m } from "../paraglide/messages";
import { CopyButton } from "./CopyButton";

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
                  /* The offer the warning above is about, next to it rather
                    than in the row below: that row is the question being
                    asked -- cancel, or lock -- and a third control in it
                    reads as a third answer. */
                }
                <div className="phrase-copy mb-3 flex items-center gap-2 text-sm">
                  <CopyButton
                    className="lock-phrase-copy"
                    label={m.panel_phrase_copy()}
                    copiedLabel={m.panel_phrase_copied()}
                    text={() =>
                      core().heldPhrase().then((held) => held.mnemonic)}
                    onFailure={m.panel_phrase_copy_failed()}
                  />
                  <span>{m.panel_phrase_copy()}</span>
                </div>
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
                    className="danger btn btn-primary"
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
