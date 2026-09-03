/* The side panel: the address of the selected square.

   Looking an address UP happens in the map's search box, which takes both a
   place name and an address -- see PlaceSearch. The form that used to live
   here is gone rather than duplicated.

   This is the only place an address is ever displayed. The map draws bare
   squares, so a screenshot or a shared screen gives away one address at most
   -- and the eye toggle here takes that to none. */

import { Download, Eye, EyeOff, PanelRightClose } from "lucide-react";
import { lazy, Suspense } from "react";
import { useBasemapStatus } from "../core/basemap";
import { useCoreVersions, useLock } from "../core/queries";
import { formatCoord } from "../i18n";
import { m } from "../paraglide/messages";
import { useAppStore } from "../store";
import { CopyButton } from "./CopyButton";
import { loadDownloadCard } from "./downloadChunk";
import { IconButton } from "./IconButton";
import { LanguagePicker } from "./LanguagePicker";
import { LockDialog } from "./LockDialog";
import { MapProgress } from "./MapProgress";
import { SettingsMenu } from "./SettingsMenu";

/* Same shape as an address, so the panel does not change width when it is
   concealed and the layout does not jump on every toggle. */
const MASK = "••••••.••••••.••••••.••••";
/* And the same idea for a coordinate. */
const COORD_MASK = "••.•••••••";

/* The drawer sits OVER the map rather than beside it. As a grid column it
   took width away from the map, so every drag resized the map with it --
   MapLibre re-laid out, tiles re-rendered, and the view you were looking at
   moved under you. Overlaid, the map is the full width of the shell and stays
   exactly where it is whatever the drawer does. It casts a shadow on what it
   covers, which is what makes it read as a panel over the map rather than a
   pale stripe beside it.

   Below the drawer breakpoint it is a sheet across the bottom instead: there
   is no vertical edge to drag there, so PanelResizer hides itself and the
   width is the viewport's. --panel-w is set on the shell by App.tsx. */
const DRAWER =
  "absolute inset-y-0 right-0 z-5 flex w-[var(--panel-w,340px)] max-w-full "
  + "flex-col overflow-y-auto border-l border-line bg-card "
  + "shadow-[-10px_0_28px_rgb(15_23_42/0.14)] "
  + "transition-transform duration-200 ease-out "
  + "max-drawer:inset-x-0 max-drawer:top-auto max-drawer:bottom-0 "
  + "max-drawer:max-h-[45vh] max-drawer:w-auto max-drawer:border-t "
  + "max-drawer:border-l-0 "
  + "max-drawer:shadow-[0_-10px_28px_rgb(15_23_42/0.14)] "
  + "max-sm:max-h-[55vh]";

/* Shut, not zero-width: sliding it out keeps its contents laid out at their
   real width, so reopening does not reflow a squashed column back into shape.
   `invisible` is what takes it out of the tab order and off the screen
   reader's map -- a drawer someone can still tab into is worse than one that
   never closed. */
const SHUT = "collapsed invisible translate-x-full "
  + "max-drawer:translate-x-0 max-drawer:translate-y-full";

/* Not a static import: see components/downloadChunk.ts. `lazy` wants a
   default export and DownloadCard is a named one, so the promise is
   reshaped here rather than the card growing a default it has no other
   use for -- the same shape App uses for MapView. */
const DownloadCard = lazy(() =>
  loadDownloadCard().then((mod) => ({ default: mod.DownloadCard }))
);

export function AddressPanel() {
  const selection = useAppStore((s) => s.selection);
  const concealed = useAppStore((s) => s.concealed);
  const toggleConcealed = useAppStore((s) => s.toggleConcealed);
  const coordsConcealed = useAppStore((s) => s.coordsConcealed);
  const toggleCoordsConcealed = useAppStore((s) => s.toggleCoordsConcealed);
  const toggleAllConcealed = useAppStore((s) => s.toggleAllConcealed);
  const anyConcealed = concealed || coordsConcealed;
  const setLocked = useAppStore((s) => s.setLocked);

  const lock = useLock();
  const versions = useCoreVersions();

  /* The offline-maps card lives here rather than over the map. It used to
     float in the top-left corner, where it covered the very tiles it was
     about and had nowhere to grow; in the panel it can be as tall as it
     needs and the map stays whole. The button that opens it stays on the
     map, because that is where someone is looking when they notice a gap. */
  const downloadOpen = useAppStore((s) => s.downloadOpen);
  const openDownload = useAppStore((s) => s.openDownload);
  const closeDownload = useAppStore((s) => s.closeDownload);
  const togglePanel = useAppStore((s) => s.togglePanel);
  const panelCollapsed = useAppStore((s) => s.panelCollapsed);
  const downloadRegion = useAppStore((s) => s.downloadRegion);
  const basemapJob = useBasemapStatus();

  /* Same treatment as the address above, scaled to the smaller type: the
     bullets are not worth selecting, and a selection highlight through a
     blur reads as a rendering fault. */
  const coordClass = `m-0 font-mono tabular-nums${
    coordsConcealed ? " text-ink-soft blur-[2.5px] select-none" : ""
  }`;

  return (
    <aside className={`panel ${DRAWER} ${panelCollapsed ? SHUT : ""}`}>
      {
        /* Wraps, because it has to. With a square selected the row is five
          controls -- reveal, downloads, settings, lock, hide -- and at the
          drawer's default 340px they need more room than there is. The
          alternative was clipping one off the right edge, where nothing
          says it is there. The brand gives way first and the row drops to
          its own line only when shrinking is not enough. */
      }
      <header className="panel-head flex flex-wrap items-center justify-between gap-x-2 gap-y-1 border-b border-line px-4.5 py-3.5">
        <span className="brand min-w-0 shrink truncate">
          {m.app_name()}
        </span>
        <div className="ml-auto flex flex-wrap items-center justify-end gap-2">
          {
            /* One press for everything hidden in this panel. Only shown with
              a selection, because with nothing selected there is nothing
              hidden and a control that does nothing is worse than no
              control. */
          }
          {selection && (
            <IconButton
              label={anyConcealed ? m.panel_reveal_all() : m.panel_hide_all()}
              pressed={anyConcealed}
              onClick={toggleAllConcealed}
              /* Crossed-out means hidden, matching the two eyes below it --
                 they show state, not the action the press would take, and
                 one control reading the other way round in the same panel
                 is worse than either convention. */
              icon={anyConcealed
                ? <EyeOff size={18} aria-hidden />
                : <Eye size={18} aria-hidden />}
            />
          )}
          {
            /* The way in to the offline maps. It used to sit over the map's
              top-left corner, under the search box; it belongs with the
              thing it opens, which is now this panel. */
          }
          <IconButton
            className="panel-download"
            label={m.map_download_open()}
            icon={<Download size={18} aria-hidden />}
            pressed={downloadOpen}
            onClick={() => (downloadOpen ? closeDownload() : openDownload())}
          />
          <SettingsMenu />
          <LockDialog
            onConfirm={() => {
              lock.mutate();
              setLocked();
            }}
          />
          <IconButton
            className="panel-hide"
            label={m.panel_hide()}
            icon={<PanelRightClose size={18} aria-hidden />}
            onClick={togglePanel}
          />
        </div>
      </header>

      <section className="selected border-b border-line p-4.5">
        <h2 className="panel-title mb-2.5">{m.panel_this_square()}</h2>
        {selection
          ? (
            <>
              <div className="address-row flex items-start gap-1.5">
                {
                  /* Concealed means not rendered, not merely styled out of
                  sight. An address hidden with CSS is still in the page for
                  anything reading the DOM. */
                }
                {
                  /* The mask is meaningless read aloud, so while concealed
                    the accessible name says what it is instead of spelling
                    out twenty-five bullets. This used to be a visible note
                    below the row; that note existed for the address and not
                    for the coordinates, and it appeared and disappeared with
                    the toggle, which moved everything under it by 23 px on
                    every press. Same information, no layout in it. */
                }
                <output
                  className={`address block min-w-0 flex-1 font-mono text-lg font-semibold leading-snug break-words text-accent-alt ${
                    /* Muted rather than accented while concealed: hidden is
                       a resting state, not an alert. And it is worth being
                       exact about WHAT is blurred -- the mask. The address
                       is not in the document while it is concealed, so
                       there is nothing behind this to recover by selecting
                       the text, opening devtools, or sharpening a
                       screenshot. This is a picture of twenty-five
                       bullets. */
                    concealed
                      ? "tracking-wide text-ink-soft blur-[3.5px] select-none"
                      : "text-accent-text"}`}
                  aria-label={concealed ? m.panel_concealed() : undefined}
                >
                  {concealed ? MASK : selection.address}
                </output>
                <IconButton
                  label={concealed ? m.panel_reveal() : m.panel_conceal()}
                  pressed={concealed}
                  onClick={toggleConcealed}
                  icon={concealed
                    ? <EyeOff size={18} aria-hidden />
                    : <Eye size={18} aria-hidden />}
                />
                {
                  /* Copying works while concealed: putting an address on the
                  clipboard is not putting it on the screen. */
                }
                <CopyButton
                  label={m.panel_copy()}
                  copiedLabel={m.panel_copied()}
                  text={() => selection.address}
                  onFailure={m.panel_copy_failed()}
                />
              </div>
              {
                /* Coordinates name where someone is as plainly as the
                  address does, so they get the same treatment: hidden by
                  default, not rendered while hidden, copyable either way. */
              }
              <div className="coords-row mt-3 flex items-start gap-1.5">
                {
                  /* Named the same way as the address above, for the same
                    reason: "Latitude, bullet bullet bullet" is not an
                    answer.

                    NOT `aria-label` on the `dd`, which is what this was
                    first and is invalid -- a description-list value has no
                    role that takes a name, and the lint rule
                    useAriaPropsSupportedByRole is right to refuse it. A
                    hidden span carries the words and the mask is hidden
                    from the tree instead, which works on every element. */
                }
                <dl className="coords m-0 grid min-w-0 flex-1 grid-cols-[auto_1fr] gap-x-3 gap-y-0.5 text-sm">
                  <dt className="text-ink-soft">{m.panel_latitude()}</dt>
                  <dd className={coordClass}>
                    {coordsConcealed
                      ? (
                        <>
                          <span className="sr-only">
                            {m.panel_coords_concealed()}
                          </span>
                          <span aria-hidden>{COORD_MASK}</span>
                        </>
                      )
                      : formatCoord(selection.cell.latLo)}
                  </dd>
                  <dt className="text-ink-soft">{m.panel_longitude()}</dt>
                  <dd className={coordClass}>
                    {coordsConcealed
                      ? (
                        <>
                          <span className="sr-only">
                            {m.panel_coords_concealed()}
                          </span>
                          <span aria-hidden>{COORD_MASK}</span>
                        </>
                      )
                      : formatCoord(selection.cell.lonLo)}
                  </dd>
                </dl>
                <IconButton
                  label={coordsConcealed
                    ? m.panel_coords_reveal()
                    : m.panel_coords_conceal()}
                  pressed={coordsConcealed}
                  onClick={toggleCoordsConcealed}
                  icon={coordsConcealed
                    ? <EyeOff size={18} aria-hidden />
                    : <Eye size={18} aria-hidden />}
                />
                <CopyButton
                  label={m.panel_coords_copy()}
                  copiedLabel={m.panel_coords_copied()}
                  text={() =>
                    `${formatCoord(selection.cell.latLo)}, ${
                      formatCoord(selection.cell.lonLo)
                    }`}
                  onFailure={m.panel_coords_copy_failed()}
                />
              </div>
            </>
          )
          : <p className="hint">{m.panel_no_selection()}</p>}
      </section>

      {
        /* Below the address, above the footer: a download is background work
          and must not push the thing the user came here for off the top. */
      }
      <MapProgress />

      {downloadOpen && downloadRegion && (
        <Suspense
          fallback={
            <p
              className="download-pending border-t border-line p-4.5 text-sm text-ink-soft"
              role="status"
            >
              {m.map_download_loading()}
            </p>
          }
        >
          <DownloadCard region={downloadRegion} job={basemapJob.data?.job} />
        </Suspense>
      )}

      <footer className="panel-foot px-4.5 py-4 text-xs leading-normal text-ink-soft">
        <LanguagePicker className="mb-2.5" />
        {
          /* Standing, not a toast, and not only in the lock dialog: a reload
            forgets the key exactly as locking does, and a browser will not
            let a page say anything useful before one. So the one place this
            can be said in time is before it happens. */
        }
        {
          /* Quieter than the gate's warning -- this one is permanent, and a
            permanent alarm stops being one. */
        }
        <p className="warning phrase-note mb-2.5 text-xs">
          {m.panel_phrase_note()}
        </p>
        <p className="panel-explainer">{m.panel_footer()}</p>
        {
          /* Names and numbers: nothing to translate, so no message key.

            The grid and derivation versions ARE shown, which reverses the
            decision that used to sit here. An address is
            three words and four digits, with no room inside it for a version,
            so a code issued under an older grid is not refused -- it decodes
            to a different and entirely plausible square, and nothing on screen
            says why. Reported from use. Naming the epoch is the cheap half of
            the answer: it cannot make an old code work, but it lets someone
            label the codes they keep with the grid those codes belong to. */
        }
        <p className="versions mt-2.5 flex flex-wrap gap-x-2 gap-y-1 text-xs">
          <code className="text-xs select-all">
            Tessarium v{__APP_VERSION__}
          </code>
          {versions.data && (
            <>
              <code className="epoch text-xs select-all">
                {versions.data.grid}
              </code>
              <code className="epoch text-xs select-all">
                {versions.data.derivation}
              </code>
            </>
          )}
        </p>
      </footer>
    </aside>
  );
}
