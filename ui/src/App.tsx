import { lazy, Suspense } from "react";
import { AddressPanel } from "./components/AddressPanel";
import { Banner } from "./components/Banner";
import { loadMapView } from "./components/mapChunk";
import { PhraseEntry } from "./components/PhraseEntry";
import { m } from "./paraglide/messages";
import { useAppStore } from "./store";

/* Not a static import: see components/mapChunk.ts. `lazy` wants a default
   export and MapView is a named one, so the promise is reshaped here rather
   than MapView growing a default export it has no other use for. */
const MapView = lazy(() =>
  loadMapView().then((mod) => ({ default: mod.MapView }))
);

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
        {
          /* The gap between the gate opening and the map engine arriving.
            Usually not seen -- PhraseEntry starts that download when the
            phrase validates, well before the key finishes deriving -- but on
            a cold cache and a slow link it is real, and an empty grid cell
            beside a populated panel reads as a broken map rather than a
            loading one. Deliberately NOT `.map-wrap`: that class means the
            real map is mounted, and the end-to-end test waits on it. And not
            `.map-loading` either, which is MapView's own shimmer bar for late
            tiles -- a different thing at a different moment. */
        }
        <Suspense
          fallback={
            <div className="map-pending" role="status">
              {m.map_loading()}
            </div>
          }
        >
          <MapView />
        </Suspense>
        <AddressPanel />
      </div>
    </div>
  );
}
