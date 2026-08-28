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
  exportUrl,
  isRunning,
  type Job,
  type LedgerEntry,
  type Region,
  regionUrl,
  useBasemapDownload,
  useBasemapEstimate,
  useBasemapExport,
  useBasemapExports,
  useBasemapLedger,
  useBasemapPresent,
  useBasemapRemove,
  useBasemapSettings,
  useBasemapUpdate,
  useCommitImport,
  useDeleteExport,
  useDiscardImport,
  useSaveBasemapSettings,
  useStagedImport,
  useUploadImport,
  WORLD,
} from "../core/basemap";
import type { StagedReady } from "../core/basemap";
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
import { toastError, toastSuccess } from "../toast";
import { Dropdown } from "./Dropdown";
import { IconButton } from "./IconButton";

/* A refused start -- another download already running, a server gone away
   -- must be audible, not swallowed. */
const loudly = {
  onError: (e: unknown) =>
    toastError(e instanceof Error ? e.message : String(e)),
};

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
              /* Already aligned with regions for the depth warning, and
                 exactly what the progress rows need to name themselves. */
              ...(names !== undefined ? { labels: names } : {}),
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
  const exportMap = useBasemapExport();
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
      {
        /* Classed, not just ordered. What each button DOES is the stable
           thing about it; its position in the row is not, and a fourth verb
           added here should not silently retarget anything that reaches for
           one of these -- which is exactly what adding the third did. */
      }
      <div className="download-actions">
        <button
          type="button"
          className="ledger-update"
          onClick={() => update.mutate(entry.id, loudly)}
          disabled={busy || update.isPending || remove.isPending}
        >
          {m.map_ledger_update()}
        </button>
        {
          /* A link, not a button, when the region has a file of its own --
             which is every region downloaded since downloads stopped
             merging. There is nothing to build: the file the download wrote
             IS the file to carry, so this saves it directly and there is no
             job to wait on and no second copy on disk.

             A region still inside the old merged archive keeps the button.
             That one really does have to be extracted first, and the wait
             is the extraction. */
          entry.file
            ? (
              <a
                className="button-link ledger-export"
                href={regionUrl(entry.file)}
                download={entry.file}
              >
                {m.map_ledger_save()}
              </a>
            )
            : (
              <button
                type="button"
                className="ledger-export"
                onClick={() => exportMap.mutate(entry.id, loudly)}
                disabled={busy || update.isPending || remove.isPending
                  || exportMap.isPending}
              >
                {m.map_export_action()}
              </button>
            )
        }
        <button
          type="button"
          className="ledger-remove"
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

/* Files waiting to be carried away.

   Saving is an ordinary link to an ordinary GET on this server, not a blob
   the page built: the file is on disk already, and a country-sized download
   assembled in JavaScript would be several gigabytes on the heap for no
   reason. The link streams and resumes; the heap never sees it. */
function ExportedFiles({ busy }: { busy: boolean; }) {
  const exports = useBasemapExports();
  const remove = useDeleteExport();
  if (!exports.isSuccess || exports.data.length === 0) return null;
  return (
    <div className="download-option download-exports">
      <p className="region-group">{m.map_export_title()}</p>
      <p className="hint">{m.map_export_hint()}</p>
      <ul className="ledger-rows">
        {exports.data.map((f) => (
          <li className="ledger-row" key={f.file}>
            <div className="ledger-row-text">
              <span className="ledger-name">{f.file}</span>
              <span className="hint">{formatBytes(f.bytes)}</span>
            </div>
            <div className="download-actions">
              {
                /* `download` names the saved file rather than navigating to
                  it; same origin, so the CSP is untroubled. */
              }
              <a
                className="button-link"
                href={exportUrl(f.file)}
                download={f.file}
              >
                {m.map_export_save()}
              </a>
              <button
                type="button"
                onClick={() => remove.mutate(f.file, loudly)}
                disabled={busy || remove.isPending}
              >
                {m.map_export_delete()}
              </button>
            </div>
          </li>
        ))}
      </ul>
    </div>
  );
}

/* Adding maps from a file, which is the whole offline story in one control.

   A file input, not a path box: the operating system's own picker is what
   reaches a USB stick, a phone, a network share or the downloads folder
   without this app knowing anything about any of them -- and it is the only
   thing that works under Flatpak, where the app is sandboxed away from the
   filesystem entirely but the browser is not.

   Two steps. The file goes up and is DESCRIBED first -- what it holds, how
   deep, how big -- and only a second press merges it. A gigabyte of the
   wrong country should cost a glance, not a merge. */
function ImportFromFile({ busy }: { busy: boolean; }) {
  const staged = useStagedImport();
  const upload = useUploadImport();
  const commit = useCommitImport();
  const discard = useDiscardImport();
  const [sent, setSent] = useState<{ done: number; total: number; } | null>(
    null,
  );

  /* Annotated rather than inferred: a conditional expression widens back to
     the whole union, so the narrowing done here would be lost by the time
     the fields are read below. */
  const stagedData = staged.data;
  const waiting: StagedReady | null = stagedData?.staged ? stagedData : null;

  return (
    <div className="download-option download-import">
      <p className="region-group">{m.map_import_title()}</p>
      <p className="hint">{m.map_import_hint()}</p>

      {waiting === null && (
        <>
          {
            /* A real file input, labelled: an icon or a bare button here
              would leave the control unnamed for assistive technology and
              unreachable by keyboard on some platforms. */
          }
          <label className="button-link file-input" htmlFor="import-file">
            {m.map_import_choose()}
          </label>
          <input
            id="import-file"
            className="visually-hidden"
            type="file"
            accept=".pmtiles,application/octet-stream"
            disabled={busy || upload.isPending}
            onChange={(e) => {
              const file = e.target.files?.[0];
              /* Cleared so choosing the same file twice fires again --
                 which happens when the first attempt failed. */
              e.target.value = "";
              if (!file) return;
              setSent({ done: 0, total: file.size });
              upload.mutate({
                file,
                onProgress: (done, total) => setSent({ done, total }),
              }, {
                ...loudly,
                onSettled: () => setSent(null),
              });
            }}
          />
          {upload.isPending && sent !== null && (
            <p className="hint" role="status">
              {m.map_import_uploading({
                done: formatBytes(sent.done),
                total: formatBytes(sent.total),
              })}
            </p>
          )}
        </>
      )}

      {waiting !== null && (
        <>
          <p className="hint">
            {waiting.name !== null
              ? m.map_import_staged_named({
                name: waiting.name,
                size: formatBytes(waiting.bytes),
                zoom: waiting.max_zoom,
              })
              : m.map_import_staged_unnamed({
                size: formatBytes(waiting.bytes),
                zoom: waiting.max_zoom,
              })}
          </p>
          <div className="download-actions">
            <button
              type="button"
              onClick={() =>
                commit.mutate(undefined, {
                  ...loudly,
                  onSuccess: () => toastSuccess(m.map_import_added()),
                })}
              disabled={busy || commit.isPending}
            >
              {m.map_import_confirm()}
            </button>
            <button
              type="button"
              onClick={() => discard.mutate(undefined, loudly)}
              disabled={busy || commit.isPending || discard.isPending}
            >
              {m.map_import_discard()}
            </button>
          </div>
        </>
      )}
    </div>
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

      {
        /* No progress bar and no cancel here, deliberately. Both live in
          MapProgress, one section up the same panel, which reports per
          REGION rather than as one total and stays put when this card is
          closed. When the card floated over the map the two were in
          different places and merely doubled up; in one panel they were the
          same download, described twice, with two cancel buttons. */
      }
      {
        /* What is hidden while a download runs is only the ways to start
          another one. Everything below stays, disabled through `busy` --
          which is what that prop was always for, and could never be true
          before, because this branch replaced the whole body. */
      }
      {!running && (
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
        </>
      )}
      <DownloadedMaps busy={running} />
      <ExportedFiles busy={running} />
      <ImportFromFile busy={running} />
      <BrowseToggle />
    </section>
  );
}
