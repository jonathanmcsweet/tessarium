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
import { Lock } from "./icons";

export function LockDialog({ onConfirm }: { onConfirm: () => void; }) {
  return (
    <DialogTrigger>
      <Button className="lock btn btn-quiet gap-1.5 px-3">
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
