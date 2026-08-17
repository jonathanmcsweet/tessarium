/* The side panel: the address of the selected square, and a box to look one
   up.

   This is the only place an address is ever displayed. The map draws bare
   squares, so a screenshot or a shared screen gives away one address at most
   -- and the eye toggle here takes that to none. */

import { Copy, Eye, EyeOff, Lock } from "lucide-react";
import { type FormEvent, useState } from "react";
import { toast } from "sonner";
import { useDecodeAddress, useLock, useStatus } from "../core/queries";
import { formatCoord } from "../i18n";
import { m } from "../paraglide/messages";
import { useAppStore } from "../store";
import { IconButton } from "./IconButton";
import { LanguagePicker } from "./LanguagePicker";

/* Same shape as an address, so the panel does not change width when it is
   concealed and the layout does not jump on every toggle. */
const MASK = "••••••.••••••.••••••.••••";

export function AddressPanel() {
  const [query, setQuery] = useState("");
  const [invalid, setInvalid] = useState(false);

  const selection = useAppStore((s) => s.selection);
  const concealed = useAppStore((s) => s.concealed);
  const toggleConcealed = useAppStore((s) => s.toggleConcealed);
  const requestFlyTo = useAppStore((s) => s.requestFlyTo);
  const setLocked = useAppStore((s) => s.setLocked);

  const lock = useLock();
  const decode = useDecodeAddress();
  const status = useStatus();

  async function copy() {
    if (!selection) return;
    try {
      await navigator.clipboard.writeText(selection.address);
      toast.success(m.panel_copied());
    } catch {
      /* Clipboard access is refused in some contexts. The address is on
         screen and selectable, so say so rather than failing silently. */
      toast.error(m.panel_copy_failed());
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
        toast.error(error instanceof Error ? error.message : String(error));
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
              <dl className="coords">
                <dt>{m.panel_latitude()}</dt>
                <dd>{formatCoord(selection.cell.latLo)}</dd>
                <dt>{m.panel_longitude()}</dt>
                <dd>{formatCoord(selection.cell.lonLo)}</dd>
              </dl>
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
          /* Which mapping this tab is on. Addresses changed twice in one day
            during development, and a tab that survives an upgrade keeps the
            old mapping in memory -- the same address then goes to different
            places in different tabs, which reads as nondeterminism unless
            the version is on screen to say otherwise. */
        }
        {status.data && (
          <p className="versions">
            {m.panel_mapping_label()}{" "}
            <code>
              {status.data.gridVersion} · {status.data.derivationVersion}
            </code>
          </p>
        )}
      </footer>
    </aside>
  );
}
