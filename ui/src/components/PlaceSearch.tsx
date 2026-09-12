import { useEffect, useMemo, useState } from "react";
import {
  ComboBox,
  Input,
  ListBox,
  ListBoxItem,
  Popover,
} from "react-aria-components";
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
import { toastSuccess } from "../toast";
import { Search } from "./icons";

type Placing = ReturnType<typeof placeRows>[number]["at"];

type Option = {
  id: string;
  name: string;
  kind: string;
  lon: number;
  lat: number;
  address: boolean;
};

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

const SHOWN = 8;
const WIDE = 40;

const DEBOUNCE_MS = 250;
const FIELD = "place-search-field flex items-center gap-2 border "
  + "border-line-strong bg-card px-2.5 shadow-[0_1px_4px_rgb(0_0_0/0.15)] "
  + "focus-within:outline-2 focus-within:outline-offset-1 "
  + "focus-within:outline-accent-text";

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

export function PlaceSearch(
  { onPick, onPickAddress, center }: {
    onPick: (lon: number, lat: number) => void;
    onPickAddress: (lon: number, lat: number) => void;
    center: () => { lon: number; lat: number; } | null;
  },
) {
  const [text, setText] = useState("");
  const [debounced, setDebounced] = useState("");

  useEffect(() => {
    const timer = setTimeout(() => setDebounced(text), DEBOUNCE_MS);
    return () => clearTimeout(timer);
  }, [text]);

  const shapeQuery = useAddressShape(debounced);
  const shape = shapeQuery.data?.shape;
  const isAddress = shape === "complete";
  const isPartial = shape === "partial";
  const lookup = useAddressLookup(debounced, isAddress);
  const addressError = lookup.error ? sayError(lookup.error) : null;

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
  const longEnough = debounced.trim().length >= 2;
  const shapes = useMemo(() => countries().map(({ country }) => country), []);

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

  const ranked = useMemo(
    () => placeRows(results ?? [], shapes, terms, locale),
    [results, shapes, terms, locale],
  );

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

  const emptyMessage = isPartial
    ? `${m.search_address_partial()} ${
      m.search_prefix_hint({ example: m.search_prefix_example() })
    }`
    : isAddress
    ? (addressError ?? m.search_searching())
    : shape === "no" && longEnough
    ? (search.isFetching ? m.search_searching() : m.search_none())
    : null;

  const pickAddress = (option: Option) => {
    onPickAddress(option.lon, option.lat);
    toastSuccess(m.search_found());
    setText("");
  };

  return (
    <ComboBox
      className="place-search"
      aria-label={m.search_label()}
      inputValue={text}
      onInputChange={setText}
      items={options}
      /* Nothing stays chosen: picking is an action, not a state. Without
         this, choosing the same result twice in a row would be silent the
         second time. */
      selectedKey={null}
      onSelectionChange={(key) => {
        const option = options.find((o) => o.id === key);
        if (!option) return;
        if (option.address) pickAddress(option);
        else onPick(option.lon, option.lat);
      }}
      allowsEmptyCollection
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
          document, so it is not a child of the search box: it needs its own
          stacking order against the map, and takes its width from the field
          through the variable the library sets on it. */
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
