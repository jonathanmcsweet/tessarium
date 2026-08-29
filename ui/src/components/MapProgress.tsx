/* What the map downloads are doing, in the side panel.

   Separate from the download card on purpose. The card is where a download
   is CHOSEN, and it is closed the moment the choosing is done; the progress
   of six countries fetched over an hour belongs somewhere that stays put.
   So the card starts the work and this reports it, and closing the card
   costs nothing.

   The rows are per region, which is the whole point of it: "downloading, 40%"
   over a selection of six countries tells a user nothing about whether the
   one they actually need has arrived. Bytes per row are what the network
   delivered for that region -- the server attributes each tile to the pick
   that asked for it, and charges a tile wanted by two picks to the first
   only, so the rows never sum past what was fetched. */

import { X } from "lucide-react";
import { type Job, useBasemapCancel, useBasemapStatus } from "../core/basemap";
import { formatBytes } from "../i18n";
import { m } from "../paraglide/messages";
import { toastError } from "../toast";
import { IconButton } from "./IconButton";

const loudly = {
  onError: (e: unknown) =>
    toastError(e instanceof Error ? e.message : String(e)),
};

/* A bar plus its numbers, said once so every row says it the same way.
   `<progress>` carries the value to assistive technology by itself; the
   visible text is the same fact for everyone else, and `aria-hidden` on it
   keeps a screen reader from reading the pair twice. */
function Bar(
  { label, done, total, hint }: {
    label: string;
    done: number;
    total: number;
    /* Explicitly `| undefined`: exactOptionalPropertyTypes is on, so an
       optional property and one that may be undefined are different types,
       and the caller passes undefined to mean "just show the numbers". */
    hint?: string | undefined;
  },
) {
  return (
    <li className="download-row">
      <div className="download-row-head">
        <span className="download-row-label">{label}</span>
        <span className="download-row-size" aria-hidden="true">
          {hint ?? `${formatBytes(done)} / ${formatBytes(total)}`}
        </span>
      </div>
      <progress
        max={Math.max(total, 1)}
        value={done}
        aria-label={m.map_progress_region_a11y({
          region: label,
          done: formatBytes(done),
          total: formatBytes(total),
        })}
      />
    </li>
  );
}

/* The states that are one job with one number. Region rows only exist while
   tiles are being fetched; everything else here is a whole-archive
   operation and has nothing to break down. */
function Simple({ job }: { job: Job; }) {
  switch (job.state) {
    case "planning":
      return <p className="hint">{m.map_download_planning()}</p>;
    case "assets":
      return <p className="hint">{m.map_download_assets()}</p>;
    case "indexing":
      return (
        <p className="hint">
          {m.map_indexing_progress({
            done: job.done_tiles,
            total: job.total_tiles,
          })}
        </p>
      );
    case "removing":
      return (
        <p className="hint">
          {m.map_removing_progress({
            done: formatBytes(job.done_bytes),
            total: formatBytes(job.total_bytes),
          })}
        </p>
      );
    case "compacting":
      return (
        <p className="hint">
          {m.map_compacting_progress({
            done: formatBytes(job.done_bytes),
            total: formatBytes(job.total_bytes),
          })}
        </p>
      );
    case "exporting":
      return (
        <ul className="download-rows mt-2 space-y-2.5">
          <Bar
            label={m.map_export_writing()}
            done={job.done_bytes}
            total={job.total_bytes}
          />
        </ul>
      );
    default:
      return null;
  }
}

export function MapProgress() {
  const status = useBasemapStatus();
  const cancel = useBasemapCancel();
  const job = status.data?.job;

  /* Quiet unless there is something happening. A panel that always carried a
     "no downloads" line would spend its life saying nothing. */
  if (!job) return null;
  const busy = job.state === "planning" || job.state === "fetching"
    || job.state === "assets" || job.state === "removing"
    || job.state === "compacting" || job.state === "indexing"
    || job.state === "exporting";
  if (!busy) return null;

  const rows = job.state === "fetching" ? job.regions : [];

  return (
    <section
      className="downloads"
      aria-labelledby="downloads-title"
    >
      <div className="downloads-head">
        {
          /* An export is not a download, and this section said "Map
            downloads" over "Writing the file" while one ran. Same bars,
            honest heading. */
        }
        <h2 id="downloads-title">
          {job.state === "exporting"
            ? m.map_progress_export_title()
            : m.map_progress_title()}
        </h2>
        <IconButton
          label={m.map_download_cancel()}
          icon={<X size={16} aria-hidden />}
          onClick={() => cancel.mutate(undefined, loudly)}
          disabled={cancel.isPending}
        />
      </div>

      {
        /* Polite, not assertive: this updates every second, and an assertive
          region would talk over everything else the user is doing. */
      }
      <div role="status" aria-live="polite" aria-atomic="false">
        {rows.length > 0
          ? (
            <ul className="download-rows mt-2 space-y-2.5">
              {rows.map((r, i) => (
                <Bar
                  // biome-ignore lint/suspicious/noArrayIndexKey: the server returns one row per requested region in request order, and that list is fixed for the life of the download -- position IS the identity here. Labels cannot serve as one: two cities can share a name.
                  key={i}
                  label={r.label || m.map_progress_unnamed()}
                  done={r.done_bytes}
                  total={r.total_bytes}
                  hint={r.total_bytes > 0 && r.done_bytes >= r.total_bytes
                      && r.planned
                    ? m.map_progress_row_done()
                    : !r.planned
                    ? m.map_progress_row_measuring()
                    : undefined}
                />
              ))}
            </ul>
          )
          : <Simple job={job} />}

        {job.state === "fetching" && (
          <p className="hint download-overall mt-2.5 tabular-nums">
            {job.parts > 1
              ? m.map_progress_overall_part({
                done: formatBytes(job.done_bytes),
                total: formatBytes(job.total_bytes),
                part: job.part,
                parts: job.parts,
              })
              : m.map_progress_overall({
                done: formatBytes(job.done_bytes),
                total: formatBytes(job.total_bytes),
              })}
          </p>
        )}
      </div>
    </section>
  );
}
