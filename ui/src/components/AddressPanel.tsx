/* The side panel: the address of the selected square, and a box to look one
   up. */

import { useState } from "react";
import type { Core } from "../core/client";
import type { Selection } from "./MapView";

type Props = {
  core: Core;
  selection: Selection | null;
  onFound: (lat: number, lon: number) => void;
  onLock: () => void;
};

export function AddressPanel({ core, selection, onFound, onLock }: Props) {
  const [query, setQuery] = useState("");
  const [lookupError, setLookupError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  async function copy() {
    if (!selection) return;
    try {
      await navigator.clipboard.writeText(selection.address);
      setCopied(true);
      setTimeout(() => setCopied(false), 1400);
    } catch {
      /* Clipboard access is refused in some contexts. The address is on
         screen and selectable, so this is a missing convenience rather than a
         failure worth an alert. */
      setCopied(false);
    }
  }

  async function lookup(event: React.FormEvent) {
    event.preventDefault();
    setLookupError(null);
    try {
      const { lat, lon } = await core.decode(query);
      onFound(lat, lon);
    } catch (e) {
      setLookupError(e instanceof Error ? e.message : String(e));
    }
  }

  return (
    <aside className="panel">
      <header className="panel-head">
        <span className="brand">Tessarium</span>
        <button className="lock" onClick={onLock} title="Forget the key">
          Lock
        </button>
      </header>

      <section className="selected">
        <h2>This square</h2>
        {selection ? (
          <>
            <output className="address">{selection.address}</output>
            <button className="copy" onClick={copy}>
              {copied ? "Copied" : "Copy address"}
            </button>
            <dl className="coords">
              <dt>Latitude</dt>
              <dd>{selection.cell.latLo.toFixed(7)}</dd>
              <dt>Longitude</dt>
              <dd>{selection.cell.lonLo.toFixed(7)}</dd>
            </dl>
          </>
        ) : (
          <p className="hint">
            Click any square on the map to see its address.
          </p>
        )}
      </section>

      <section className="lookup">
        <h2>Find an address</h2>
        <form onSubmit={lookup}>
          <input
            type="text"
            spellCheck={false}
            autoComplete="off"
            autoCapitalize="off"
            placeholder="dream.tourist.creek.2703"
            value={query}
            onChange={(e) => {
              setQuery(e.target.value);
              setLookupError(null);
            }}
          />
          <button type="submit" disabled={query.trim() === ""}>
            Go
          </button>
        </form>
        {lookupError && <p className="invalid">{lookupError}</p>}
        <p className="hint">
          Four-letter prefixes work, and separators are forgiving:
          <code> drea tour cree 2703</code> resolves the same way.
        </p>
      </section>

      <footer className="panel-foot">
        <p>
          Addresses are meaningless to anyone with a different seed phrase. The
          same square has an entirely unrelated address under every other
          phrase.
        </p>
      </footer>
    </aside>
  );
}
