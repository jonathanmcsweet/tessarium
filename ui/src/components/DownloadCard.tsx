/* The offline-maps card.

   Offers, in order of usefulness: the whole world at country level when
   nothing is on disk (there is nothing on screen to aim a viewport with
   until it exists), detail for the current view, and any mix of countries,
   states and cities picked by name from a filterable tree -- the way the
   established offline map apps do it, because aiming a viewport at Portugal
   is work a list does better.

   A selection travels as ONE download: the server plans all its regions
   together and dedups overlap by tile id, so picking a country and also one
   of its cities pays for the shared tiles once, and the estimate is the
   real price of the set rather than the sum of its parts. Every offer runs
   through the same estimate-then-confirm shape: what it costs, whether it
   is already held, which picks are too big for street level.

   Not a modal. It sits over the map's corner and traps nothing -- the map
   stays usable behind it, which matters because looking at the map is how a
   user decides the region is right. The view region is frozen at the moment
   the card opens; panning afterwards changes the next download, not this
   one. */

import { X } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { toast } from "sonner";
import {
  isRunning,
  type Job,
  type Region,
  useBasemapCancel,
  useBasemapDownload,
  useBasemapEstimate,
  useBasemapPresent,
  WORLD,
} from "../core/basemap";
import { formatBytes, formatList, getLocale } from "../i18n";
import { m } from "../paraglide/messages";
import {
  citiesOf,
  countries,
  countryRegions,
  subdivisionRegions,
  subdivisionsOf,
  toRegion,
} from "../regions";
import { useAppStore } from "../store";
import { IconButton } from "./IconButton";

/* A refused start -- another download already running, a server gone away
   -- must be audible, not swallowed. */
const loudly = {
  onError: (e: unknown) =>
    toast.error(e instanceof Error ? e.message : String(e)),
};

function Progress({ job }: { job: Job; }) {
  if (job.state === "planning") {
    return <p className="hint">{m.map_download_planning()}</p>;
  }
  if (job.state === "assets") {
    return <p className="hint">{m.map_download_assets()}</p>;
  }
  if (job.state !== "fetching") return null;
  const done = formatBytes(job.done_bytes);
  const total = formatBytes(job.total_bytes);
  /* The bar tracks the CURRENT part -- part sizes are not known up front,
     and a bar that restarts per labelled part is more honest than one
     guessing at a total it cannot know. */
  const text = job.parts > 1
    ? m.map_download_progress_part({
      part: job.part,
      parts: job.parts,
      done,
      total,
    })
    : m.map_download_progress({ done, total });
  return (
    <>
      <progress
        value={job.done_bytes}
        max={Math.max(1, job.total_bytes)}
        aria-label={text}
      />
      <p className="hint">{text}</p>
    </>
  );
}

/* One offer: its estimate, its caveats, its button. Shared by the world,
   the current view, and the picker's selection, so the three cannot
   drift. */
function Offer({ regions, names, describe, confirmLabel, className }: {
  regions: Region[] | null;
  /* Aligned with regions. Lets the depth warning name the picks that are
     too big for street level; the world and the view have no names worth
     saying and get the generic wording. */
  names?: string[];
  describe: (size: string) => string;
  confirmLabel: string;
  className: string;
}) {
  const estimate = useBasemapEstimate(regions);
  const download = useBasemapDownload();
  /* The picks granted less depth than they asked for. */
  const clamped = estimate.isSuccess && regions !== null
    ? regions
      .map((region, i) => ({
        name: names?.[i],
        granted: estimate.data.max_zooms[i] ?? region.max_zoom,
        asked: region.max_zoom,
      }))
      .filter((r) => r.granted < r.asked)
    : [];
  /* Deduplicated: a two-box country would otherwise be named twice. */
  const clampedNames = [
    ...new Set(
      clamped.map((r) => r.name).filter((n): n is string => n !== undefined),
    ),
  ];
  const showClamped = clamped.length > 0 && estimate.isSuccess
    && !estimate.data.covered && estimate.data.tiles > 0;
  return (
    <div className={`download-option ${className}`}>
      {regions !== null && estimate.isPending && (
        <p className="hint">{m.map_download_estimating()}</p>
      )}
      {estimate.isError && (
        <p className="hint invalid">
          {estimate.error instanceof Error
            ? estimate.error.message
            : String(estimate.error)}
        </p>
      )}
      {estimate.isSuccess && (
        <p className="hint">
          {estimate.data.covered
            ? m.map_download_covered()
            : estimate.data.tiles === 0
            ? m.map_download_none()
            : describe(formatBytes(estimate.data.total_bytes))}
        </p>
      )}
      {showClamped && (
        <p className="hint">
          {names !== undefined && clampedNames.length > 0
            ? m.map_download_clamped({ names: formatList(clampedNames) })
            : m.map_download_depth_hint()}
        </p>
      )}
      <div className="download-actions">
        <button
          type="button"
          onClick={() => regions && download.mutate(regions, loudly)}
          disabled={regions === null || !estimate.isSuccess
            || estimate.data.tiles === 0 || estimate.data.covered
            || download.isPending}
        >
          {confirmLabel}
        </button>
      </div>
    </div>
  );
}

/* A pick: a whole country, one of its states, or a city. One pick can mean
   several regions -- a country astride the antimeridian is two boxes -- and
   the label is what the selection count and the depth warning speak of. */
type Choice = { key: string; label: string; regions: Region[]; };

/* The estimate is a real planning job server-side. Waiting for the
   selection to settle turns five quick taps into one request instead of
   five abandoned ones. */
function useSettled<T>(value: T, ms: number): T {
  const [settled, setSettled] = useState(value);
  useEffect(() => {
    const id = setTimeout(() => setSettled(value), ms);
    return () => clearTimeout(id);
  }, [value, ms]);
  return settled;
}

function CheckRow({ text, checked, onChange }: {
  text: string;
  checked: boolean;
  onChange: () => void;
}) {
  return (
    <label className="region-check">
      <input type="checkbox" checked={checked} onChange={onChange} />
      <span>{text}</span>
    </label>
  );
}

/* Countries disclose their states and cities; any mix across any number of
   countries rides in one download. Native details/summary and checkboxes on
   purpose: every behavior here -- disclosure, toggling, keyboard focus --
   is the browser's own rather than re-implemented. */
function RegionPicker() {
  const [filter, setFilter] = useState("");
  const [selected, setSelected] = useState(new Map<string, Choice>());
  /* Re-sorted per render on purpose: the locale can change under a live
     picker, and "Germany" and "Allemagne" sort to different places. */
  const list = countries();
  const locale = getLocale();
  const needle = filter.trim().toLocaleLowerCase(locale);

  const toggle = (choice: Choice) =>
    setSelected((prev) => {
      const next = new Map(prev);
      if (next.has(choice.key)) next.delete(choice.key);
      else next.set(choice.key, choice);
      return next;
    });

  const picksNow = useMemo(() => [...selected.values()], [selected]);
  const picks = useSettled(picksNow, 500);

  return (
    <div className="download-option download-region">
      <label htmlFor="region-filter">{m.map_download_region_label()}</label>
      <input
        id="region-filter"
        className="region-filter"
        type="search"
        placeholder={m.map_download_region_filter()}
        value={filter}
        onChange={(e) => setFilter(e.target.value)}
      />
      <ul className="region-tree">
        {list.map(({ country, label }) => {
          const code = country.code ?? country.name;
          const subs = subdivisionsOf(country);
          const cities = citiesOf(country);
          const matches = (name: string) =>
            name.toLocaleLowerCase(locale).includes(needle);
          const selfMatch = needle === "" || matches(label);
          const childMatch = !selfMatch
            && [...subs, ...cities].some((c) => matches(c.name));
          if (!selfMatch && !childMatch) return null;
          const whole: Choice = {
            key: `country:${code}`,
            label,
            regions: countryRegions(country),
          };
          return (
            <li key={code}>
              {
                /* Filtering holds matches open so the hits are visible; with
                  no filter the browser owns the disclosure state. */
              }
              <details open={needle === "" ? undefined : true}>
                <summary>{label}</summary>
                <CheckRow
                  text={m.map_download_region_whole()}
                  checked={selected.has(whole.key)}
                  onChange={() => toggle(whole)}
                />
                {subs.length > 0 && (
                  <p className="region-group">
                    {m.map_download_region_sub_label()}
                  </p>
                )}
                {subs.map((entry) => {
                  const choice: Choice = {
                    key: `state:${code}:${entry.name}`,
                    label: entry.name,
                    regions: subdivisionRegions(entry),
                  };
                  return (
                    <CheckRow
                      key={choice.key}
                      text={entry.name}
                      checked={selected.has(choice.key)}
                      onChange={() => toggle(choice)}
                    />
                  );
                })}
                {cities.length > 0 && (
                  <p className="region-group">
                    {m.map_download_region_cities()}
                  </p>
                )}
                {cities.map((entry) => {
                  const choice: Choice = {
                    key: `city:${code}:${entry.name}`,
                    label: entry.name,
                    regions: [toRegion(entry.bbox)],
                  };
                  return (
                    <CheckRow
                      key={choice.key}
                      text={entry.name}
                      checked={selected.has(choice.key)}
                      onChange={() => toggle(choice)}
                    />
                  );
                })}
              </details>
            </li>
          );
        })}
      </ul>
      {(selected.size > 0 || picks.length > 0) && (
        <Offer
          regions={picks.length > 0 ? picks.flatMap((p) => p.regions) : null}
          names={picks.flatMap((p) => p.regions.map(() => p.label))}
          describe={(size) =>
            m.map_download_region_selected({ count: picks.length, size })}
          confirmLabel={m.map_download_confirm()}
          className="download-region-offer"
        />
      )}
    </div>
  );
}

export function DownloadCard({ region, job }: {
  region: Region;
  job: Job | undefined;
}) {
  const closeDownload = useAppStore((s) => s.closeDownload);
  const present = useBasemapPresent();
  /* Only certainty leads with the world offer: while the HEAD is in flight
     the card shows the other options rather than guessing. */
  const worldFirst = present.data === false;
  const cancel = useBasemapCancel();

  const running = job !== undefined && isRunning(job);

  return (
    <section className="download-card" aria-labelledby="download-title">
      <header>
        <h2 id="download-title">{m.map_download_title()}</h2>
        <IconButton
          label={m.map_download_close()}
          icon={<X size={16} aria-hidden />}
          onClick={closeDownload}
        />
      </header>

      {running
        ? (
          <>
            <Progress job={job} />
            <div className="download-actions">
              <button
                type="button"
                onClick={() => cancel.mutate(undefined, loudly)}
                disabled={cancel.isPending}
              >
                {m.map_download_cancel()}
              </button>
            </div>
          </>
        )
        : (
          <>
            {worldFirst && (
              <Offer
                regions={[WORLD]}
                describe={(size) => m.map_download_world_estimate({ size })}
                confirmLabel={m.map_download_world_confirm()}
                className="download-world"
              />
            )}
            <Offer
              regions={[region]}
              describe={(size) => m.map_download_estimate({ size })}
              confirmLabel={m.map_download_confirm()}
              className="download-view"
            />
            <RegionPicker />
          </>
        )}
    </section>
  );
}
