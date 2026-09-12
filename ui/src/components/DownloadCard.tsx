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
  type LabelledRegion,
  type LedgerEntry,
  type Region,
  regionUrl,
  useBasemapDownload,
  useBasemapEstimate,
  useBasemapExport,
  useBasemapExports,
  useBasemapLedger,
  useBasemapRemove,
  useBasemapSettings,
  useBasemapStatus,
  useBasemapUpdate,
  useCommitImport,
  useDeleteExport,
  useDiscardImport,
  useSaveBasemapSettings,
  useStagedImport,
  useUploadImport,
} from "../core/basemap";
import type { StagedReady } from "../core/basemap";
import { formatBytes, formatList, getLocale } from "../i18n";
import { m } from "../paraglide/messages";
import {
  citiesOf,
  countries,
  countryRegions,
  placeAt,
  subdivisionRegions,
  subdivisionsOf,
  toRegion,
} from "../regions";
import { useAppStore } from "../store";
import { toastError } from "../toast";
import { Dropdown } from "./Dropdown";
import { IconButton } from "./IconButton";
import { Check, ChevronRight, X } from "./icons";
import { LoadingTiles } from "./LoadingTiles";
import { PanelSection } from "./PanelSection";
import { InfoTip } from "./Tip";

type Choice = { key: string; label: string; regions: Region[]; };

/* The checkbox face. React Aria hides the real input and leaves the
   appearance to us, so this is the box and `selected` fills it. The tick is
   scaled to nothing when unchecked rather than unmounted, so it cannot
   reflow the row. */
const BOX = "checkbox-box flex size-4.5 flex-none items-center justify-center "
  + "border border-line-strong bg-card text-on-ink "
  + "group-selected/check:border-accent group-selected/check:bg-accent "
  + "[&>svg]:scale-0 group-selected/check:[&>svg]:scale-100";

/* Makes an <a> or a <label> read as a button. Save is an <a> because the
   browser fetches the file; import is a <label> because a file input needs
   one. */
const LINK_BUTTON = "btn btn-quiet border-line-strong";

/* A refused start -- another download running, the server gone -- must be
   audible, not swallowed. */
const loudly = {
  onError: (e: unknown) =>
    toastError(e instanceof Error ? e.message : String(e)),
};

/* What the ledger will call a download. The server caps names at 120 bytes
   of printable UTF-8, so many picks become "first + N" rather than a name
   cut mid-character. */
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

function Offer(
  {
    regions,
    names,
    regionLabel,
    ledgerLabel,
    describe,
    confirmLabel,
    className,
  }: {
    regions: Region[] | null;
    names?: string[];
    regionLabel?: string | undefined;
    ledgerLabel: string | undefined;
    describe: (size: string) => string;
    confirmLabel: string;
    className: string;
  },
) {

  const estimate = useBasemapEstimate(regions);
  const download = useBasemapDownload();
  const labelled: LabelledRegion[] | null = regions === null 
  ? null
  : regions
  .map((region, i) => {
    const label = names?.[i] ?? regionLabel;
    return label === undefined ? region : { ...region, label };
  });

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
  /* Nothing to write: covered means the archive holds every tile the source
     has here, zero tiles means the source has none. Either way there is no
     download, so no button.*/
  const nothingToWrite = estimate.isSuccess
    && (estimate.data.covered || estimate.data.tiles === 0);
  return (
    <div className={`download-option ${className}`}>
      {regions !== null && estimate.isPending && (
        <p
          className="panel-note hint estimating flex items-center gap-2"
          role="status"
        >
          <LoadingTiles />
          {m.map_download_estimating()}
        </p>
      )}
      {estimate.isError && (
        <p className="panel-note hint invalid text-danger">
          {estimate.error instanceof Error
            ? estimate.error.message
            : String(estimate.error)}
        </p>
      )}
      {estimate.isSuccess && (
        <p
          className={`panel-note hint${nothingToWrite ? " download-held" : ""}`}
        >
          {estimate.data.covered
            ? m.map_download_covered()
            : estimate.data.tiles === 0
              ? m.map_download_none()
              : describe(formatBytes(estimate.data.total_bytes))}
        </p>
      )}
      {showClamped && (
        <p className="panel-note hint">
          {names !== undefined && clampedNames.length > 0
            ? m.map_download_clamped({ names: formatList(clampedNames) })
            : m.map_download_depth_hint()}
        </p>
      )}
      {!nothingToWrite && (
        <div className="download-actions mt-2.5">
          <button
            type="button"
            className="btn btn-primary"
            onClick={() =>
              labelled
              && download.mutate({
                regions: labelled,
                ...(ledgerLabel !== undefined ? { name: ledgerLabel } : {}),
              }, loudly)}
            disabled={labelled === null || !estimate.isSuccess
              || download.isPending}
          >
            {confirmLabel}
          </button>
        </div>
      )}
    </div>
  );
}

/* The estimate is real planning work on the server. Waiting for the
   selection to settle turns five quick taps into one request. */
function useSettled<T>(value: T, ms: number): T {
  const [settled, setSettled] = useState(value);
  useEffect(() => {
    const id = setTimeout(() => setSettled(value), ms);
    return () => clearTimeout(id);
  }, [value, ms]);
  return settled;
}

/* The box is drawn here, not by the browser, so a checkbox looks like the
   rest of the application rather than like the operating system. The tick
   comes from the shared icon set; `aria-hidden` because the real input
   already carries the state. */
function CheckRow({ text, checked, onChange, disabled }: {
  text: string;
  checked: boolean;
  onChange: () => void;
  disabled?: boolean;
}) {
  return (
    <Checkbox
      className="region-check group/check flex cursor-pointer items-center gap-2 disabled:cursor-default disabled:opacity-55"
      isSelected={checked}
      onChange={onChange}
      isDisabled={disabled ?? false}
    >
      <span className={BOX} aria-hidden="true">
        <Check size={14} />
      </span>
      <span className="panel-note">{text}</span>
    </Checkbox>
  );
}

/* Countries disclose their states and cities; any mix across any number of
   countries rides in one download.

   The disclosure and the checkboxes used to be native elements. They were
   replaced for looks, not behaviour: a `summary` marker and a system
   checkbox are drawn by the platform and matched nothing else on screen. */
function RegionPicker() {
  const [filter, setFilter] = useState("");
  const [opened, setOpened] = useState(new Set<string>());
  const [selected, setSelected] = useState(new Map<string, Choice>());
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
      <label
        htmlFor="region-filter"
        className="panel-label mt-0.5 mb-1.5 block"
      >
        {m.map_download_region_label()}
      </label>
      <input
        id="region-filter"
        className="region-filter field min-h-10 px-2.5 py-2"
        type="search"
        placeholder={m.map_download_region_filter()}
        value={filter}
        onChange={(e) => setFilter(e.target.value)}
      />
      <ul className="region-tree my-2 max-h-[min(45vh,21rem)] divide-y divide-line overflow-y-auto border border-line">
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
              <Disclosure
                className="region-disclosure group/disclosure"
                isExpanded={needle !== "" || opened.has(code)}
                onExpandedChange={(open) =>
                  setOpened((previous) => {
                    const next = new Set(previous);
                    if (open) next.add(code);
                    else next.delete(code);
                    return next;
                  })}
              >
                <Button
                  slot="trigger"
                  className="region-summary focus-ring flex min-h-10 w-full cursor-pointer items-center gap-1.5 p-2.5 text-left text-sm group-expanded/disclosure:font-semibold"
                >
                  <ChevronRight
                    size={14}
                    aria-hidden="true"
                    className="flex-none text-ink-soft transition-transform group-expanded/disclosure:rotate-90"
                  />
                  {label}
                </Button>
                <DisclosurePanel className="region-children">
                  <CheckRow
                    text={m.map_download_region_whole()}
                    checked={selected.has(whole.key)}
                    onChange={() => toggle(whole)}
                  />
                  {subs.length > 0 && (
                    <PanelSection
                      className="region-sub"
                      title={m.map_download_region_sub_label()}
                    >
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
                    </PanelSection>
                  )}
                  {cities.length > 0 && (
                    <PanelSection
                      className="region-sub"
                      title={m.map_download_region_cities()}
                    >
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
                    </PanelSection>
                  )}
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

  const partOfBaseMap = entry.overview || entry.file === "";
  const ageUnknown = entry.completed === 0;

  const stale = !partOfBaseMap
    && days > 0
    && (ageUnknown
      || Date.now() / 1000 - entry.completed > days * 86_400);
  const size = formatBytes(entry.bytes);
  const meta = entry.overview
    ? m.map_ledger_overview({ size })
    : ageUnknown
      ? m.map_ledger_age_unknown({ size })
      : m.map_ledger_meta({
        size,
        date: new Intl.DateTimeFormat(getLocale(), { dateStyle: "medium" })
          .format(new Date(entry.completed * 1000)),
      });

  return (
    <li className="ledger-row">
      <div className="ledger-row-text">
        <span className="panel-label ledger-name">
          {entry.overview ? m.map_name_world() : entry.name}
        </span>
        <span className="panel-note hint">
          {meta}
          {stale && (
            <>
              {" "}
              <span className="ledger-stale font-semibold text-accent-text">
                {m.map_ledger_stale()}
              </span>
            </>
          )}
        </span>
      </div>
      <div className="download-actions flex-shrink">
          !partOfBaseMap && (
            <button
              type="button"
              className="ledger-update btn btn-quiet border-line-strong"
              onClick={() => update.mutate(entry.id, loudly)}
              disabled={busy || update.isPending || remove.isPending}
            >
              {m.map_ledger_update()}
            </button>
          )
        {
          !entry.overview
          && (entry.file
            ? (
              <a
                className={`button-link ledger-export ${LINK_BUTTON}`}
                href={regionUrl(entry.file)}
                download={entry.file}
              >
                {m.map_ledger_save()}
              </a>
            )
            : (
              <button
                type="button"
                className="ledger-export btn btn-quiet border-line-strong"
                onClick={() => exportMap.mutate(entry.id, loudly)}
                disabled={busy || update.isPending || remove.isPending
                  || exportMap.isPending}
              >
                {m.map_export_action()}
              </button>
            ))
        }
        {
          !partOfBaseMap && (
            <button
              type="button"
              className="ledger-remove btn btn-quiet border-line-strong"
              onClick={() => {
                if (!confirming) setConfirming(true);
                else remove.mutate(entry.id, loudly);
              }}
              disabled={busy || update.isPending || remove.isPending}
            >
              {confirming ? m.map_ledger_confirm() : m.map_ledger_remove()}
            </button>
          )
        }
      </div>
    </li>
  );
}

/* Saving is a plain link to a GET, not a blob the page built: the file is
   already on disk, and a country-sized one would be gigabytes on the heap.*/
function ExportedFiles({ busy }: { busy: boolean; }) {
  const exports = useBasemapExports();
  const remove = useDeleteExport();
  if (!exports.isSuccess || exports.data.length === 0) return null;
  return (
    <PanelSection
      className="download-option download-exports"
      title={m.map_export_title()}
    >
      <p className="panel-note hint">{m.map_export_hint()}</p>
      <ul className="ledger-rows divide-y divide-line">
        {exports.data.map((f) => (
          <li
            className="ledger-row"
            key={f.file}
          >
            <div className="ledger-row-text">
              <span className="panel-label ledger-name">
                {f.file}
              </span>
              <span className="panel-note hint">{formatBytes(f.bytes)}</span>
            </div>
            <div className="download-actions flex-shrink">
              <a
                className={`button-link ${LINK_BUTTON}`}
                href={exportUrl(f.file)}
                download={f.file}
              >
                {m.map_export_save()}
              </a>
              <button
                type="button"
                className="btn btn-quiet border-line-strong"
                onClick={() => remove.mutate(f.file, loudly)}
                disabled={busy || remove.isPending}
              >
                {m.map_export_delete()}
              </button>
            </div>
          </li>
        ))}
      </ul>
    </PanelSection>
  );
}

function ImportFromFile({ busy }: { busy: boolean; }) {
  const staged = useStagedImport();
  const upload = useUploadImport();
  const commit = useCommitImport();
  const discard = useDiscardImport();
  /* Recorded, not announced. The merge runs for minutes and can fail*/
  const startImport = useAppStore((s) => s.startImport);
  const [sent, setSent] = useState<{ done: number; total: number; } | null>(
    null,
  );
  const stagedData = staged.data;
  const waiting: StagedReady | null = stagedData?.staged ? stagedData : null;

  return (
    <PanelSection
      className="download-option download-import"
      title={m.map_import_title()}
      info={m.map_import_hint()}
    >
      {waiting === null && (
        <>
          {
            /* A real file input, hidden rather than removed, so it keeps
              its accessible name and its keyboard behaviour*/
          }
          <input
            id="import-file"
            className="peer sr-only"
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
          <div className="download-actions mt-2.5">
            <label
              className={`button-link file-input ${LINK_BUTTON} peer-focus-visible:outline-2 peer-focus-visible:outline-offset-2 peer-focus-visible:outline-accent`}
              htmlFor="import-file"
            >
              {m.map_import_choose()}
            </label>
          </div>
          {upload.isPending && sent !== null && (
            <p className="panel-note hint" role="status">
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
          <p className="panel-note hint">
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
          <div className="download-actions mt-2.5">
            <button
              type="button"
              className="btn btn-primary"
              onClick={() =>
                commit.mutate(undefined, {
                  ...loudly,
                  onSuccess: () => startImport(),
                })}
              disabled={busy || commit.isPending}
            >
              {m.map_import_confirm()}
            </button>
            <button
              type="button"
              className="btn btn-quiet border-line-strong"
              onClick={() => discard.mutate(undefined, loudly)}
              disabled={busy || commit.isPending || discard.isPending}
            >
              {m.map_import_discard()}
            </button>
          </div>
        </>
      )}
    </PanelSection>
  );
}

function DownloadedMaps({ busy }: { busy: boolean; }) {
  const ledger = useBasemapLedger();
  const settings = useBasemapSettings();
  const save = useSaveBasemapSettings();
  if (!ledger.isSuccess || ledger.data.entries.length === 0) return null;
  const days = settings.data?.update_reminder_days ?? 90;
  return (
    <PanelSection
      className="download-option download-ledger"
      title={m.map_ledger_title()}
    >
      <ul className="ledger-rows divide-y divide-line">
        {ledger.data.entries.map((entry) => (
          <LedgerRow key={entry.id} entry={entry} days={days} busy={busy} />
        ))}
      </ul>
      <Dropdown
        className="ledger-reminder mt-2.5 text-sm [&>.dropdown-button]:w-auto [&>.dropdown-button]:flex-none"
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
    </PanelSection>
  );
}

function BrowseToggle() {
  const settings = useBasemapSettings();
  const save = useSaveBasemapSettings();
  return (
    <div className="download-option download-browse flex items-center">
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
      <InfoTip label={m.map_browse_hint()} />
    </div>
  );
}

export function DownloadCard({ region }: { region: Region; }) {
  const closeDownload = useAppStore((s) => s.closeDownload);
  const job = useBasemapStatus({ follow: true }).data?.job;
  const viewName = useMemo(
    () =>
      placeAt(
        (region.min_lon + region.max_lon) / 2,
        (region.min_lat + region.max_lat) / 2,
      ),
    [region.min_lon, region.max_lon, region.min_lat, region.max_lat],
  );

  const running = job !== undefined && isRunning(job);

  return (
    <PanelSection
      className="download-card min-w-0"
      title={m.map_download_title()}
      action={
        <IconButton
          label={m.map_download_close()}
          icon={<X size={16} aria-hidden />}
          onClick={closeDownload}
        />
      }
    >
      {!running && (
        <>
          <Offer
            regions={[region]}
            regionLabel={viewName}
            ledgerLabel={viewName}
            describe={(size) => m.map_download_estimate({ size })}
            confirmLabel={m.map_download_confirm()}
            className="download-view"
          />
          <RegionPicker />
        </>
      )}
      <DownloadedMaps busy={running} />
      <ExportedFiles busy={running} />
      <ImportFromFile busy={running} />
      <BrowseToggle />
    </PanelSection>
  );
}
