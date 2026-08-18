/* The side panel: the address of the selected square, and a box to look one
   up.

   This is the only place an address is ever displayed. The map draws bare
   squares, so a screenshot or a shared screen gives away one address at most
   -- and the eye toggle here takes that to none. */

import { Copy, Eye, EyeOff, Lock } from "lucide-react";
import { type FormEvent, useState } from "react";
import { toast } from "sonner";
import { useDecodeAddress, useLock } from "../core/queries";
import { formatCoord } from "../i18n";
import { m } from "../paraglide/messages";
import { useAppStore } from "../store";
import { toastError } from "../toast";
import { IconButton } from "./IconButton";
import { LanguagePicker } from "./LanguagePicker";

/* Same shape as an address, so the panel does not change width when it is
   concealed and the layout does not jump on every toggle. */
const MASK = "••••••.••••••.••••••.••••";
/* And the same idea for a coordinate. */
const COORD_MASK = "••.•••••••";

export function AddressPanel() {
  const [query, setQuery] = useState("");
  const [invalid, setInvalid] = useState(false);

  const selection = useAppStore((s) => s.selection);
  const concealed = useAppStore((s) => s.concealed);
  const toggleConcealed = useAppStore((s) => s.toggleConcealed);
  const coordsConcealed = useAppStore((s) => s.coordsConcealed);
  const toggleCoordsConcealed = useAppStore((s) => s.toggleCoordsConcealed);
  const requestFlyTo = useAppStore((s) => s.requestFlyTo);
  const setLocked = useAppStore((s) => s.setLocked);

  const lock = useLock();
  const decode = useDecodeAddress();

  async function copy() {
    if (!selection) return;
    try {
      await navigator.clipboard.writeText(selection.address);
      toast.success(m.panel_copied());
    } catch {
      /* Clipboard access is refused in some contexts. The address is on
         screen and selectable, so say so rather than failing silently. */
      toastError(m.panel_copy_failed());
    }
  }

  async function copyCoords() {
    if (!selection) return;
    try {
      await navigator.clipboard.writeText(
        `${formatCoord(selection.cell.latLo)}, ${
          formatCoord(selection.cell.lonLo)
        }`,
      );
      toast.success(m.panel_coords_copied());
    } catch {
      /* Unlike the address, the value may be deliberately absent from the
         screen, so the fallback tells the user how to get at it. */
      toastError(m.panel_coords_copy_failed());
    }
  }

  function lookup(event: FormEvent) {
    event.preventDefault();
    setInvalid(false);
    decode.mutate(query, {
      onSuccess: ({ lat, lon }) => {
        requestFlyTo(lat, lon);
        toast.success(m.panel_found());
      },
      onError: (error) => {
        setInvalid(true);
        toastError(error instanceof Error ? error.message : String(error));
      },
    });
  }

  return (
    <aside className="panel">
      <header className="panel-head">
        <span className="brand">{m.app_name()}</span>
        <button
          type="button"
          className="lock"
          onClick={() => {
            lock.mutate();
            setLocked();
          }}
          title={m.panel_lock_hint()}
        >
          <Lock size={15} aria-hidden />
          {m.panel_lock()}
        </button>
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
                <output className={concealed ? "address concealed" : "address"}>
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
                <IconButton
                  label={m.panel_copy()}
                  onClick={copy}
                  icon={<Copy size={18} aria-hidden />}
                />
              </div>
              {concealed && (
                <p className="concealed-note">{m.panel_concealed()}</p>
              )}
              {
                /* Coordinates name where someone is as plainly as the
                  address does, so they get the same treatment: hidden by
                  default, not rendered while hidden, copyable either way. */
              }
              <div className="coords-row">
                <dl className="coords">
                  <dt>{m.panel_latitude()}</dt>
                  <dd>
                    {coordsConcealed
                      ? COORD_MASK
                      : formatCoord(selection.cell.latLo)}
                  </dd>
                  <dt>{m.panel_longitude()}</dt>
                  <dd>
                    {coordsConcealed
                      ? COORD_MASK
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
                <IconButton
                  label={m.panel_coords_copy()}
                  onClick={copyCoords}
                  icon={<Copy size={18} aria-hidden />}
                />
              </div>
            </>
          )
          : <p className="hint">{m.panel_no_selection()}</p>}
      </section>

      <section className="lookup">
        <h2 id="lookup-heading">{m.panel_find_title()}</h2>
        <form onSubmit={lookup}>
          <label className="sr-only" htmlFor="lookup-input">
            {m.panel_find_label()}
          </label>
          <input
            id="lookup-input"
            type="text"
            spellCheck={false}
            autoComplete="off"
            autoCapitalize="off"
            aria-invalid={invalid}
            aria-describedby="lookup-hint"
            placeholder={m.panel_find_placeholder()}
            value={query}
            onChange={(e) => {
              setQuery(e.target.value);
              setInvalid(false);
            }}
          />
          <button
            type="submit"
            disabled={query.trim() === "" || decode.isPending}
          >
            {m.panel_go()}
          </button>
        </form>
        <p className="hint" id="lookup-hint">
          {m.panel_prefix_hint({ example: m.panel_prefix_example() })}
        </p>
      </section>

      <footer className="panel-foot">
        <LanguagePicker />
        <p>{m.panel_footer()}</p>
        {
          /* A name and a number: nothing to translate, so no message key. The
            grid and derivation versions are deliberately NOT shown -- the
            end-to-end suite checks them against the vectors instead. */
        }
        <p className="versions">
          <code>Tessarium v{__APP_VERSION__}</code>
        </p>
      </footer>
    </aside>
  );
}
