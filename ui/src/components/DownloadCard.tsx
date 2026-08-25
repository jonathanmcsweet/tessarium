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

import { Check, ChevronRight, X } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import {
  Button,
  Checkbox,
  Disclosure,
  DisclosurePanel,
} from "react-aria-components";
import {
  isRunning,
  type Job,
  type LedgerEntry,
  type Region,
  useBasemapCancel,
  useBasemapDownload,
  useBasemapEstimate,
  useBasemapLedger,
  useBasemapPresent,
  useBasemapRemove,
  useBasemapSettings,
  useBasemapUpdate,
  useSaveBasemapSettings,
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
import { toastError } from "../toast";
import { Dropdown } from "./Dropdown";
import { IconButton } from "./IconButton";

/* A refused start -- another download already running, a server gone away
   -- must be audible, not swallowed. */
const loudly = {
  onError: (e: unknown) =>
    toastError(e instanceof Error ? e.message : String(e)),
};

function Progress({ job }: { job: Job; }) {
  if (job.state === "planning") {
    return <p className="hint">{m.map_download_planning()}</p>;
  }
  if (job.state === "assets") {
    return <p className="hint">{m.map_download_assets()}</p>;
  }
  if (job.state === "compacting") {
    const text = m.map_compacting_progress({
      done: formatBytes(job.done_bytes),
      total: formatBytes(job.total_bytes),
    });
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
  if (job.state === "indexing") {
    /* Tiles, not bytes: what is being read is the archive's labels, and a
       byte count of that would mean nothing to anyone. */
    const text = m.map_indexing_progress({
      done: job.done_tiles.toLocaleString(),
      total: job.total_tiles.toLocaleString(),
    });
    return (
      <>
        <progress
          value={job.done_tiles}
          max={Math.max(1, job.total_tiles)}
          aria-label={text}
        />
        <p className="hint">{text}</p>
      </>
    );
  }
  if (job.state === "removing") {
    const text = m.map_removing_progress({
      done: formatBytes(job.done_bytes),
      total: formatBytes(job.total_bytes),
    });
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

/* What the ledger will call a download. The server caps names at 120 bytes
   of printable UTF-8; a selection of many picks is clamped to "first + N"
   rather than truncated mid-character. */
const nameBytes = (s: string) => new TextEncoder().encode(s).length;

function ledgerName(labels: string[]): string | undefined {
  const distinct = [...new Set(labels)];
  const first = distinct[0];
  if (first === undefined) return undefined;
  const joined = distinct.length === 1 ? first : formatList(distinct);
  if (nameBytes(joined) <= 120) return joined;
  const short = m.map_name_many({ first, count: distinct.length - 1 });
  return nameBytes(short) <= 120 ? short : undefined;
}

/* One offer: its estimate, its caveats, its button. Shared by the world,
   the current view, and the picker's selection, so the three cannot
   drift. */
function Offer(
  { regions, names, ledgerLabel, describe, confirmLabel, className, world }: {
    regions: Region[] | null;
    /* Whether this offer is the world overview, which lives in its own
       archive and keeps no ledger entry. */
    world?: boolean;
    /* Aligned with regions. Lets the depth warning name the picks that are
     too big for street level; the world and the view have no names worth
     saying and get the generic wording. */
    names?: string[];
    /* What the downloaded-maps list will call this, in the user's locale.
       Undefined for the world overview, which is not listed there. */
    ledgerLabel: string | undefined;
    describe: (size: string) => string;
    confirmLabel: string;
    className: string;
  },
) {
  const estimate = useBasemapEstimate(regions, world);
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
          onClick={() =>
            regions
            && download.mutate({
              regions,
              ...(ledgerLabel !== undefined ? { name: ledgerLabel } : {}),
              ...(world ? { world: true } : {}),
            }, loudly)}
          disabled={regions === null || !estimate.isSuccess
            || (estimate.data.tiles === 0 && !estimate.data.covered)
            || download.isPending}
        >
          {
            /* A covered area has nothing to fetch but can still be
               RECORDED -- that is how an archive from before the ledger
               gets its first entry. The server answers "you already have"
               if it is recorded already. */
            estimate.isSuccess && estimate.data.covered
              ? m.map_download_adopt()
              : confirmLabel
          }
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

/* The box is drawn here rather than by the browser. React Aria renders a
   real input, visually hidden, and leaves the appearance to the caller --
   which is what makes a checkbox look like the rest of the application
   instead of like the operating system. The tick comes from the shared icon
   set; `aria-hidden` because the state is already on the input. */
function CheckRow({ text, checked, onChange, disabled }: {
  text: string;
  checked: boolean;
  onChange: () => void;
  disabled?: boolean;
}) {
  return (
    <Checkbox
      className="region-check"
      isSelected={checked}
      onChange={onChange}
      isDisabled={disabled ?? false}
    >
      <span className="checkbox-box" aria-hidden="true">
        <Check size={14} />
      </span>
      <span>{text}</span>
    </Checkbox>
  );
}

/* Countries disclose their states and cities; any mix across any number of
   countries rides in one download.

   The disclosure and the checkboxes were the browser's own until React Aria
   became the interaction library. Nothing about the BEHAVIOUR needed
   replacing -- that was the argument for the native elements, and it was a
   good one -- but a `summary` marker and a system checkbox are drawn by the
   platform, and this is the densest screen in the application to have two
   controls in it that do not match anything else. */
function RegionPicker() {
  const [filter, setFilter] = useState("");
  /* Which countries the user has opened. A filter overrides it and forces
     every match open, so the hits are visible without hunting -- which is
     what `open={needle === "" ? undefined : true}` did on the native
     element, in the one way `details` allowed it to be said. */
  const [opened, setOpened] = useState(new Set<string>());
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
              <Disclosure
                className="region-disclosure"
                isExpanded={needle !== "" || opened.has(code)}
                onExpandedChange={(open) =>
                  setOpened((previous) => {
                    const next = new Set(previous);
                    if (open) next.add(code);
                    else next.delete(code);
                    return next;
                  })}
              >
                <Button slot="trigger" className="region-summary">
                  <ChevronRight size={14} aria-hidden="true" />
                  {label}
                </Button>
                <DisclosurePanel>
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
                </DisclosurePanel>
              </Disclosure>
            </li>
          );
        })}
      </ul>
      {(selected.size > 0 || picks.length > 0) && (
        <Offer
          regions={picks.length > 0 ? picks.flatMap((p) => p.regions) : null}
          names={picks.flatMap((p) => p.regions.map(() => p.label))}
          ledgerLabel={ledgerName(picks.map((p) => p.label))}
          describe={(size) =>
            m.map_download_region_selected({ count: picks.length, size })}
          confirmLabel={m.map_download_confirm()}
          className="download-region-offer"
        />
      )}
    </div>
  );
}

/* One downloaded region: what it is, how old it is, and its two verbs.
   Staleness is decided here from the recorded date and the reminder
   threshold; completed = 0 means the tiles predate the ledger and their
   age is unknown, which is treated as stale rather than fresh. Remove is
   two clicks -- the second press of the same button -- because it discards
   gigabytes that took real time to fetch. */
function LedgerRow({ entry, days, busy }: {
  entry: LedgerEntry;
  days: number;
  busy: boolean;
}) {
  const update = useBasemapUpdate();
  const remove = useBasemapRemove();
  const [confirming, setConfirming] = useState(false);
  useEffect(() => {
    if (!confirming) return;
    const id = setTimeout(() => setConfirming(false), 5000);
    return () => clearTimeout(id);
  }, [confirming]);
  const ageUnknown = entry.completed === 0;
  const stale = days > 0
    && (ageUnknown
      || Date.now() / 1000 - entry.completed > days * 86_400);
  const size = formatBytes(entry.bytes);
  const meta = ageUnknown
    ? m.map_ledger_age_unknown({ size })
    : m.map_ledger_meta({
      size,
      date: new Intl.DateTimeFormat(getLocale(), { dateStyle: "medium" })
        .format(new Date(entry.completed * 1000)),
    });
  return (
    <li className="ledger-row">
      <div className="ledger-row-text">
        <span className="ledger-name">{entry.name}</span>
        <span className="hint">
          {meta}
          {stale && (
            <>
              {" "}
              <span className="ledger-stale">{m.map_ledger_stale()}</span>
            </>
          )}
        </span>
      </div>
      <div className="download-actions">
        <button
          type="button"
          onClick={() => update.mutate(entry.id, loudly)}
          disabled={busy || update.isPending || remove.isPending}
        >
          {m.map_ledger_update()}
        </button>
        <button
          type="button"
          onClick={() => {
            if (!confirming) setConfirming(true);
            else remove.mutate(entry.id, loudly);
          }}
          disabled={busy || update.isPending || remove.isPending}
        >
          {confirming ? m.map_ledger_confirm() : m.map_ledger_remove()}
        </button>
      </div>
    </li>
  );
}

/* The downloaded-maps list and the one setting that governs it. Rendered
   only when something is recorded: an empty list teaches nothing that the
   offers above it do not. */
function DownloadedMaps({ busy }: { busy: boolean; }) {
  const ledger = useBasemapLedger();
  const settings = useBasemapSettings();
  const save = useSaveBasemapSettings();
  if (!ledger.isSuccess || ledger.data.entries.length === 0) return null;
  const days = settings.data?.update_reminder_days ?? 90;
  return (
    <div className="download-option download-ledger">
      <p className="region-group">{m.map_ledger_title()}</p>
      <ul className="ledger-rows">
        {ledger.data.entries.map((entry) => (
          <LedgerRow key={entry.id} entry={entry} days={days} busy={busy} />
        ))}
      </ul>
      <Dropdown
        className="ledger-reminder"
        label={m.map_ledger_reminder()}
        value={String(days)}
        onChange={(value) =>
          save.mutate({ update_reminder_days: Number(value) }, loudly)}
        options={[
          { value: "30", label: m.map_ledger_reminder_days({ days: 30 }) },
          { value: "90", label: m.map_ledger_reminder_days({ days: 90 }) },
          { value: "180", label: m.map_ledger_reminder_days({ days: 180 }) },
          { value: "0", label: m.map_ledger_reminder_never() },
        ]}
        disabled={!settings.isSuccess || save.isPending}
      />
    </div>
  );
}

/* The one setting that makes this tool reach the network without a click:
   fetching the tiles you are looking at, as you look. Opt-in, server-gated,
   and worded as what it does. */
function BrowseToggle() {
  const settings = useBasemapSettings();
  const save = useSaveBasemapSettings();
  return (
    <div className="download-option download-browse">
      <CheckRow
        text={m.map_browse_toggle()}
        checked={settings.data?.browse_cache ?? false}
        disabled={!settings.isSuccess || save.isPending}
        onChange={() =>
          save.mutate(
            { browse_cache: !(settings.data?.browse_cache ?? false) },
            loudly,
          )}
      />
      <p className="hint">{m.map_browse_hint()}</p>
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
  /* The world overview used to be offered ONLY on an empty map, so anyone
     who started with a region never saw it again -- and flying anywhere
     else showed blank ocean while detail loaded. When maps exist (and no
     job is running -- a world plan is real server work the running card
     has no use for), ask the estimate whether the overview is still
     missing (its incremental cost is ~zero once merged in) and keep
     offering until it isn't. React Query dedups this with the Offer's own
     estimate, which asks about the same archive and so shares its key. */
  const worldEstimate = useBasemapEstimate(
    present.data === true && !running ? [WORLD] : null,
    true,
  );
  const worldMissing = present.data === true
    && worldEstimate.isSuccess
    && !worldEstimate.data.covered
    && worldEstimate.data.tiles > 0;

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
                world
                ledgerLabel={undefined}
                describe={(size) => m.map_download_world_estimate({ size })}
                confirmLabel={m.map_download_world_confirm()}
                className="download-world"
              />
            )}
            <Offer
              regions={[region]}
              ledgerLabel={m.map_name_view()}
              describe={(size) => m.map_download_estimate({ size })}
              confirmLabel={m.map_download_confirm()}
              className="download-view"
            />
            {worldMissing && (
              <Offer
                regions={[WORLD]}
                world
                ledgerLabel={undefined}
                describe={(size) => m.map_download_world_add({ size })}
                confirmLabel={m.map_download_world_confirm()}
                className="download-world"
              />
            )}
            <RegionPicker />
            <DownloadedMaps busy={running} />
            <BrowseToggle />
          </>
        )}
    </section>
  );
}
