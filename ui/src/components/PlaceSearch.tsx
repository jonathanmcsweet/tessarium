/* One box for both ways of naming somewhere: a place, or an address.

   Deliberately not a geocoder call. The place index this reads was built from
   the downloaded tiles, so a place query never leaves the machine — which is
   the whole reason the feature is shaped this way rather than as one fetch to
   a hosted service.

   An address is stricter still: it never leaves the BROWSER. Before anything
   is sent, the text is classified by `Tessarium.address_shape`, which lives
   beside the address format rather than being re-implemented here — and the
   place query is gated on that answer. Three outcomes:

     complete  decode it in the worker and offer to fly there
     partial   someone is mid-address: show nothing, send nothing
     no        a place name: search the index as before

   The gate fails closed. While the classification is still in flight the
   answer is not yet "no", so nothing is searched; a keystroke costs one
   postMessage round trip before the request it might not make. Getting this
   backwards would put a user's address in a request, in a log, and on a
   network in any hosted deployment — which is the one thing an address must
   never be in. */

import { Search } from "lucide-react";
import { useEffect, useId, useMemo, useRef, useState } from "react";
import { type PlaceResult, usePlaceSearch } from "../core/basemap";
import {
  bearing8,
  containingCountry,
  containingSubdivision,
  type Direction,
  distanceKm,
} from "../core/placeContext";
import { useAddressLookup, useAddressShape } from "../core/queries";
import { getLocale } from "../i18n";
import { m } from "../paraglide/messages";
import { citiesOf, countries, countryName, subdivisionsOf } from "../regions";

const DIRECTION_LABEL: Record<Direction, () => string> = {
  n: m.search_dir_n,
  ne: m.search_dir_ne,
  e: m.search_dir_e,
  se: m.search_dir_se,
  s: m.search_dir_s,
  sw: m.search_dir_sw,
  w: m.search_dir_w,
  nw: m.search_dir_nw,
};

/* Long enough that typing a word does not fire a scan per keystroke, short
   enough that the list feels attached to the keyboard. The scan itself is
   milliseconds on a city and a few hundred on a country. */
const DEBOUNCE_MS = 250;

export function PlaceSearch(
  { onPick, onPickAddress, center }: {
    onPick: (lon: number, lat: number) => void;
    /* Separate from onPick because arriving at an address should select the
       square as well as move the map -- the user asked about a square, not
       about a neighbourhood. */
    onPickAddress: (lon: number, lat: number) => void;
    /* Where the map is now, for "how far would this take me" -- null
       before the map exists. A function, not a value: the centre moves
       without this component re-rendering. */
    center: () => { lon: number; lat: number; } | null;
  },
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

  /* The classification, and everything that hangs off it. `shape` is
     undefined until the worker answers, and every branch below treats that
     as "not a place name yet" rather than as "no". */
  const shapeQuery = useAddressShape(debounced);
  const shape = shapeQuery.data?.shape;
  const isAddress = shape === "complete";
  const isPartial = shape === "partial";

  const lookup = useAddressLookup(debounced, isAddress);
  const addressError = lookup.error instanceof Error
    ? lookup.error.message
    : null;

  const search = usePlaceSearch(debounced, shape === "no");
  const results = search.data?.results ?? [];
  /* Clamped on read: a refetch can return fewer rows than the highlight was
     sitting on, and a dangling aria-activedescendant points a screen reader
     at an element that no longer exists. */
  const active = Math.min(rawActive, Math.max(0, results.length - 1));
  /* An address answer is worth showing from the first character -- there is
     no "too short to be meaningful" for text already known to be one. */
  const listOpen = open
    && (isAddress || isPartial || debounced.trim().length >= 2);

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

  /* Cleared on arrival, unlike a place name, which is deliberately kept so
     the same answers can be seen again without retyping. An address is not a
     query to refine -- it names one square and the map is now on it -- and it
     is a secret sitting in a box OVER the map, where the panel keeps the same
     value behind a conceal toggle. Leaving it there would put an address in
     every screenshot of the map, which is the exposure the panel's toggle
     exists to prevent. */
  const pickAddress = () => {
    const point = lookup.data;
    if (!point) return;
    onPickAddress(point.lon, point.lat);
    setText("");
    setOpen(false);
  };

  /* The catalogue's shapes, once -- they are static data. Labels are NOT
     memoized with them: the locale can change under a live component
     (regions.ts recomputes per call for the same reason), so the name is
     asked for at render time, fresh. */
  const shapes = useMemo(() => countries().map(({ country }) => country), []);

  /* A result reads as "name — kind · where · how far": several towns share
     a name (the United States alone has a handful of Atlantas), so the
     kind alone is a coin flip about where the map is about to fly. The
     containing country and, where the catalogue has them, the subdivision
     come from the shipped border data; the distance and compass point from
     the current map centre. All offline -- the query already never leaves
     the machine, and neither does the context. */
  const describe = (r: PlaceResult) => {
    const parts = [r.kind === "" ? r.layer : r.kind.replace(/_/g, " ")];
    const where = containingCountry(shapes, r.lon, r.lat, citiesOf);
    if (where) {
      const region = containingSubdivision(subdivisionsOf(where), r.lon, r.lat);
      const label = countryName(where);
      parts.push(
        region ? m.search_in_region({ region, country: label }) : label,
      );
    }
    const from = center();
    if (from) {
      const km = distanceKm(from.lon, from.lat, r.lon, r.lat);
      if (km >= 1) {
        parts.push(m.search_away({
          distance: new Intl.NumberFormat(getLocale()).format(km),
          direction: DIRECTION_LABEL
            [bearing8(from.lon, from.lat, r.lon, r.lat)](),
        }));
      }
    }
    return parts.join(" · ");
  };

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
            if (isAddress) {
              if (e.key === "Enter") {
                e.preventDefault();
                pickAddress();
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
          {isPartial
            ? (
              <p className="place-empty" role="status">
                {m.search_address_partial()}
              </p>
            )
            : isAddress
            ? (
              /* One option, not a list: an address names exactly one square,
                 so there is nothing to choose between. Still an option in a
                 listbox, because Enter and the pointer must do the same
                 thing here as they do for a place. */
              <div id={listId} role="listbox" aria-label={m.search_label()}>
                {addressError
                  ? <p className="place-empty" role="status">{addressError}</p>
                  : lookup.data
                  ? (
                    <button
                      type="button"
                      id={`${listId}-0`}
                      role="option"
                      tabIndex={-1}
                      aria-selected
                      className="place-option active"
                      onClick={pickAddress}
                    >
                      <span className="place-name">{debounced.trim()}</span>
                      <span className="place-kind">
                        {m.search_address_local()}
                      </span>
                    </button>
                  )
                  : (
                    <p className="place-empty" role="status">
                      {m.search_searching()}
                    </p>
                  )}
              </div>
            )
            : results.length === 0
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
