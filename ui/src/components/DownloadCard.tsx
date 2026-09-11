/* The offline-maps card.

   Two offers: detail for the current view, and any mix of countries, states
   and cities picked from a filterable tree. The planet is not one of them --
   every package ships the world overview at the depth the map draws it, so
   there is nothing left to offer for it.

   A selection travels as ONE download. The server plans all its regions
   together and dedups overlapping tiles, so a country plus one of its
   cities pays for the shared tiles once. Every offer has the same shape:
   estimate, then confirm.

   The view region is frozen when the card opens. Panning afterwards changes
   the next download, not this one. */

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
import { LoadingTiles } from "./LoadingTiles";
import { InfoTip } from "./Tip";

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
const LINK_BUTTON = "btn btn-quiet border-line-strong hover:border-accent";

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

/* One offer: its estimate, its caveats, its button. Shared by the current
   view and the picker's selection, so the two cannot drift.

   Nothing here offers the planet. Every package carries the world overview
   at the depth the map ever draws it, so there is no world left to fetch --
   only the regions someone picks for street detail. */
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
    /* Aligned with regions. Lets the depth warning name the picks that are
       too big for street level. The world and the view get generic
       wording. */
    names?: string[];
    /* What the progress panel calls this offer's regions when there are no
       per-pick names -- the world and the current view. Every download path
       sends one, so the progress bar and the ledger row cannot disagree.

       Explicitly `| undefined`: exactOptionalPropertyTypes is on, so an
       optional property and one that may be undefined are different types,
       and over open water the catalogue has no name to give. */
    regionLabel?: string | undefined;
    /* What the downloaded-maps list will call this, in the user's locale.
       Undefined for the world overview, which is not listed there. */
    ledgerLabel: string | undefined;
    describe: (size: string) => string;
    confirmLabel: string;
    className: string;
  },
) {
  /* Priced on the bare regions: a label would become part of the query key
     for an answer that is only about tiles. */
  const estimate = useBasemapEstimate(regions);
  const download = useBasemapDownload();
  /* Downloaded with the label INSIDE each region -- see LabelledRegion. A
     parallel array could be one short or out of order and still pass. */
  const labelled: LabelledRegion[] | null = regions === null ? null : regions
    .map((region, i) => {
      const label = names?.[i] ?? regionLabel;
      return label === undefined ? region : { ...region, label };
    });
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
  /* Nothing to write: covered means the archive holds every tile the source
     has here, zero tiles means the source has none. Either way there is no
     download, so no button.

     There used to be one: a covered estimate turned the confirm into "Keep
     track of this map", from when the server could record a held area
     without fetching. That is gone -- a covered area writes nothing and the
     job fails -- so every press produced a failed job and an error toast,
     from a button the card had offered. */
  const nothingToWrite = estimate.isSuccess
    && (estimate.data.covered || estimate.data.tiles === 0);
  return (
    <div className={`download-option ${className}`}>
      {
        /* `role="status"`, which it did not have: the sentence appears on its
           own after a selection settles, and a wait nobody is told about is a
           card that has gone quiet. */
      }
      {regions !== null && estimate.isPending && (
        <p className="hint estimating flex items-center gap-2" role="status">
          <LoadingTiles />
          {m.map_download_estimating()}
        </p>
      )}
      {estimate.isError && (
        <p className="hint invalid text-danger">
          {estimate.error instanceof Error
            ? estimate.error.message
            : String(estimate.error)}
        </p>
      )}
      {estimate.isSuccess && (
        <p className={`hint${nothingToWrite ? " download-held" : ""}`}>
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
      {!nothingToWrite && (
        <div className="download-actions mt-2.5 flex flex-wrap gap-2">
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

/* A pick: a country, one of its states, or a city. One pick can be several
   regions -- a country astride the antimeridian is two boxes. The label is
   what the selection count and the depth warning name. */
type Choice = { key: string; label: string; regions: Region[]; };

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
      <span>{text}</span>
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
  /* Which countries the user has opened. A filter overrides it and forces
     every match open, so the hits are visible without hunting. */
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
      <label
        htmlFor="region-filter"
        className="mt-0.5 mb-1.5 block text-sm font-semibold"
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
      {
        /* The picker's tree. It scrolls inside the card so the selection's
          estimate and its download button stay in reach below the list. */
      }
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
              {
                /* A filter forces every match open; with no filter,
                  `opened` decides. */
              }
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

/* One downloaded region: what it is, how old it is, and its buttons.
   Staleness comes from the recorded date and the reminder threshold;
   completed = 0 means the tiles predate the ledger and their age is
   unknown, which counts as stale. Remove takes two presses of the same
   button, because it discards gigabytes. */
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
  /* Whether this row is part of the base map rather than somebody's
     download. It decides whether the row gets any buttons.

     An empty `file` means the entry has no archive of its own: its tiles sit
     in the shared map.pmtiles, written by tools/fetch-basemap.sh or by an
     install from before downloads split one file per region. Removing such
     an entry rewrites that whole file, or unlinks it when the last entry
     goes.

     Judged by where the tiles live, not by what they cover. Judging by
     coverage left a merged London box called "Map view" with Remove beside
     it, even though removing it would rewrite the base map. The base map is
     removed with a file manager, not from here. */
  const partOfBaseMap = entry.overview || entry.file === "";
  const ageUnknown = entry.completed === 0;
  /* Never on a base-map row, by the SAME rule that decides the buttons: the
     nudge invites a press of one of them. Gated on `overview` alone, an old
     merged entry (completed = 0, so ageUnknown, so stale at any threshold)
     wore a permanent "Update available" beside no buttons at all, and only
     setting the reminder to Never silenced it. */
  const stale = !partOfBaseMap
    && days > 0
    && (ageUnknown
      || Date.now() / 1000 - entry.completed > days * 86_400);
  const size = formatBytes(entry.bytes);
  const meta = entry.overview
    /* Says what the row IS, which is also why it has no buttons. */
    ? m.map_ledger_overview({ size })
    : ageUnknown
    ? m.map_ledger_age_unknown({ size })
    : m.map_ledger_meta({
      size,
      date: new Intl.DateTimeFormat(getLocale(), { dateStyle: "medium" })
        .format(new Date(entry.completed * 1000)),
    });
  /* The row's shell is three utilities in styles.css because the
     exported-files list below draws the same shell, and the wrapping they
     carry is a fix. Pasted into both, it would drift. */
  return (
    <li className="ledger-row">
      <div className="ledger-row-text">
        <span className="ledger-name">
          {
            /* Named here, not by the server, which knows nothing of the
               reader's language. The recorded name is unusable anyway:
               blank on a row synthesised from a file, and whatever the
               picker happened to call it on an old install. */
          }
          {entry.overview ? m.map_name_world() : entry.name}
        </span>
        <span className="hint">
          {meta}
          {stale && (
            <>
              {" "}
              {
                /* Text, not a traffic light: accent-text holds 4.5:1 on
                  the card where the brighter accent would not. */
              }
              <span className="ledger-stale font-semibold text-accent-text">
                {m.map_ledger_stale()}
              </span>
            </>
          )}
        </span>
      </div>
      {
        /* Each button carries its own class, so anything reaching for one
           finds it by what it does rather than by its position. Adding the
           third button silently retargeted selectors written by
           position. */
      }
      <div className="download-actions flex flex-shrink flex-wrap gap-2">
        {
          /* No Update either, so the overview row has no buttons at all.

             An update re-downloads an entry's own regions under its recorded
             name. The overview has no record -- the row is built from the
             file -- and an old install's record would re-fetch the whole
             planet AS DETAIL: a world-sized download leaving a removable
             duplicate of the map everything else draws on. Deepening the
             planet is the world offer above the list instead.

             Off for every base-map row for a second reason: an update writes
             a NEW file and leaves the merged row where it is, so it would
             leave a duplicate that can never be taken away. */
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
        }
        {
          /* Nothing to carry: every package (tools/package.sh, the .deb,
            the .rpm, the offline bundle) puts a world overview in basemap/,
            so the machine it would be carried to already has one. */
          !entry.overview
          /* A link when the region has a file of its own -- every region
             downloaded since downloads stopped merging. The file the
             download wrote IS the file to carry: no job to wait on, no
             second copy on disk.

             A region still inside the old merged archive keeps the button,
             because it has to be extracted first. */
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
          /* No Remove on anything that is part of the base map: it would
            rewrite or unlink the archive the whole application draws from,
            to take away one row, and offline there is no getting it back.

            The server refuses these ids too. This half keeps the button
            from being there to press. */
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

/* Files waiting to be carried away.

   Saving is a plain link to a GET, not a blob the page built: the file is
   already on disk, and a country-sized one would be gigabytes on the heap.
   The link streams and resumes. */
function ExportedFiles({ busy }: { busy: boolean; }) {
  const exports = useBasemapExports();
  const remove = useDeleteExport();
  if (!exports.isSuccess || exports.data.length === 0) return null;
  return (
    <div className="download-option download-exports">
      <p className="region-group">
        {m.map_export_title()}
      </p>
      <p className="hint">{m.map_export_hint()}</p>
      <ul className="ledger-rows divide-y divide-line">
        {exports.data.map((f) => (
          <li
            className="ledger-row"
            key={f.file}
          >
            <div className="ledger-row-text">
              <span className="ledger-name">
                {f.file}
              </span>
              <span className="hint">{formatBytes(f.bytes)}</span>
            </div>
            <div className="download-actions flex flex-shrink flex-wrap gap-2">
              {
                /* `download` names the saved file rather than navigating to
                  it; same origin, so the CSP is untroubled. */
              }
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
    </div>
  );
}

/* Adding maps from a file.

   A file input, not a path box: the operating system's picker reaches a USB
   stick, a phone or a network share without this app knowing about any of
   them, and it is the only thing that works under Flatpak, where the app is
   sandboxed away from the filesystem but the browser is not.

   Two steps. The file goes up and is DESCRIBED first -- what it holds, how
   deep, how big -- and a second press merges it. A gigabyte of the wrong
   country should cost a glance, not a merge. */
function ImportFromFile({ busy }: { busy: boolean; }) {
  const staged = useStagedImport();
  const upload = useUploadImport();
  const commit = useCommitImport();
  const discard = useDiscardImport();
  /* Recorded, not announced. The merge runs for minutes and can fail, so
     this only says which words its ending deserves. The map watches the
     poll, so a user who closed the card still hears it. */
  const startImport = useAppStore((s) => s.startImport);
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
      {
        /* The sentence rides the heading rather than standing under it. It
          says what the section is for, which is worth having once and is not
          worth the vertical space above the control every time the card is
          opened. */
      }
      <p className="region-group">
        {m.map_import_title()}
        <InfoTip label={m.map_import_hint()} />
      </p>

      {waiting === null && (
        <>
          {
            /* A real file input, hidden rather than removed, so it keeps
              its accessible name and its keyboard behaviour; the visible
              label drives it.

              The input comes FIRST in the DOM so the label can show the
              focus: what is focused is the off-screen input, and `peer`
              only reads an earlier sibling. */
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
          <label
            className={`button-link file-input mt-2.5 ${LINK_BUTTON} peer-focus-visible:outline-2 peer-focus-visible:outline-offset-2 peer-focus-visible:outline-accent`}
            htmlFor="import-file"
          >
            {m.map_import_choose()}
          </label>
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
          <div className="download-actions mt-2.5 flex flex-wrap gap-2">
            <button
              type="button"
              className="btn btn-primary"
              /* No success toast. The server answers as soon as it has
                 forked the job, so "Those maps were added" appeared while
                 the merge still had minutes to run -- and a merge that then
                 failed contradicted it. The flag is set instead; the ending
                 is reported when the job reaches it. */
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
    </div>
  );
}

/* The downloaded-maps list and the one setting that governs it. Rendered
   only when something is recorded: an empty list says nothing the offers
   above it do not. */
function DownloadedMaps({ busy }: { busy: boolean; }) {
  const ledger = useBasemapLedger();
  const settings = useBasemapSettings();
  const save = useSaveBasemapSettings();
  if (!ledger.isSuccess || ledger.data.entries.length === 0) return null;
  const days = settings.data?.update_reminder_days ?? 90;
  return (
    <div className="download-option download-ledger">
      <p className="region-group">
        {m.map_ledger_title()}
      </p>
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
    </div>
  );
}

/* The one setting that makes this application reach the network without a
   click: fetching the tiles you are looking at, as you look. Opt-in and
   server-gated. */
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

export function DownloadCard({ region }: { region: Region; }) {
  const closeDownload = useAppStore((s) => s.closeDownload);
  /* Subscribed HERE rather than passed down from the panel. The poll ticks
     once a second for the life of a job, and holding it in the panel
     re-rendered the address, the coordinates and the footer every second of
     an hour-long download, card closed. The map and the progress section
     keep the poll alive while this card is shut.

     A FOLLOWER: mounting must not refetch. The poll stops whenever nothing
     is running, so a job that ended unobserved would be fetched by this
     mount and delivered as fresh news -- and the map closes the card on a
     job's ending. Opening the card closed it again. */
  const job = useBasemapStatus({ follow: true }).data?.job;

  /* What a download of the current view is called: where its middle is --
     "London", not "Map view". The generic phrase said only that a download
     had happened, and got mistaken for the base map.

     Undefined over open water, where the catalogue has nothing to offer.
     The Offer then sends no name and the server writes one from the box's
     corners: ugly, and true.

     Recomputed only when the view moves. The lookup walks 1198 city boxes
     and up to 177 border polygons. */
  const viewName = useMemo(
    () =>
      placeAt(
        (region.min_lon + region.max_lon) / 2,
        (region.min_lat + region.max_lat) / 2,
      ),
    [region.min_lon, region.max_lon, region.min_lat, region.max_lat],
  );

  const running = job !== undefined && isRunning(job);

  /* A section of the side panel, not a card over the map: floating in the
     corner it covered the tiles it was describing and could not grow past
     the viewport. The padding matches the panel head so the headings line
     up, and nothing inside may push the drawer wider than the user set
     it. */
  return (
    <section
      className="download-card min-w-0 border-t border-line px-4.5 py-3.5"
      aria-labelledby="download-title"
    >
      <header className="flex items-center justify-between gap-2">
        <h2 id="download-title" className="panel-title">
          {m.map_download_title()}
        </h2>
        <IconButton
          label={m.map_download_close()}
          icon={<X size={16} aria-hidden />}
          onClick={closeDownload}
        />
      </header>

      {
        /* No progress bar and no cancel here. Both live in MapProgress,
          one section up the same panel, which reports per REGION and stays
          put when this card is closed. Two of each in one panel is one
          download described twice, with two cancel buttons. */
      }
      {
        /* Only the ways to START another download are hidden while one
          runs. Everything below stays, disabled through `busy`. */
      }
      {!running && (
        <>
          {
            /* One name for both. Only the ledger used to be told, so the
              bar said "Unnamed area" through a download the list called
              "London". */
          }
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
    </section>
  );
}
