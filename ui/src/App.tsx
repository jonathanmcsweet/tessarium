import { useState, useMemo, useCallback } from "react";
import { Core } from "./core/client";
import { PhraseEntry } from "./components/PhraseEntry";
import { MapView, type Selection } from "./components/MapView";
import { AddressPanel } from "./components/AddressPanel";

export function App() {
  /* One worker for the life of the tab. Reconstructing it would mean
     re-running PBKDF2, and it holds the key, so its lifetime is the session's
     lifetime. */
  const core = useMemo(() => new Core(), []);

  const [unlocked, setUnlocked] = useState(false);
  const [selection, setSelection] = useState<Selection | null>(null);
  const [flyTo, setFlyTo] = useState<{
    lat: number;
    lon: number;
    nonce: number;
  } | null>(null);

  const onFound = useCallback((lat: number, lon: number) => {
    /* The nonce makes looking up the same address twice fly there twice.
       Without it the second lookup changes nothing and reads as broken. */
    setFlyTo({ lat, lon, nonce: Date.now() });
  }, []);

  const onLock = useCallback(() => {
    void core.lock();
    setUnlocked(false);
    setSelection(null);
    setFlyTo(null);
  }, [core]);

  if (!unlocked) {
    return <PhraseEntry core={core} onUnlocked={() => setUnlocked(true)} />;
  }

  return (
    <div className="app">
      <MapView
        core={core}
        selection={selection}
        onSelect={setSelection}
        flyTo={flyTo}
      />
      <AddressPanel
        core={core}
        selection={selection}
        onFound={onFound}
        onLock={onLock}
      />
    </div>
  );
}
