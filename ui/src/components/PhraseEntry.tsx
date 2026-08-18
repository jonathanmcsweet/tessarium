/* Seed phrase entry.

   The warnings here are not boilerplate. Anyone who learns a few (address,
   true location) pairs is doing cryptanalysis against this key; if the same
   key also holds funds, two unrelated risks have been combined for no reason.
   So the wallet-reuse warning is permanent and not dismissible.

   Nothing typed here is persisted. No localStorage, no URL, no request. The
   phrase goes straight to the worker, which keeps the derived key and returns
   only whether it worked. */

import { Dices } from "lucide-react";
import { type FormEvent, useEffect, useRef, useState } from "react";
import {
  useGeneratePhrase,
  useUnlock,
  useValidatePhrase,
} from "../core/queries";
import { m } from "../paraglide/messages";
import { useAppStore } from "../store";
import { toastError } from "../toast";
import { LanguagePicker } from "./LanguagePicker";

const wordsIn = (phrase: string) => phrase.trim().split(/\s+/).filter(Boolean);

export function PhraseEntry() {
  const [phrase, setPhrase] = useState("");
  const [passphrase, setPassphrase] = useState("");
  /* Held so the "write this down" notice disappears once the user edits the
     words, rather than lingering over a phrase we did not generate. */
  const [generated, setGenerated] = useState<string | null>(null);
  const input = useRef<HTMLTextAreaElement>(null);

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

  /* The bytes are drawn in the worker, by the platform CSPRNG, and only the
     words come back. Offered prominently because the alternative -- a person
     choosing 24 words that mean something to them -- produces a phrase that
     passes every check this app makes and is worth a tiny fraction of the
     guessing effort. It is the one weakness a user can introduce that no
     amount of work elsewhere repairs. */
  function onGenerate() {
    generate.mutate(undefined, {
      onSuccess: ({ mnemonic }) => {
        setPhrase(mnemonic);
        setGenerated(mnemonic);
        input.current?.focus();
      },
      onError: () => toastError(m.gate_generate_failed()),
    });
  }

  function submit(event: FormEvent) {
    event.preventDefault();
    if (!ready || unlock.isPending) return;
    unlock.mutate(
      { mnemonic: phrase, passphrase },
      {
        onSuccess: (result) => {
          if (!result.ok) {
            toastError(result.error ?? m.gate_unlock_failed());
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
        onError: () => toastError(m.gate_unlock_failed()),
      },
    );
  }

  const showWriteDown = generated !== null && phrase === generated;

  return (
    <div className="gate">
      <form className="gate-card" onSubmit={submit}>
        <h1>{m.app_name()}</h1>
        <p className="lede">{m.gate_lede()}</p>

        <label htmlFor="phrase">{m.gate_phrase_label()}</label>
        <textarea
          id="phrase"
          ref={input}
          rows={4}
          spellCheck={false}
          autoComplete="off"
          autoCorrect="off"
          autoCapitalize="off"
          /* A generated phrase arrives a moment after the click and replaces
             whatever is in this field. Read-only for that moment, so it can
             never replace something the user typed in the meantime.
             Read-only rather than disabled: focus and selection survive. */
          readOnly={generate.isPending}
          aria-invalid={wordCount > 0 && validationError !== null}
          aria-describedby="phrase-status"
          placeholder={m.gate_phrase_placeholder()}
          value={phrase}
          onChange={(e) => setPhrase(e.target.value)}
        />

        {
          /* Inline and beside the field, not a toast: this is live validation
            of what is being typed, and it has to stay on screen while the user
            fixes it. Toasts are for the submit. */
        }
        <div className="phrase-status" id="phrase-status" role="status">
          <span className={wordCount === 24 ? "count ok" : "count"}>
            {m.gate_word_count({ count: wordCount })}
          </span>
          {validationError && wordCount > 0 && (
            <span className="invalid">{validationError}</span>
          )}
          {ready && <span className="valid">{m.gate_checksum_valid()}</span>}
        </div>

        <div className="generate">
          <button
            type="button"
            onClick={onGenerate}
            disabled={generate.isPending}
          >
            <Dices size={17} aria-hidden />
            {m.gate_generate()}
          </button>
          <span className="hint">{m.gate_generate_hint()}</span>
        </div>

        {showWriteDown && (
          <div className="warning" role="status">
            <strong>{m.gate_write_down_title()}</strong>{" "}
            {m.gate_write_down_body()}
          </div>
        )}

        <details className="passphrase">
          <summary>{m.gate_passphrase_summary()}</summary>
          <p className="hint">{m.gate_passphrase_what()}</p>
          <p className="hint">{m.gate_passphrase_exact()}</p>
          <p className="hint">{m.gate_passphrase_empty()}</p>
          <label htmlFor="passphrase">{m.gate_passphrase_label()}</label>
          <input
            id="passphrase"
            type="password"
            autoComplete="off"
            value={passphrase}
            onChange={(e) => setPassphrase(e.target.value)}
          />
        </details>

        <button type="submit" disabled={!ready || unlock.isPending}>
          {unlock.isPending ? m.gate_submit_busy() : m.gate_submit()}
        </button>
        {unlock.isPending && <p className="hint">{m.gate_deriving_hint()}</p>}

        <div className="warning">
          <strong>{m.gate_wallet_warning_title()}</strong>{" "}
          {m.gate_wallet_warning_body()}
        </div>

        {
          /* The wordlist is English BIP-39 in every language: a French reader
            still types English words, and being told that up front is kinder
            than discovering it against a validation error. */
        }
        <p className="fineprint">{m.gate_wordlist_note()}</p>
        <p className="fineprint">{m.gate_fineprint()}</p>

        <LanguagePicker className="gate-language" />
      </form>
    </div>
  );
}
