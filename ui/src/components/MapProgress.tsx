import {
  isRunning,
  type Job,
  useBasemapCancel,
  useBasemapStatus,
} from "../core/basemap";
import { formatBytes } from "../i18n";
import { m } from "../paraglide/messages";
import { toastError } from "../toast";
import { IconButton } from "./IconButton";
import { X } from "./icons";
import { PanelSection } from "./PanelSection";

const loudly = {
  onError: (e: unknown) =>
    toastError(e instanceof Error ? e.message : String(e)),
};

function Bar(
  { label, done, total, hint }: {
    label: string;
    done: number;
    total: number;
    hint?: string | undefined;
  },
) {
  const ceiling = Math.max(total, 1);
  return (
    <li className="download-row">
      <div className="flex items-baseline justify-between gap-2">
        <span className="panel-label ledger-name min-w-0">{label}</span>
        <span
          className="flex-none text-xs tabular-nums text-ink-soft"
          aria-hidden="true"
        >
          {hint ?? m.map_progress_bytes({
            done: formatBytes(done),
            total: formatBytes(total),
          })}
        </span>
      </div>
      <progress
        className="mt-1 h-1.5 w-full accent-accent"
        max={ceiling}
        value={done >= total ? ceiling : done}
        aria-label={m.map_progress_region_a11y({
          region: label,
          done: formatBytes(done),
          total: formatBytes(total),
        })}
      />
    </li>
  );
}

function Simple({ job }: { job: Job; }) {
  switch (job.state) {
    case "planning":
      return <p className="panel-note hint">{m.map_download_planning()}</p>;
    case "assets":
      return <p className="panel-note hint">{m.map_download_assets()}</p>;
    case "indexing":
      return (
        <p className="panel-note hint">
          {m.map_indexing_progress({
            done: job.done_tiles,
            total: job.total_tiles,
          })}
        </p>
      );
    case "removing":
      return (
        <p className="panel-note hint">
          {m.map_removing_progress({
            done: formatBytes(job.done_bytes),
            total: formatBytes(job.total_bytes),
          })}
        </p>
      );
    case "compacting":
      return (
        <p className="panel-note hint">
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

  if (!job || !isRunning(job)) return null;

  const rows = job.state === "fetching" ? job.regions : [];

  return (
    <PanelSection
      className="downloads"
      title={job.state === "exporting"
        ? m.map_progress_export_title()
        : m.map_progress_title()}
      action={
        <IconButton
          label={m.map_download_cancel()}
          icon={<X size={16} aria-hidden />}
          onClick={() => cancel.mutate(undefined, loudly)}
          disabled={cancel.isPending}
        />
      }
    >
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
                  hint={!r.planned
                    ? m.map_progress_row_measuring()
                    : r.done_bytes >= r.total_bytes
                    ? m.map_progress_row_done()
                    : undefined}
                />
              ))}
            </ul>
          )
          : <Simple job={job} />}

        {job.state === "fetching" && (
          <p className="panel-note hint download-overall mt-2.5 tabular-nums">
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
    </PanelSection>
  );
}
