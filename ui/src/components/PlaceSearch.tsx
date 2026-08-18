/* Finding a place by name, out of the region already on disk.

   Deliberately not a geocoder call. The index this reads was built from the
   downloaded tiles, so a query never leaves the machine — which is the whole
   reason the feature is shaped this way rather than as one fetch to a
   hosted service. */

import { Search } from "lucide-react";
import { useEffect, useId, useRef, useState } from "react";
import { type PlaceResult, usePlaceSearch } from "../core/basemap";
import { m } from "../paraglide/messages";

/* Long enough that typing a word does not fire a scan per keystroke, short
   enough that the list feels attached to the keyboard. The scan itself is
   milliseconds on a city and a few hundred on a country. */
const DEBOUNCE_MS = 250;

export function PlaceSearch(
  { onPick }: { onPick: (lon: number, lat: number) => void; },
) {
  const [text, setText] = useState("");
  const [debounced, setDebounced] = useState("");
  const [open, setOpen] = useState(false);
  const [rawActive, setActive] = useState(0);
  const listId = useId();
  const boxRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const timer = setTimeout(() => setDebounced(text), DEBOUNCE_MS);
    return () => clearTimeout(timer);
  }, [text]);

  const search = usePlaceSearch(debounced);
  const results = search.data?.results ?? [];
  /* Clamped on read: a refetch can return fewer rows than the highlight was
     sitting on, and a dangling aria-activedescendant points a screen reader
     at an element that no longer exists. */
  const active = Math.min(rawActive, Math.max(0, results.length - 1));
  const listOpen = open && debounced.trim().length >= 2;

  /* Clicking away closes the list; the input keeps what was typed, because
     losing it would mean retyping to see the same answers. */
  useEffect(() => {
    if (!open) return;
    const away = (event: MouseEvent) => {
      if (!boxRef.current?.contains(event.target as Node)) setOpen(false);
    };
    document.addEventListener("mousedown", away);
    return () => document.removeEventListener("mousedown", away);
  }, [open]);

  /* biome-ignore lint/correctness/useExhaustiveDependencies: the point is to
     reset the highlight when the QUERY changes, which the body does not read */
  useEffect(() => setActive(0), [debounced]);

  const pick = (r: PlaceResult) => {
    onPick(r.lon, r.lat);
    setOpen(false);
  };

  /* A result reads as "name — kind, near here": the kind is what separates
     three identical names, and the basemap spells it in snake_case. */
  const describe = (r: PlaceResult) =>
    r.kind === "" ? r.layer : r.kind.replace(/_/g, " ");

  return (
    <div className="place-search" ref={boxRef}>
      <label className="sr-only" htmlFor="place-search-input">
        {m.search_label()}
      </label>
      <div className="place-search-field">
        <Search size={16} aria-hidden />
        <input
          id="place-search-input"
          type="text"
          role="combobox"
          aria-expanded={listOpen}
          aria-controls={listOpen ? listId : undefined}
          aria-autocomplete="list"
          aria-activedescendant={listOpen && results.length > 0
            ? `${listId}-${active}`
            : undefined}
          autoComplete="off"
          spellCheck={false}
          placeholder={m.search_placeholder()}
          value={text}
          onChange={(e) => {
            setText(e.target.value);
            setOpen(true);
          }}
          onFocus={() => setOpen(true)}
          /* Tabbing away closes it; without this the list hangs over the
             map with focus somewhere else entirely. */
          onBlur={(e) => {
            if (!boxRef.current?.contains(e.relatedTarget as Node)) {
              setOpen(false);
            }
          }}
          onKeyDown={(e) => {
            if (e.key === "Escape") {
              setOpen(false);
              return;
            }
            /* Closed means closed. Without this the widget stays live under
               a list nobody can see: Enter would fly the map to a result
               that is not on screen, and the arrows would move an invisible
               cursor. Down reopens, which is what a combobox does. */
            if (!listOpen) {
              if (e.key === "ArrowDown") {
                e.preventDefault();
                setOpen(true);
              }
              return;
            }
            if (results.length === 0) return;
            if (e.key === "ArrowDown") {
              e.preventDefault();
              setActive((i) => (i + 1) % results.length);
            } else if (e.key === "ArrowUp") {
              e.preventDefault();
              setActive((i) => (i - 1 + results.length) % results.length);
            } else if (e.key === "Enter") {
              e.preventDefault();
              const chosen = results[active];
              if (chosen) pick(chosen);
            }
          }}
        />
      </div>
      {listOpen && (
        /* Roles on divs rather than ul/li: a list is not interactive, and
           dressing one up as a listbox is what assistive technology has to
           un-guess. The options never take focus -- the input keeps it and
           points at the active one, which is what makes a combobox behave
           for both a keyboard and a screen reader. */
        <div className="place-results">
          {results.length === 0
            ? (
              /* Outside the listbox: a paragraph is not an option, and a
                 listbox may only contain options. Announced instead. */
              <p className="place-empty" role="status">
                {search.isFetching ? m.search_searching() : m.search_none()}
              </p>
            )
            : (
              <div id={listId} role="listbox" aria-label={m.search_label()}>
                {results.map((r, i) => (
                  /* A button, not a styled div: it is a thing you press, so it
                 should be the element that already knows how -- focusable,
                 Enter and Space for free, and nothing to re-implement. The
                 input keeps focus and points here with
                 aria-activedescendant, which is what makes arrow keys work
                 without the options stealing it. */
                  <button
                    type="button"
                    key={`${r.name}-${r.lon}-${r.lat}`}
                    id={`${listId}-${i}`}
                    role="option"
                    tabIndex={-1}
                    aria-selected={i === active}
                    className={i === active
                      ? "place-option active"
                      : "place-option"}
                    onClick={() => pick(r)}
                    onMouseEnter={() => setActive(i)}
                  >
                    <span className="place-name">{r.name}</span>
                    <span className="place-kind">{describe(r)}</span>
                  </button>
                ))}
              </div>
            )}
        </div>
      )}
    </div>
  );
}
