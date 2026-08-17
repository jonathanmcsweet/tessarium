import { AddressPanel } from "./components/AddressPanel";
import { Banner } from "./components/Banner";
import { MapView } from "./components/MapView";
import { PhraseEntry } from "./components/PhraseEntry";
import { m } from "./paraglide/messages";
import { useAppStore } from "./store";

export function App() {
  const unlocked = useAppStore((s) => s.unlocked);
  const basemapFailed = useAppStore((s) => s.basemapFailed);
  const openDownload = useAppStore((s) => s.openDownload);
  /* Subscribed to here, and read nowhere, on purpose.

     Paraglide's messages are plain functions that read the current locale when
     they are called. Changing language therefore changes nothing on screen
     until something re-renders, and nothing would: no component's props or
     state have changed. Subscribing at the root re-renders this tree, and none
     of these children is memoised, so all of them pick up the new strings.

     If a child is ever wrapped in `memo`, it needs its own subscription, and
     the end-to-end language check is what will say so. */
  useAppStore((s) => s.locale);

  if (!unlocked) return <PhraseEntry />;

  return (
    <div className="shell">
      {
        /* A missing basemap affects the whole application rather than any one
          action, and it stays true until someone downloads tiles, so it is a
          banner and not a toast. */
      }
      {basemapFailed && (
        <Banner
          message={m.map_basemap_missing()}
          action={{ label: m.banner_basemap_action(), onClick: openDownload }}
        />
      )}
      <div className="app">
        <MapView />
        <AddressPanel />
      </div>
    </div>
  );
}
