/* The offline-maps card.

   Offers, in order of usefulness: the whole world at country level when
   nothing is on disk (there is nothing on screen to aim a viewport with
   until it exists), detail for the current view, and a country or state
   picked by name -- the way the established offline map apps do it, because
   aiming a viewport at Portugal is work a list does better.

   Every offer runs through the same estimate-then-confirm shape: what it
   costs, whether it is already held, whether a big area stops at regional
   detail. Downloads merge, so offers compose instead of replacing each
   other.

   Not a modal. It sits over the map's corner and traps nothing -- the map
   stays usable behind it, which matters because looking at the map is how a
   user decides the region is right. The view region is frozen at the moment
   the card opens; panning afterwards changes the next download, not this
   one. */

import { X } from "lucide-react";
import { useState } from "react";
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
import { countries, subdivisionsOf, toRegion } from "../regions";
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

/* One offer: its estimate, its caveats, its button. Shared by the world,
   the current view, and a picked region, so the three cannot drift. */
function Offer({ region, describe, confirmLabel, className }: {
  region: Region | null;
  describe: (size: string) => string;
  confirmLabel: string;
  className: string;
}) {
  const estimate = useBasemapEstimate(region);
  const download = useBasemapDownload();
  return (
    <div className={`download-option ${className}`}>
      {region !== null && estimate.isPending && (
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
      {estimate.isSuccess && !estimate.data.covered && estimate.data.tiles > 0
        && region !== null && estimate.data.max_zoom < region.max_zoom && (
        <p className="hint">{m.map_download_depth_hint()}</p>
      )}
      <div className="download-actions">
        <button
          type="button"
          onClick={() => region && download.mutate(region, loudly)}
          disabled={region === null || !estimate.isSuccess
            || estimate.data.tiles === 0 || estimate.data.covered
            || download.isPending}
        >
          {confirmLabel}
        </button>
      </div>
    </div>
  );
}

/* Countries and states by name. Selects rather than anything fancier: they
   are natively accessible, natively mobile, and 177 entries is what they
   are for. */
function RegionPicker() {
  const [countryIdx, setCountryIdx] = useState("");
  const [subIdx, setSubIdx] = useState("");
  /* Re-sorted per render on purpose: the locale can change under a live
     picker, and "Germany" and "Allemagne" sort to different places. */
  const list = countries();
  const chosen = countryIdx === "" ? null : list[Number(countryIdx)] ?? null;
  const subs = chosen ? subdivisionsOf(chosen.country) : [];
  const sub = subIdx === "" ? null : subs[Number(subIdx)] ?? null;
  const box = sub?.bbox ?? chosen?.country.bbox ?? null;

  return (
    <div className="download-option download-region">
      <label htmlFor="region-country">{m.map_download_region_label()}</label>
      <select
        id="region-country"
        className="region-country"
        value={countryIdx}
        onChange={(e) => {
          setCountryIdx(e.target.value);
          setSubIdx("");
        }}
      >
        <option value="">{m.map_download_region_placeholder()}</option>
        {list.map((entry, i) => (
          <option key={entry.country.name} value={String(i)}>
            {entry.label}
          </option>
        ))}
      </select>
      {subs.length > 0 && (
        <select
          className="region-sub"
          aria-label={m.map_download_region_sub_label()}
          value={subIdx}
          onChange={(e) => setSubIdx(e.target.value)}
        >
          <option value="">{m.map_download_region_whole()}</option>
          {subs.map((entry, i) => (
            <option key={entry.name} value={String(i)}>{entry.name}</option>
          ))}
        </select>
      )}
      {box && (
        <Offer
          region={toRegion(box)}
          describe={(size) =>
            m.map_download_region_estimate({
              size,
              name: sub?.name ?? chosen?.label ?? "",
            })}
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
                region={WORLD}
                describe={(size) => m.map_download_world_estimate({ size })}
                confirmLabel={m.map_download_world_confirm()}
                className="download-world"
              />
            )}
            <Offer
              region={region}
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
