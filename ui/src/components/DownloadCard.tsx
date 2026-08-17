/* The offline-maps card.

   Two offers, not one. Until an archive exists every choice is a grey
   guess -- there is nothing on screen to aim the viewport with -- so the
   card leads with the whole world at country level, and only then offers
   detail for the current view. Once the world map is down it stops being
   mentioned; from there the flow is: find the place on the world map, zoom,
   download the view.

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
  useBasemapPresent,
  WORLD,
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
  const present = useBasemapPresent();
  /* Only certainty hides the world offer: while the HEAD is in flight the
     card shows the view option alone rather than guessing. */
  const worldFirst = present.data === false;
  const world = useBasemapEstimate(worldFirst ? WORLD : null);
  const view = useBasemapEstimate(region);
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
            {worldFirst && (
              <div className="download-option download-world">
                <p className="hint">
                  {world.isPending
                    ? m.map_download_estimating()
                    : world.isSuccess
                    ? m.map_download_world_estimate({
                      size: formatBytes(world.data.total_bytes),
                    })
                    : world.error instanceof Error
                    ? world.error.message
                    : String(world.error)}
                </p>
                <div className="download-actions">
                  <button
                    type="button"
                    onClick={() => download.mutate(WORLD, loudly)}
                    disabled={!world.isSuccess || world.data.tiles === 0
                      || download.isPending}
                  >
                    {m.map_download_world_confirm()}
                  </button>
                </div>
              </div>
            )}
            <div className="download-option download-view">
              {view.isPending && (
                <p className="hint">{m.map_download_estimating()}</p>
              )}
              {view.isError && (
                <p className="hint invalid">
                  {view.error instanceof Error
                    ? view.error.message
                    : String(view.error)}
                </p>
              )}
              {view.isSuccess && (
                <p className="hint">
                  {view.data.covered
                    ? m.map_download_covered()
                    : view.data.tiles === 0
                    ? m.map_download_none()
                    : m.map_download_estimate({
                      size: formatBytes(view.data.total_bytes),
                    })}
                </p>
              )}
              <div className="download-actions">
                <button
                  type="button"
                  onClick={() => download.mutate(region, loudly)}
                  disabled={!view.isSuccess || view.data.tiles === 0
                    || download.isPending}
                >
                  {m.map_download_confirm()}
                </button>
              </div>
            </div>
          </>
        )}
    </section>
  );
}
