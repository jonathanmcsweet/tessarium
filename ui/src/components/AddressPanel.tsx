/* The side panel: the address of the selected square.

   Looking an address UP happens in the map's search box, which takes both a
   place name and an address -- see PlaceSearch. The form that used to live
   here is gone rather than duplicated.

   This is the only place an address is ever displayed. The map draws bare
   squares, so a screenshot or a shared screen gives away one address at most
   -- and the eye toggle here takes that to none. */

import { Eye, EyeOff } from "lucide-react";
import { useCoreVersions, useLock } from "../core/queries";
import { formatCoord } from "../i18n";
import { m } from "../paraglide/messages";
import { useAppStore } from "../store";
import { CopyButton } from "./CopyButton";
import { IconButton } from "./IconButton";
import { LanguagePicker } from "./LanguagePicker";
import { LockDialog } from "./LockDialog";

/* Same shape as an address, so the panel does not change width when it is
   concealed and the layout does not jump on every toggle. */
const MASK = "••••••.••••••.••••••.••••";
/* And the same idea for a coordinate. */
const COORD_MASK = "••.•••••••";

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

  return (
    <aside className="panel">
      <header className="panel-head">
        <span className="brand">{m.app_name()}</span>
        <div className="panel-head-actions">
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
          <LockDialog
            onConfirm={() => {
              lock.mutate();
              setLocked();
            }}
          />
        </div>
      </header>

      <section className="selected">
        <h2>{m.panel_this_square()}</h2>
        {selection
          ? (
            <>
              <div className="address-row">
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
                  className={concealed ? "address concealed" : "address"}
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
              <div className="coords-row">
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
                <dl className="coords">
                  <dt>{m.panel_latitude()}</dt>
                  <dd className={coordsConcealed ? "concealed" : undefined}>
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
                  <dt>{m.panel_longitude()}</dt>
                  <dd className={coordsConcealed ? "concealed" : undefined}>
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

      <footer className="panel-foot">
        <LanguagePicker />
        {
          /* Standing, not a toast, and not only in the lock dialog: a reload
            forgets the key exactly as locking does, and a browser will not
            let a page say anything useful before one. So the one place this
            can be said in time is before it happens. */
        }
        <p className="warning phrase-note">{m.panel_phrase_note()}</p>
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
        <p className="versions">
          <code>Tessarium v{__APP_VERSION__}</code>
          {versions.data && (
            <>
              <code className="epoch">{versions.data.grid}</code>
              <code className="epoch">{versions.data.derivation}</code>
            </>
          )}
        </p>
      </footer>
    </aside>
  );
}
