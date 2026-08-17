/* The offline-maps card: estimate for the region it was opened on, confirm,
   progress, cancel.

   Not a modal. It sits over the map's corner and traps nothing -- the map
   stays usable behind it, which matters because looking at the map is how a
   user decides the region is right. The region is frozen at the moment the
   card opens; panning afterwards changes the next download, not this one. */

import { X } from "lucide-react";
import { toast } from "sonner";
import {
  isRunning,
  type Job,
  type Region,
  useBasemapCancel,
  useBasemapDownload,
  useBasemapEstimate,
} from "../core/basemap";
import { formatBytes } from "../i18n";
import { m } from "../paraglide/messages";
import { useAppStore } from "../store";
import { IconButton } from "./IconButton";

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
  return (
    <>
      <progress
        value={job.done_bytes}
        max={Math.max(1, job.total_bytes)}
        aria-label={m.map_download_progress({ done, total })}
      />
      <p className="hint">{m.map_download_progress({ done, total })}</p>
    </>
  );
}

export function DownloadCard({ region, job }: {
  region: Region;
  job: Job | undefined;
}) {
  const closeDownload = useAppStore((s) => s.closeDownload);
  const estimate = useBasemapEstimate(region);
  const download = useBasemapDownload();
  const cancel = useBasemapCancel();

  const running = job !== undefined && isRunning(job);

  /* A refused start -- another download already running, a server gone away
     -- must be audible, not swallowed. */
  const loudly = {
    onError: (e: unknown) =>
      toast.error(e instanceof Error ? e.message : String(e)),
  };

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
            {estimate.isPending && (
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
              estimate.data.tiles === 0
                ? <p className="hint">{m.map_download_none()}</p>
                : (
                  <p className="hint">
                    {m.map_download_estimate({
                      size: formatBytes(estimate.data.total_bytes),
                    })}
                  </p>
                )
            )}
            <div className="download-actions">
              <button
                type="button"
                onClick={() => download.mutate(region, loudly)}
                disabled={!estimate.isSuccess || estimate.data.tiles === 0
                  || download.isPending}
              >
                {m.map_download_confirm()}
              </button>
            </div>
          </>
        )}
    </section>
  );
}
