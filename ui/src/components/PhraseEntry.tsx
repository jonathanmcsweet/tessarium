/* Seed phrase entry.

   The warnings here are not boilerplate. Where the phrase came from is the
   highest-value security decision in the application, and the one thing this
   code cannot check: validation confirms the words were typed correctly, not
   that they were generated. Casually invented phrases mostly get rejected --
   the checksum is 8 bits, so 255 of 256 arbitrary selections fail -- but
   that is typo detection, not an entropy test. Anyone can pick 23 words and
   search the 2048 for one that completes a valid phrase, and a
   checksum-valid phrase from a weak source passes untouched. Reuse is the
   other half: anyone who learns a few (address, true location) pairs is
   doing cryptanalysis against whatever else that phrase protects. So the
   provenance warning rides the generate button, in an info icon beside it,
   where the choice is made -- and it is permanent, in the sense that the
   icon is: it is never dismissed and never conditional, and the sentence is
   the icon's accessible name whether or not the tooltip is open.

   Nothing typed here is persisted -- no localStorage, no URL, no request.
   The phrase goes straight to the worker, which keeps the derived key and
   returns only whether it worked. */

import { Dices, Eye, EyeOff } from "lucide-react";
import { type FormEvent, useEffect, useRef, useState } from "react";
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
import { CopyButton } from "./CopyButton";
import { IconButton } from "./IconButton";
import { LanguagePicker } from "./LanguagePicker";
import { loadMapView } from "./mapChunk";
import { ThemePicker } from "./ThemePicker";
import { InfoTip } from "./Tip";

const wordsIn = (phrase: string) => phrase.trim().split(/\s+/).filter(Boolean);

export function PhraseEntry() {
  const [phrase, setPhrase] = useState("");
  /* Held so the "write this down" notice disappears once the user edits the
     words, rather than lingering over a phrase we did not generate. */
  const [generated, setGenerated] = useState<string | null>(null);
  /* Masked by default: this is the highest-value secret the application
     handles, typed on whatever screen the user is in front of. Revealed on
     demand, because 24 words cannot be proofread through bullets, and
     revealed automatically for a GENERATED phrase, because the next thing
     the screen asks is that you write it down. */
  const [shown, setShown] = useState(false);
  const input = useRef<HTMLInputElement>(null);

  const setUnlocked = useAppStore((s) => s.setUnlocked);
  const generate = useGeneratePhrase();
  const unlock = useUnlock();

  /* Feedback as you type: wordlist and checksum only, so it is instant. The
     expensive derivation happens on submit. A phrase that fails its checksum
     is almost always one mistyped word, and saying so before a 400 ms
     derivation is worth the round trip. */
  const validation = useValidatePhrase(phrase);
  const validationError = validation.data?.error ?? null;

  useEffect(() => {
    input.current?.focus();
  }, []);

  const wordCount = wordsIn(phrase).length;
  const ready = wordCount === 24 && validationError === null
    && validation.isSuccess;

  /* Start the map download here rather than on submit. A checksum-valid
     phrase is the last thing before an unlock, and the unlock is Argon2id
     over 64 MB -- far longer than this fetch -- so the chunk is normally in
     the browser before the map is asked for. On submit would start later; on
     mount would charge every visitor who reads this screen and leaves.

     No cleanup and no cancellation: a download in flight is what this wants,
     and an unmount here means the gate opened. The rejection is swallowed
     because nothing is waiting on it, and `lazy` asks again -- and surfaces
     the failure properly -- when the map mounts. */
  useEffect(() => {
    if (ready) void loadMapView().catch(() => {});
  }, [ready]);

  /* The bytes are drawn in the worker by the platform CSPRNG; only the
     words come back. Offered prominently because the alternative -- a phrase
     a person composed, or one already used elsewhere -- costs a tiny
     fraction of the guessing effort and looks identical once it satisfies
     the checksum. It is the one weakness no amount of work elsewhere
     repairs. */
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
     map" blames a phrase that is perfectly good. */
  const serverDown = useBackendDown();
  const unlockFailed = () =>
    serverDown ? m.banner_backend_down() : m.gate_unlock_failed();

  function submit(event: FormEvent) {
    event.preventDefault();
    if (!ready || unlock.isPending) return;
    unlock.mutate(
      { mnemonic: phrase },
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
        className="gate-card flex w-[min(35rem,100%)] flex-col gap-3 border border-line bg-card p-7 shadow-card"
        onSubmit={submit}
      >
        <h1 className="brand text-2xl">{m.app_name()}</h1>
        <p className="mb-1.5 leading-normal text-ink-soft">{m.gate_lede()}</p>

        <label htmlFor="phrase" className="text-sm font-semibold">
          {m.gate_phrase_label()}
        </label>
        {
          /* A real password field, in a real form, with a real
            `autocomplete` -- which is what a password manager needs before
            it offers to save anything. It was a textarea with autocomplete
            off, and the browser did as it was told: nothing ever offered to
            remember the one string that cannot be recovered if lost.

            The cost is that 24 words no longer wrap. The reveal toggle and
            the word count replace reading them back, and a generated phrase
            reveals itself so it can be written down.

            This does NOT change where the phrase goes: straight to the
            worker, with this application storing nothing. What is new is
            that the BROWSER may be asked to keep it, by the person using
            it. */
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
          {
            /* For the password vault the warning below asks for. The same
              button the address uses, so the tick that confirms the clipboard
              took it appears in the same place, in the same green, in both.

              Disabled until the phrase is whole: copying six words saves
              nothing, and a clipboard holding half a secret is worse than an
              empty one. Disabled rather than hidden, so the row does not
              change width on the last word typed. */
          }
          <CopyButton
            className="gate-phrase-copy"
            label={m.gate_phrase_copy()}
            copiedLabel={m.gate_phrase_copied()}
            text={() => phrase}
            onFailure={m.gate_phrase_copy_failed()}
            disabled={wordCount !== 24}
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
            fine print. On a phone it takes the row less the info icon, where
            a button that does not is just a small target. */
        }
        <div className="generate flex items-center">
          <button
            type="button"
            className="btn btn-quiet max-sm:grow"
            onClick={onGenerate}
            disabled={generate.isPending}
          >
            <Dices size={17} aria-hidden />
            {m.gate_generate()}
          </button>
          {
            /* Beside the control it is guidance for, not at the foot of the
              form where it was read after the decision if at all. A tooltip
              hides a sentence from anyone who does not reach for it, which
              is the cost paid here for the row of boxes this screen had
              become; what keeps it honest is that the sentence is the
              icon's accessible name at all times, so it is announced
              whether or not the tooltip is ever opened. */
          }
          <InfoTip label={m.gate_phrase_warning()} />
        </div>

        {showWriteDown && (
          <div className="warning" role="status">
            <strong>{m.gate_write_down_title()}</strong>{" "}
            {m.gate_write_down_body()}
          </div>
        )}

        <button
          type="submit"
          className="btn btn-primary"
          disabled={!ready || unlock.isPending}
        >
          {unlock.isPending ? m.gate_submit_busy() : m.gate_submit()}
        </button>
        {unlock.isPending && <p className="hint">{m.gate_deriving_hint()}</p>}

        {
          /* The two choices someone stuck on this screen may need: the
             language, for a reader who cannot read this one, and the theme,
             for a room the device's own guess is wrong about. Wrapping,
             because on a narrow phone in a language with long names they do
             not fit on one line. */
        }
        <div className="mt-1 flex flex-wrap items-center gap-x-4 gap-y-2">
          <LanguagePicker />
          <ThemePicker labelHidden />
        </div>
      </form>
    </div>
  );
}
