import { PanelRightOpen } from "lucide-react";
import { type CSSProperties, lazy, Suspense, useRef } from "react";
import { AddressPanel } from "./components/AddressPanel";
import { Banner } from "./components/Banner";
import { IconButton } from "./components/IconButton";
import { loadMapView } from "./components/mapChunk";
import { PanelResizer } from "./components/PanelResizer";
import { PhraseEntry } from "./components/PhraseEntry";
import { useBackendDown } from "./core/health";
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
  const panelWidth = useAppStore((s) => s.panelWidth);
  const panelCollapsed = useAppStore((s) => s.panelCollapsed);
  const togglePanel = useAppStore((s) => s.togglePanel);
  /* Subscribed to here and read nowhere, on purpose.

     Paraglide's messages are plain functions that read the locale when they
     are called, so changing language changes nothing on screen until
     something re-renders -- and nothing otherwise would. Subscribing at the
     root re-renders this tree, and none of these children is memoised.

     A child wrapped in `memo` would need its own subscription; the
     end-to-end language check is what would say so. */
  useAppStore((s) => s.locale);

  /* Handed to the splitter so a drag can write the two widths below
     straight onto this element. Every pointermove used to go through the
     store, and because of the subscription above, each one rebuilt this
     tree -- the map's whole body and the panel -- to move two custom
     properties. The drag paints; the store hears the answer once. */
  const surface = useRef<HTMLDivElement>(null);

  /* The gate is where a missing server hurts most: the phrase validates, the
     checksum goes green, and unlocking then fails with a message that blames
     the phrase. So this banner has to sit ABOVE the gate as well as inside
     the shell, which is why it is built here and rendered in both returns. */
  const serverDown = useBackendDown();
  const serverBanner = serverDown
    ? <Banner message={m.banner_backend_down()} />
    : null;

  if (!unlocked) {
    return (
      <>
        {serverBanner}
        <PhraseEntry />
      </>
    );
  }

  return (
    <div className="shell flex h-full min-h-0 flex-col">
      {serverBanner}
      {
        /* A missing basemap affects the whole application and stays true
          until someone downloads tiles, so it is a banner rather than a
          toast.

          Suppressed while the server is unreachable: nothing is answering,
          so of course there is no basemap, and a Download maps button that
          cannot work says less than nothing. One banner, naming the cause
          rather than a symptom. */
      }
      {basemapFailed && !serverDown && (
        <Banner
          message={m.map_basemap_missing()}
          action={{ label: m.banner_basemap_action(), onClick: openDownload }}
        />
      )}
      {
        /* The two facts this component has: how wide the panel is, and
          whether it is showing. --panel-w is kept while it is shut, so
          reopening returns what was dragged to.

          What each EDGE of the map has under it is derived from these two in
          styles.css, where the breakpoint is -- below it the panel is a
          sheet across the bottom and covers no side at all. */
      }
      <div
        ref={surface}
        className="app relative h-full min-h-0 flex-1 overflow-hidden"
        style={{
          "--panel-w": `${panelWidth}px`,
          "--panel-open": panelCollapsed ? "0" : "1",
        } as CSSProperties}
      >
        {
          /* The gap between the gate opening and the map engine arriving.
            Rarely seen -- PhraseEntry starts that download when the phrase
            validates -- but real on a cold cache and a slow link, and an
            empty cell beside a populated panel reads as a broken map. NOT
            `.map-wrap`, which means the real map is mounted and is what the
            end-to-end test waits on; not `.map-loading` either, which is
            MapView's own shimmer bar for late tiles. */
        }
        <Suspense
          fallback={
            <div
              className="map-pending flex h-full items-center justify-center bg-bg text-ink-soft"
              role="status"
            >
              {m.map_loading()}
            </div>
          }
        >
          <MapView />
        </Suspense>
        {!panelCollapsed && <PanelResizer surface={surface} />}
        <AddressPanel />
        {
          /* The way back in. The drawer's own hide button leaves with it, so
            the control that reopens it has to live outside the drawer --
            over the map, at the edge the drawer just gave back. */
        }
        {panelCollapsed && (
          <div className="panel-reopen absolute top-3.5 right-2.5 z-6">
            <IconButton
              label={m.panel_show()}
              icon={<PanelRightOpen size={18} aria-hidden />}
              onClick={togglePanel}
              /* It floats over the map rather than sitting on the panel, so
                 unlike every other icon button it needs a ground of its
                 own. */
              className="bg-card shadow-card"
            />
          </div>
        )}
      </div>
    </div>
  );
}
