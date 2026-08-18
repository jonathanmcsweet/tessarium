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
  const [active, setActive] = useState(0);
  const listId = useId();
  const boxRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const timer = setTimeout(() => setDebounced(text), DEBOUNCE_MS);
    return () => clearTimeout(timer);
  }, [text]);

  const search = usePlaceSearch(debounced);
  const results = search.data?.results ?? [];

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
          aria-expanded={open && results.length > 0}
          aria-controls={listId}
          aria-autocomplete="list"
          aria-activedescendant={open && results.length > 0
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
          onKeyDown={(e) => {
            if (e.key === "Escape") {
              setOpen(false);
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
      {open && debounced.trim().length >= 2 && (
        /* Roles on divs rather than ul/li: a list is not interactive, and
           dressing one up as a listbox is what assistive technology has to
           un-guess. The options never take focus -- the input keeps it and
           points at the active one, which is what makes a combobox behave
           for both a keyboard and a screen reader. */
        <div className="place-results" id={listId} role="listbox">
          {results.length === 0
            ? (
              <p className="place-empty">
                {search.isFetching ? m.search_searching() : m.search_none()}
              </p>
            )
            : results.map((r, i) => (
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
  );
}
