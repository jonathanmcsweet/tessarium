/* The side panel: the address of the selected square.

   Looking an address UP happens in the map's search box, which takes both a
   place name and an address -- see PlaceSearch.

   This is the only place an address is ever displayed. The map draws bare
   squares, so a screenshot or a shared screen gives away one address at
   most, and the eye toggle here takes that to none. */

import { Download, Eye, EyeOff, PanelRightClose } from "lucide-react";
import { lazy, type RefObject, Suspense, useEffect, useRef } from "react";
import { core, useCoreVersions, useLock } from "../core/queries";
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

/* The drawer sits OVER the map, not beside it. As a grid column it took
   width from the map, so every drag re-laid out MapLibre, re-rendered tiles
   and moved the view under you. Overlaid, the map is the full width of the
   shell and stays put. The shadow is what makes it read as a panel over the
   map rather than a pale stripe beside it.

   Below the drawer breakpoint it is a sheet across the bottom instead: no
   vertical edge to drag, so PanelResizer hides itself and the width is the
   viewport's. --panel-w is set on the shell by App.tsx. */
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
/* A row of the view section. Text, and whether it carries a consequence --
   nothing here is pressable: the one thing to do about any of it is the
   download button in the header above, which the coverage row names. */
type ViewNote = {
  key: string;
  text: string;
  warn?: boolean;
};

const DownloadCard = lazy(() =>
  loadDownloadCard().then((mod) => ({ default: mod.DownloadCard }))
);

export function AddressPanel(
  {
    /* The element carrying the shell's custom properties, handed down the
       way PanelResizer's is: the panel reports its own height onto it, and
       styles.css decides what that height means. Above the drawer breakpoint
       it means nothing -- the panel is beside the map, not on it. */
    surface,
  }: { surface: RefObject<HTMLDivElement | null>; },
) {
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

  /* The offline-maps card is drawn here rather than over the map, where it
     covered the tiles it was about and had nowhere to grow. */
  const downloadOpen = useAppStore((s) => s.downloadOpen);
  const openDownload = useAppStore((s) => s.openDownload);
  const closeDownload = useAppStore((s) => s.closeDownload);
  const togglePanel = useAppStore((s) => s.togglePanel);
  const panelCollapsed = useAppStore((s) => s.panelCollapsed);
  const downloadRegion = useAppStore((s) => s.downloadRegion);

  /* What the map has to say about the view it is drawing, said here rather
     than over the ground it is about. Built as a list so the section and its
     rows cannot disagree about whether there is anything to say -- as two
     conditions they drift, and an empty headed section is worse than none.

     The coverage row goes when the maps card opens: the row exists to open
     that card, and it is the card that then says what will be fetched. */
  const view = useAppStore((s) => s.view);
  const notes: ViewNote[] = [
    view.truncated
      ? { key: "truncated", text: m.map_too_many_squares(), warn: true }
      : null,
    view.belowGrid ? { key: "below-grid", text: m.map_zoom_for_grid() } : null,
    view.blank && !downloadOpen
      /* One message, because only one fact is honest here: the detail is not
         downloaded. What the floor draws underneath ranges from a full
         country map to one stretched polygon, so "this is the wider map" is
         a promise the app cannot keep, and "no map here" contradicts a map
         the reader can see.

         Gone while the card is open: it points at the button that opens
         that card, and pointing at a button already pressed is worse than
         saying nothing. */
      ? { key: "blank", text: m.map_coverage_gap() }
      : null,
  ].filter((note) => note !== null);

  /* The download job's status is deliberately NOT subscribed to here. It
     polls once a second for the life of a job, and holding it here
     re-rendered the address, the coordinates and the footer every second of
     an hour-long download. The card asks for itself now; the map and the
     progress section keep the poll alive meanwhile. */

  /* Same treatment as the address above, scaled to the smaller type: the
     bullets are not worth selecting, and a selection highlight through a
     blur reads as a rendering fault. */
  const coordClass = `m-0 font-mono tabular-nums${
    coordsConcealed ? " text-ink-soft blur-[2.5px] select-none" : ""
  }`;

  return (
    <aside
      ref={sheet}
      id="panel"
      className={`panel ${DRAWER} ${panelCollapsed ? SHUT : ""}`}
    >
      {
        /* Wraps, because it has to. With a square selected the row is five
          controls -- reveal, downloads, settings, lock, hide -- and at the
          drawer's default 340px there is not room. The alternative was
          clipping one off the right edge. The brand gives way first. */
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
  /* How much of the map's bottom edge this covers as a sheet. Painted
     straight onto the shell rather than kept in the store, for the reason
     PanelResizer paints its width there: the answer changes whenever the
     panel's content does -- a square selected, the maps card opened -- and
     nothing about this application's rendering should depend on it.

     Measured rather than assumed to be the 45vh cap, which it only reaches
     when the content is long enough to be scrolling. */
  const sheet = useRef<HTMLElement>(null);
  useEffect(() => {
    const node = sheet.current;
    if (!node) return;
    /* The border box, not contentRect: the sheet has a top border and the
       map has to clear that too. */
    const observer = new ResizeObserver(() => {
      surface.current?.style.setProperty("--panel-h", `${node.offsetHeight}px`);
    });
    observer.observe(node);
    return () => observer.disconnect();
  }, [surface]);

          {
            /* The way in to the offline maps. It belongs beside the thing
              it opens, which is this panel. */
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
      {notes.length > 0 && (
        <section className="view-notes border-b border-line p-4.5">
          <h2 className="panel-title mb-2.5">{m.panel_this_view()}</h2>
          <div className="flex flex-col gap-3">
            {notes.map((note) => (
              <div key={note.key} role="status">
                <p
                  className={`view-note view-note-${note.key} m-0 text-sm leading-normal${
                    note.warn
                      /* The one row carrying a consequence takes a ground and
                         a rule down its left, the same shape `warning` uses
                         for the panel's standing note. The others are plain
                         text on the panel: a section where every row is
                         marked marks nothing. */
                      ? " warn border-l-4 border-notice-soft-line"
                        + " bg-notice-soft px-3 py-2 text-warn"
                      : ""
                  }`}
                >
                  {note.text}
                </p>
              </div>
            ))}
          </div>
        </section>
      )}

              <div className="address-row flex items-start gap-1.5">
                {
                  /* Concealed means not rendered, not merely styled out of
                  sight. An address hidden with CSS is still in the page for
                  anything reading the DOM. */
                }
                {
                  /* The mask is meaningless read aloud, so while concealed
                    the accessible name says what it is rather than spelling
                    out twenty-five bullets. It used to be a visible note
                    below the row, which moved everything under it by 23 px
                    on every press. */
                }
                <output
                  className={`address block min-w-0 flex-1 font-mono text-lg font-semibold leading-snug break-words ${
                    /* Muted rather than accented while concealed: hidden is
                       a resting state, not an alert. What is blurred is the
                       MASK -- the address is not in the document while
                       concealed, so nothing is recoverable by selecting the
                       text, opening devtools or sharpening a screenshot.

                       The colour is set in each branch and NOT on the line
                       above. It used to sit in both, and two colour classes
                       on one element are settled by the stylesheet rather
                       than by the order they are written -- so the address
                       wore accent-text in every theme, and accent-alt, the
                       token each palette defines FOR the address, painted
                       nothing. */
                    concealed
                      ? "tracking-wide text-ink-soft blur-[3.5px] select-none"
                      : "text-accent-alt"}`}
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
                  /* Named like the address above, for the same reason:
                    "Latitude, bullet bullet bullet" is not an answer.

                    NOT `aria-label` on the `dd`, which was the first
                    attempt and is invalid: a description-list value has no
                    role that takes a name, and useAriaPropsSupportedByRole
                    is right to refuse it. A hidden span carries the words
                    and the mask is hidden from the tree instead. */
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
          <DownloadCard region={downloadRegion} />
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
        <div className="phrase-copy mb-2.5 flex items-center gap-2">
        <div className="mb-2.5 flex flex-wrap items-center gap-x-4 gap-y-2">
          <LanguagePicker />
          <ThemePicker labelHidden />
        </div>
          <CopyButton
            className="panel-phrase-copy"
            label={m.panel_phrase_copy()}
            copiedLabel={m.panel_phrase_copied()}
            text={() => core().heldPhrase().then((held) => held.mnemonic)}
            onFailure={m.panel_phrase_copy_failed()}
          />
          <span>{m.panel_phrase_copy()}</span>
        </div>
        <p className="panel-explainer">{m.panel_footer()}</p>
        {
          /* Names and numbers: nothing to translate, so no message key.

            The grid and derivation versions ARE shown. An address is three
            words and four digits with no room for a version, so a code
            issued under an older grid is not refused -- it decodes to a
            different, entirely plausible square, and nothing says why.
            Naming the epoch cannot make an old code work, but it lets
            someone label the codes they keep with the grid they belong
            to. */
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
