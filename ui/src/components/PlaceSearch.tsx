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
import { useEffect, useMemo, useState } from "react";
import {
  ComboBox,
  Input,
  ListBox,
  ListBoxItem,
  Popover,
} from "react-aria-components";
import { toast } from "sonner";
import { type PlaceResult, usePlaceSearch } from "../core/basemap";
import {
  bearing8,
  compareRows,
  containingCountry,
  contextDepth,
  contextTerms,
  type Direction,
  distanceKm,
  namedSubdivision,
  overlappingSubdivisions,
  placeLabels,
} from "../core/placeContext";
import { useAddressLookup, useAddressShape } from "../core/queries";
import { sayError } from "../core/refusal";
import { getLocale } from "../i18n";
import { m } from "../paraglide/messages";
import {
  citiesOf,
  countries,
  type Country,
  countryName,
  subdivisionsOf,
} from "../regions";

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

/* Rows offered. The popover scrolls past about five, so eight is a short
   scroll rather than a wall. */
const SHOWN = 8;

/* Rows ASKED FOR when the query carries a context. The server ranks by
   population and knows nothing of states, so the Jasper in Georgia sits
   wherever its population puts it among every other Jasper -- sixth, on
   the real United States index, which is below the fold. Forty rows is a
   couple of kilobytes on a request that already scanned the whole index,
   and it is only asked for when there is a comma to justify it. */
const WIDE = 40;

/* Where each result sits, and how much of the typed context it answers.
   Both fall out of the same containment work, so it is done once per row
   rather than once for the label and again for the ranking.

   Module level, with every input named, so the memo that calls it can
   state what it depends on -- the locale included, because a country is
   matched against the context under the name the reader would see it
   under.

   The sort is the whole point of the wider ask -- see [compareRows], which
   states the two keys and why they are in that order. Ranking only: a row
   answering none of the context is still offered, because the boxes
   overlap and the borders are simplified, and a context that DECIDED
   would hide the right answer every time the catalogue and the atlas
   disagreed. */
const placeRows = (
  results: readonly PlaceResult[],
  shapes: readonly Country[],
  terms: readonly string[],
  locale: string,
) =>
  results
    .map((result) => {
      const country = containingCountry(
        shapes,
        result.lon,
        result.lat,
        citiesOf,
      );
      const subs = country
        ? overlappingSubdivisions(
          subdivisionsOf(country),
          result.lon,
          result.lat,
        )
        : [];
      return {
        result,
        at: {
          country,
          region: namedSubdivision(subs, terms),
          depth: contextDepth(
            terms,
            placeLabels(country, country && countryName(country, locale), subs),
          ),
        },
      };
    })
    .sort(compareRows)
    .slice(0, SHOWN);

type Placing = ReturnType<typeof placeRows>[number]["at"];

/* Long enough that typing a word does not fire a scan per keystroke, short
   enough that the list feels attached to the keyboard. The scan itself is
   milliseconds on a city and a few hundred on a country. */
const DEBOUNCE_MS = 250;

/* The box itself. The ring is on the wrapper rather than the input, because
   the magnifier sits inside the same border and a ring around only the text
   would read as two controls. */
const FIELD = "place-search-field flex items-center gap-2 rounded-lg border "
  + "border-line-strong bg-card px-2.5 shadow-[0_1px_4px_rgb(0_0_0/0.15)] "
  + "focus-within:outline-2 focus-within:outline-offset-1 "
  + "focus-within:outline-accent-text";

export function PlaceSearch(
  { onPick, onPickAddress, center }: {
    onPick: (lon: number, lat: number) => void;
    /* Separate from onPick because an address names a square rather than a
       neighbourhood, so it is worth arriving closer. Both only move the
       camera. */
    onPickAddress: (lon: number, lat: number) => void;
    /* Where the map is now, for "how far would this take me" -- null
       before the map exists. A function, not a value: the centre moves
       without this component re-rendering. */
    center: () => { lon: number; lat: number; } | null;
  },
) {
  const [text, setText] = useState("");
  const [debounced, setDebounced] = useState("");
  /* No open flag, no highlight index, no listbox id, no ref to the box.
     React Aria's ComboBox owns those, along with the click-away listener,
     the blur rule, Escape, the arrow-key wrap, and the aria-activedescendant
     that has to point at whichever branch drew an option. */

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
  /* The core's refusal, said in the user's language: this is where a
     mistyped word or a three-digit number is explained, and it is the most
     likely error anyone here will ever see. */
  const addressError = lookup.error ? sayError(lookup.error) : null;

  /* What was typed after the comma: "Jasper, GA". The server cannot answer
     it -- its index is tile labels, and a tile label does not know its
     state -- so the answer is worked out here from the border data already
     shipped, and a wider slice of the index is asked for when there is a
     context to answer with it. */
  const locale = getLocale();
  const terms = useMemo(
    () => (shape === "no" ? contextTerms(debounced) : []),
    [shape, debounced],
  );
  const search = usePlaceSearch(
    debounced,
    shape === "no",
    terms.length > 0 ? WIDE : SHOWN,
  );
  const results = search.data?.results;

  /* An address answer is worth showing from the first character -- there is
     no "too short to be meaningful" for text already known to be one. A
     place name waits for two, which is what keeps one keystroke from
     scanning the index. */
  const longEnough = debounced.trim().length >= 2;

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
  const describe = (r: PlaceResult, at: Placing) => {
    const parts = [r.kind === "" ? r.layer : r.kind.replace(/_/g, " ")];
    if (at.country) {
      const label = countryName(at.country);
      parts.push(
        at.region
          ? m.search_in_region({ region: at.region, country: label })
          : label,
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

  /* Memoized because placing a point is a ray cast against every border
     polygon in the catalogue -- ten thousand edges -- and forty of them
     measured 15 ms: a dropped frame on every keystroke, and several on a
     phone. */
  const ranked = useMemo(
    () => placeRows(results ?? [], shapes, terms, locale),
    [results, shapes, terms, locale],
  );

  /* One collection, whichever mode is live. The old version branched in the
     markup and had to keep three sets of ARIA wiring agreeing with each
     other; a combobox only ever has options, so the branch belongs here. An
     address resolves to exactly one, which is still an option because Enter
     and the pointer must do the same thing for it as for a place. */
  type Option = {
    id: string;
    name: string;
    kind: string;
    lon: number;
    lat: number;
    address: boolean;
  };
  const options: Option[] = isAddress
    ? (lookup.data && !addressError
      ? [{
        id: "address",
        name: debounced.trim(),
        kind: m.search_address_local(),
        lon: lookup.data.lon,
        lat: lookup.data.lat,
        address: true,
      }]
      : [])
    : shape === "no" && longEnough
    ? ranked.map(({ result: r, at }) => ({
      id: `${r.name}-${r.lon}-${r.lat}`,
      name: r.name,
      kind: describe(r, at),
      lon: r.lon,
      lat: r.lat,
      address: false,
    }))
    : [];

  /* What to say when there are no options but there IS something to say.
     Null means the popover should not open at all -- a query under two
     characters has no answer yet and an empty box over the map is noise.
     Kept out of the listbox: a paragraph is not an option, and a listbox
     may only contain options. */
  const emptyMessage = isPartial
    ? `${m.search_address_partial()} ${
      m.search_prefix_hint({ example: m.search_prefix_example() })
    }`
    : isAddress
    ? (addressError ?? m.search_searching())
    : shape === "no" && longEnough
    ? (search.isFetching ? m.search_searching() : m.search_none())
    : null;

  /* Cleared on arrival for an address, unlike a place name, which is
     deliberately kept so the same answers can be seen again without
     retyping. An address is not a query to refine -- it names one square and
     the map is now on it -- and it is a secret sitting in a box OVER the
     map, where the panel keeps the same value behind a conceal toggle.
     Leaving it there would put an address in every screenshot of the map,
     which is the exposure the panel's toggle exists to prevent. */
  const pickAddress = (option: Option) => {
    onPickAddress(option.lon, option.lat);
    toast.success(m.search_found());
    setText("");
  };

  return (
    <ComboBox
      className="place-search"
      aria-label={m.search_label()}
      inputValue={text}
      onInputChange={setText}
      items={options}
      /* Nothing stays chosen: picking is an action, not a state, so the
         selection is handed back immediately. Without this, choosing the
         same result twice in a row would be silent the second time. */
      selectedKey={null}
      onSelectionChange={(key) => {
        const option = options.find((o) => o.id === key);
        if (!option) return;
        if (option.address) pickAddress(option);
        else onPick(option.lon, option.lat);
      }}
      /* Always allowed to open with nothing in it, and this is the one
         place where this widget and React Aria genuinely disagree.

         ComboBox decides whether to open in an effect that runs on the
         render where the input value changed, and refuses if the collection
         is empty and this flag is off. Every answer here arrives later than
         that: the text is debounced by 250 ms, then classified in the
         worker, then either decoded or run past the place index. So at the
         only moment ComboBox is willing to open, there is never anything to
         show -- and it never asks again, because by the time the results
         land the input value has stopped changing. With the flag off this
         box simply never opened.

         So the answer is to let it open always and decide separately what
         may be seen: the Popover below is not rendered at all when there is
         neither an option nor something to say, which is what keeps an empty
         card off the map while someone types their first character. */
      allowsEmptyCollection
      /* Not decoration, and not optional. What is typed here is usually NOT
         one of the options -- a place query, a half-typed address -- so a
         custom value is the normal case. Without it, Escape takes the
         "commit the selection" path, which resets the library's record of
         the last input value to the empty string while the box still holds
         text; the reopen effect then sees a value that differs from its
         record and opens the list again in the same tick. Escape closed
         nothing. With it, Escape commits what is there and closes, which is
         also what the hand-written version did. */
      allowsCustomValue
    >
      <div className={FIELD}>
        <Search size={16} aria-hidden className="flex-none text-ink-soft" />
        <Input
          id="place-search-input"
          className="w-full border-0 bg-transparent py-2.5 focus:outline-none"
          autoComplete="off"
          spellCheck={false}
          placeholder={m.search_placeholder()}
        />
      </div>
      {
        /* React Aria renders the results card in a portal at the end of the
          document and positions it, so it is no longer a child of the search
          box: it needs its own stacking order against the map, and it takes
          its width from the field through the variable the library sets on
          it rather than by inheriting a parent's. */
      }
      {(options.length > 0 || emptyMessage !== null) && (
        <Popover className="place-results sheet z-5 w-(--trigger-width)">
          <ListBox
            className="block max-h-72 overflow-y-auto p-1 outline-none"
            renderEmptyState={() => (
              <p
                className="place-empty px-2.5 py-2 text-ink-soft"
                role="status"
              >
                {emptyMessage}
              </p>
            )}
          >
            {(option: Option) => (
              <ListBoxItem
                id={option.id}
                className="place-option sheet-option w-full flex-col items-start gap-px text-left"
                textValue={option.name}
              >
                <span className="font-semibold">{option.name}</span>
                <span className="text-xs text-ink-soft">{option.kind}</span>
              </ListBoxItem>
            )}
          </ListBox>
        </Popover>
      )}
    </ComboBox>
  );
}
