/* Seed phrase entry.

   The warnings here are not boilerplate. Anyone who learns a few (address,
   true location) pairs is doing cryptanalysis against this key; if the same
   key also holds funds, two unrelated risks have been combined for no reason.
   So the wallet-reuse warning is permanent and not dismissible.

   Nothing typed here is persisted. No localStorage, no URL, no request. The
   phrase goes straight to the worker, which keeps the derived key and returns
   only whether it worked. */

import { useState, useEffect, useRef } from "react";
import type { Core } from "../core/client";

type Props = {
  core: Core;
  onUnlocked: () => void;
};

export function PhraseEntry({ core, onUnlocked }: Props) {
  const [phrase, setPhrase] = useState("");
  const [passphrase, setPassphrase] = useState("");
  const [validation, setValidation] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const input = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    input.current?.focus();
  }, []);

  /* Checksum feedback as you type. This is wordlist and checksum only, so it
     is instant -- the expensive derivation happens on submit. A phrase that
     fails its checksum is almost always one mistyped word, and saying so
     before a 400 ms derivation is worth the round trip. */
  useEffect(() => {
    const words = phrase.trim().split(/\s+/).filter(Boolean);
    if (words.length === 0) {
      setValidation(null);
      return;
    }
    let cancelled = false;
    core.validate(phrase).then((r) => {
      if (!cancelled) setValidation(r.error);
    });
    return () => {
      cancelled = true;
    };
  }, [phrase, core]);

  const wordCount = phrase.trim().split(/\s+/).filter(Boolean).length;
  const ready = validation === null && wordCount === 24;

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (!ready || busy) return;
    setBusy(true);
    setFailure(null);
    const result = await core.unlock(phrase, passphrase);
    if (result.ok) {
      /* Drop the phrase from component state the moment it is no longer
         needed. React state is reachable from the page; the worker's copy is
         not. */
      setPhrase("");
      setPassphrase("");
      onUnlocked();
    } else {
      setFailure(result.error);
    }
    setBusy(false);
  }

  return (
    <div className="gate">
      <form className="gate-card" onSubmit={submit}>
        <h1>Tessarium</h1>
        <p className="lede">
          Three words and a number address every ~3 m square on Earth, under a
          map that belongs to your seed phrase alone.
        </p>

        <label htmlFor="phrase">Your 24-word seed phrase</label>
        <textarea
          id="phrase"
          ref={input}
          rows={4}
          spellCheck={false}
          autoComplete="off"
          autoCorrect="off"
          autoCapitalize="off"
          placeholder="abandon ability able about above absent…"
          value={phrase}
          onChange={(e) => setPhrase(e.target.value)}
        />

        <div className="phrase-status">
          <span className={wordCount === 24 ? "count ok" : "count"}>
            {wordCount}/24 words
          </span>
          {validation && wordCount > 0 && (
            <span className="invalid">{validation}</span>
          )}
          {ready && <span className="valid">checksum valid</span>}
        </div>

        <details className="passphrase">
          <summary>Optional passphrase</summary>
          <p className="hint">
            A BIP-39 passphrase. A different passphrase over the same words is
            a completely different map, not a variation on this one.
          </p>
          <input
            type="password"
            autoComplete="off"
            value={passphrase}
            onChange={(e) => setPassphrase(e.target.value)}
          />
        </details>

        <button type="submit" disabled={!ready || busy}>
          {busy ? "Deriving key…" : "Open my map"}
        </button>
        {busy && (
          <p className="hint">
            2048 rounds of PBKDF2. Slow on purpose, and only once per session.
          </p>
        )}
        {failure && <p className="invalid">{failure}</p>}

        <div className="warning">
          <strong>Use a fresh phrase, not a wallet seed.</strong> Anyone who
          learns a few of your addresses and where they actually are is doing
          cryptanalysis against this key. If it also holds funds, you have
          combined two unrelated risks for nothing.
        </div>

        <p className="fineprint">
          24 words only. A 12-word phrase carries 128 bits of entropy, which
          Grover's algorithm reduces to an effective 64. Your phrase is never
          stored, never put in the URL, and never sent anywhere — the key is
          derived here, in a worker, on this device.
        </p>
      </form>
    </div>
  );
}
