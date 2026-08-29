/* Seed phrase entry.

   The warnings here are not boilerplate. Where the phrase comes from is the
   highest-value security decision in the application, and it is the one this
   code cannot check: validation confirms the words were typed correctly, not
   that they were generated. Casually invented phrases do get rejected -- the
   checksum is 8 bits, so 255 of 256 arbitrary selections fail -- but that is
   typo detection doing it, not an entropy test. A determined user can pick 23
   words and search the 2048 for the 8 that complete a valid phrase, and any
   checksum-valid phrase from a weak source passes untouched. Reuse is the
   other half: anyone who learns a few (address, true location) pairs is doing
   cryptanalysis against whatever else that phrase protects. So the provenance
   warning sits directly under the generate button, where the choice is
   actually made, and is permanent and not dismissible.

   Nothing typed here is persisted. No localStorage, no URL, no request. The
   phrase goes straight to the worker, which keeps the derived key and returns
   only whether it worked. */

import { ChevronRight, Dices, Eye, EyeOff } from "lucide-react";
import { type FormEvent, useEffect, useRef, useState } from "react";
import { Button, Disclosure, DisclosurePanel } from "react-aria-components";
import { useBackendDown } from "../core/health";
import {
  useGeneratePhrase,
  useUnlock,
  useValidatePhrase,
} from "../core/queries";
import { sayRefusal } from "../core/refusal";
import { m } from "../paraglide/messages";
import { useAppStore } from "../store";
import { toastError } from "../toast";
import { IconButton } from "./IconButton";
import { LanguagePicker } from "./LanguagePicker";
import { loadMapView } from "./mapChunk";

const wordsIn = (phrase: string) => phrase.trim().split(/\s+/).filter(Boolean);

export function PhraseEntry() {
  const [phrase, setPhrase] = useState("");
  const [passphrase, setPassphrase] = useState("");
  /* Held so the "write this down" notice disappears once the user edits the
     words, rather than lingering over a phrase we did not generate. */
  const [generated, setGenerated] = useState<string | null>(null);
  /* Masked by default, because this is the highest-value secret the
     application handles and it is typed on whatever screen the user happens
     to be in front of. Revealed on demand -- 24 words cannot be proofread
     through bullets -- and revealed automatically when the phrase was
     GENERATED, since the next thing that screen asks is that you write it
     down, and a screenful of dots cannot be written down. */
  const [shown, setShown] = useState(false);
  const input = useRef<HTMLInputElement>(null);

  const setUnlocked = useAppStore((s) => s.setUnlocked);
  const generate = useGeneratePhrase();
  const unlock = useUnlock();

  /* Checksum feedback as you type: wordlist and checksum only, so it is
     instant. The expensive derivation happens on submit. A phrase that fails
     its checksum is almost always one mistyped word, and saying so before a
     400 ms derivation is worth the round trip. */
  const validation = useValidatePhrase(phrase);
  const validationError = validation.data?.error ?? null;

  useEffect(() => {
    input.current?.focus();
  }, []);

  const wordCount = wordsIn(phrase).length;
  const ready = wordCount === 24 && validationError === null
    && validation.isSuccess;

  /* Start the map download here rather than on submit. A checksum-valid
     phrase is the last thing that happens before someone unlocks, and the
     unlock itself is Argon2id over 64 MB -- far longer than this fetch -- so
     the chunk is normally in the browser before the map is asked for. Doing
     it on submit would work too and start later; doing it on mount would
     charge every visitor who reads this screen and leaves.

     No cleanup and no cancellation: a download in flight is the outcome this
     wants, and an unmount here means the gate opened. The rejection is
     swallowed because a failure has no consequence at this point -- nothing
     is waiting on it -- and `lazy` will ask again, and surface it properly,
     when the map actually mounts. */
  useEffect(() => {
    if (ready) void loadMapView().catch(() => {});
  }, [ready]);

  /* The bytes are drawn in the worker, by the platform CSPRNG, and only the
     words come back. Offered prominently because the alternative -- a phrase
     a person composed, or one already in use elsewhere -- is worth a tiny
     fraction of the guessing effort and is indistinguishable from this one
     once it satisfies the checksum. It is the one weakness a user can
     introduce that no amount of work elsewhere repairs. */
  function onGenerate() {
    generate.mutate(undefined, {
      onSuccess: ({ mnemonic }) => {
        setPhrase(mnemonic);
        setGenerated(mnemonic);
        /* The screen is about to say "write these down". It has to show
           them to be able to ask that. */
        setShown(true);
        input.current?.focus();
      },
      onError: () => toastError(m.gate_generate_failed()),
    });
  }

  /* Unlocking derives the key in a worker against argon2.wasm, which the
     SERVER supplies -- so with no server it fails, and "Could not open the
     map" then blames a phrase that is perfectly good. Say which it is. */
  const serverDown = useBackendDown();
  const unlockFailed = () =>
    serverDown ? m.banner_backend_down() : m.gate_unlock_failed();

  function submit(event: FormEvent) {
    event.preventDefault();
    if (!ready || unlock.isPending) return;
    unlock.mutate(
      { mnemonic: phrase, passphrase },
      {
        onSuccess: (result) => {
          if (!result.ok) {
            toastError(
              result.error
                ? sayRefusal(result.error)
                : unlockFailed(),
            );
            return;
          }
          /* Drop the phrase from component state the moment it is no longer
             needed. React state is reachable from the page; the worker's copy
             is not. */
          setPhrase("");
          setPassphrase("");
          setGenerated(null);
          setUnlocked();
        },
        onError: () => toastError(unlockFailed()),
      },
    );
  }

  const showWriteDown = generated !== null && phrase === generated;

  return (
    <div className="gate grid min-h-full place-items-center p-3 sm:p-6">
      <form
        className="gate-card flex w-[min(35rem,100%)] flex-col gap-3 rounded-xl border border-line bg-card p-7 shadow-card"
        onSubmit={submit}
      >
        <h1 className="text-2xl font-bold tracking-tight">{m.app_name()}</h1>
        <p className="mb-1.5 leading-normal text-ink-soft">{m.gate_lede()}</p>

        <label htmlFor="phrase" className="text-sm font-semibold">
          {m.gate_phrase_label()}
        </label>
        {
          /* A real password field, in a real form, with a real
            `autocomplete` -- which is what a password manager needs before
            it will offer to save anything. It was a textarea with
            autocomplete off, and the browser did as it was told: nothing
            ever offered to remember the one string that cannot be
            recovered if it is lost.

            The cost is that 24 words no longer wrap. The reveal toggle and
            the word count beside it are what replace reading them back, and
            a generated phrase reveals itself so it can be written down.

            Note what this does NOT change: the phrase still goes straight
            to the worker and this application still stores nothing. What is
            new is that the BROWSER may now be asked to keep it, by the
            person using it, in the place they already keep secrets. */
        }
        <div className="flex items-start gap-2">
          <input
            id="phrase"
            className="field font-mono"
            ref={input}
            type={shown ? "text" : "password"}
            name="phrase"
            autoComplete="current-password"
            spellCheck={false}
            autoCorrect="off"
            autoCapitalize="off"
            /* A generated phrase arrives a moment after the click and
               replaces whatever is in this field. Read-only for that moment,
               so it can never replace something the user typed in the
               meantime. Read-only rather than disabled: focus and selection
               survive. */
            readOnly={generate.isPending}
            aria-invalid={wordCount > 0 && validationError !== null}
            aria-describedby="phrase-status"
            placeholder={m.gate_phrase_placeholder()}
            value={phrase}
            onChange={(e) => setPhrase(e.target.value)}
          />
          <IconButton
            className="gate-phrase-toggle"
            label={shown ? m.gate_phrase_hide() : m.gate_phrase_show()}
            pressed={shown}
            onClick={() => setShown((v) => !v)}
            /* Crossed-out means hidden, matching the panel's own eyes:
               these show the state, not the action the press would take. */
            icon={shown
              ? <Eye size={18} aria-hidden />
              : <EyeOff size={18} aria-hidden />}
          />
        </div>

        {
          /* Inline and beside the field, not a toast: this is live validation
            of what is being typed, and it has to stay on screen while the user
            fixes it. Toasts are for the submit. */
        }
        <div
          className="phrase-status flex min-h-5 flex-wrap items-baseline gap-3 text-sm"
          id="phrase-status"
          role="status"
        >
          <span
            className={`count tabular-nums ${
              wordCount === 24 ? "text-ok" : "text-ink-soft"
            }`}
          >
            {m.gate_word_count({ count: wordCount })}
          </span>
          {validationError && wordCount > 0 && (
            <span className="invalid text-danger">
              {sayRefusal(validationError)}
            </span>
          )}
          {ready && (
            <span className="valid font-semibold text-ok">
              {m.gate_checksum_valid()}
            </span>
          )}
        </div>

        {
          /* Secondary weight: this sits above "Open my map", which is the
            primary action, but it must still read as an offer rather than as
            fine print. Full width on a phone, where a button that is not is
            just a small target. */
        }
        <div className="generate flex max-sm:w-full flex-col items-start gap-1.5">
          <button
            type="button"
            className="btn btn-quiet max-sm:w-full"
            onClick={onGenerate}
            disabled={generate.isPending}
            /* The hint describes what this button does, so a screen reader
               should read it with the button rather than leave it as loose
               text a keyboard user tabs straight past. */
            aria-describedby="generate-hint"
          >
            <Dices size={17} aria-hidden />
            {m.gate_generate()}
          </button>
          <span className="hint" id="generate-hint">
            {m.gate_generate_hint()}
          </span>
        </div>

        {
          /* Directly under the generate control rather than at the foot of
             the form: this is guidance for a choice being made right here,
             and at the bottom it was read after the decision, if at all.
             No role: it is present from first paint and never changes, so a
             live region would be wrong -- the write-down notice below is the
             one that appears, and the one that announces. The `provenance`
             class is a test hook, so the end-to-end position check can find
             this block without matching on copy. */
        }
        <div className="warning provenance">
          <strong>{m.gate_phrase_warning_title()}</strong>{" "}
          {m.gate_phrase_warning_body()}
        </div>

        {showWriteDown && (
          <div className="warning" role="status">
            <strong>{m.gate_write_down_title()}</strong>{" "}
            {m.gate_write_down_body()}
          </div>
        )}

        {
          /* A `summary` came with a marker triangle the browser drew; this is
            a button, so the chevron is ours and turns. */
        }
        <Disclosure className="passphrase group">
          <Button
            slot="trigger"
            className="passphrase-summary focus-ring flex w-full cursor-pointer items-center gap-1.5 py-1 text-left text-sm font-semibold"
          >
            <ChevronRight
              size={14}
              aria-hidden="true"
              className="flex-none text-ink-soft transition-transform group-expanded:rotate-90"
            />
            {m.gate_passphrase_summary()}
          </Button>
          <DisclosurePanel>
            <p className="hint">{m.gate_passphrase_what()}</p>
            <p className="hint">{m.gate_passphrase_exact()}</p>
            <p className="hint">{m.gate_passphrase_empty()}</p>
            <label
              htmlFor="passphrase"
              className="mb-1 block text-sm font-semibold"
            >
              {m.gate_passphrase_label()}
            </label>
            <input
              id="passphrase"
              className="field font-mono"
              type="password"
              autoComplete="off"
              value={passphrase}
              onChange={(e) => setPassphrase(e.target.value)}
            />
          </DisclosurePanel>
        </Disclosure>

        <button
          type="submit"
          className="btn btn-primary"
          disabled={!ready || unlock.isPending}
        >
          {unlock.isPending ? m.gate_submit_busy() : m.gate_submit()}
        </button>
        {unlock.isPending && <p className="hint">{m.gate_deriving_hint()}</p>}

        {
          /* The wordlist is English BIP-39 in every language: a French reader
            still types English words, and being told that up front is kinder
            than discovering it against a validation error. */
        }
        <p className="text-xs leading-normal text-ink-soft">
          {m.gate_wordlist_note()}
        </p>
        <p className="text-xs leading-normal text-ink-soft">
          {m.gate_fineprint()}
        </p>

        <LanguagePicker className="mt-1" />
      </form>
    </div>
  );
}
