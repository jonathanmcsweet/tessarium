import { PanelRightOpen } from "lucide-react";
import { type CSSProperties, lazy, Suspense } from "react";
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
  /* Subscribed to here, and read nowhere, on purpose.

     Paraglide's messages are plain functions that read the current locale when
     they are called. Changing language therefore changes nothing on screen
     until something re-renders, and nothing would: no component's props or
     state have changed. Subscribing at the root re-renders this tree, and none
     of these children is memoised, so all of them pick up the new strings.

     If a child is ever wrapped in `memo`, it needs its own subscription, and
     the end-to-end language check is what will say so. */
  useAppStore((s) => s.locale);

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
        /* A missing basemap affects the whole application rather than any one
          action, and it stays true until someone downloads tiles, so it is a
          banner and not a toast.

          Suppressed while the server is unreachable, though: of course there
          is no basemap when nothing is answering, and a Download maps button
          that cannot work is worse than saying nothing. One banner, naming
          the cause rather than a symptom of it. */
      }
      {basemapFailed && !serverDown && (
        <Banner
          message={m.map_basemap_missing()}
          action={{ label: m.banner_basemap_action(), onClick: openDownload }}
        />
      )}
      {
        /* Two widths, and they are not the same thing. --panel-w is the
          drawer's own width, kept while it is shut so reopening returns what
          was dragged to. --panel-offset is how much of the RIGHT EDGE is
          covered, which is zero while it is shut -- it is what MapLibre's
          own controls and attribution keep clear of, so none of them ends up
          underneath the drawer. */
      }
      <div
        className="app relative h-full min-h-0 flex-1 overflow-hidden"
        style={{
          "--panel-w": `${panelWidth}px`,
          "--panel-offset": panelCollapsed ? "0px" : `${panelWidth}px`,
        } as CSSProperties}
      >
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
        {!panelCollapsed && <PanelResizer />}
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
