/* The in-app map downloader's client side.

   These calls go to our own server, which does the actual fetching: the
   browser names a region of the world and nothing else. Where the tiles come
   from is the server's command line, so a compromised page cannot redirect
   the download — and the CSP's connect-src 'self' holds, because every
   request here is same-origin.

   All of it lives in React Query per the house rule for network state, and
   every response is parsed with zod rather than cast, same as the worker
   boundary and for the same reason. */

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { z } from "zod";

export type Region = {
  min_lon: number;
  min_lat: number;
  max_lon: number;
  max_lat: number;
  max_zoom: number;
  /* Outer rings of the region's border, when the catalogue knows them. The
     server clips the download to the polygon, so a country stops at its
     border instead of its bounding box. */
  polygon?: [number, number][][];
};

const Estimate = z.object({
  /* Bytes still to fetch: tiles already on disk are excluded server-side,
     so an area you already hold estimates at zero. */
  total_bytes: z.number().int().nonnegative(),
  tiles: z.number().int().nonnegative(),
  /* True when the source has tiles here but the archive already holds every
     one of them -- "you have this" rather than "there is nothing". */
  covered: z.boolean(),
  /* The depth the server's tile budget afforded, per requested region and
     in request order. Less than a region asked for means that pick was too
     big and stops at regional detail. */
  max_zooms: z.array(z.number().int()),
});
export type Estimate = z.infer<typeof Estimate>;

/* The whole world at country level -- the recommended first download, and
   what makes every later choice visible instead of a grey guess. Measured
   against the Protomaps planet build: zoom 6 is about 45 MB; zoom 7 would
   quadruple it. Downloads merge, so detail added later never re-pays for
   this. */
export const WORLD: Region = {
  min_lon: -180,
  min_lat: -85,
  max_lon: 180,
  max_lat: 85,
  max_zoom: 6,
};

const Job = z.discriminatedUnion("state", [
  z.object({ state: z.literal("idle") }),
  z.object({ state: z.literal("planning") }),
  z.object({
    state: z.literal("fetching"),
    done_bytes: z.number(),
    total_bytes: z.number(),
    /* Giants are fetched in parts; a small download is part 1 of 1. */
    part: z.number().int().min(1),
    parts: z.number().int().min(1),
  }),
  z.object({ state: z.literal("assets") }),
  z.object({
    state: z.literal("done"),
    total_bytes: z.number(),
    parts: z.number().int().min(1),
  }),
  z.object({ state: z.literal("failed"), reason: z.string() }),
  z.object({ state: z.literal("cancelled") }),
]);
export type Job = z.infer<typeof Job>;

/* The generation counts download starts. It is what lets a poller tell "the
   download I just asked for finished" from stale news about an earlier one,
   even when the job ran to completion entirely between two polls -- which a
   small region from a fast source really does. */
const JobStatus = z.object({
  generation: z.number().int().nonnegative(),
  job: Job,
});
export type JobStatus = z.infer<typeof JobStatus>;

export const isRunning = (job: Job): boolean =>
  job.state === "planning" || job.state === "fetching"
  || job.state === "assets";

async function post<T>(
  schema: z.ZodType<T>,
  endpoint: string,
  body?: unknown,
  timeoutMs = 120_000,
): Promise<T> {
  const res = await fetch(`/api/${endpoint}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body ?? {}),
    /* Generous, but bounded: "checking..." forever is how a wedged server
       used to present itself in this card. */
    signal: AbortSignal.timeout(timeoutMs),
  });
  const json: unknown = await res.json().catch(() => null);
  if (!res.ok) {
    const message = json && typeof json === "object" && "error" in json
      ? String((json as { error: unknown; }).error)
      : `request failed (${res.status})`;
    throw new Error(message);
  }
  const parsed = schema.safeParse(json);
  if (!parsed.success) {
    throw new Error(
      `server returned an unexpected shape for "${endpoint}": ${parsed.error.message}`,
    );
  }
  return parsed.data;
}

/* Whether an archive exists at all, asked of the server directly. The
   missing-basemap banner used to hang off MapLibre's error events, which
   describe a failed fetch without naming what failed -- the banner never
   fired. A HEAD request is a yes or a no. */
export function useBasemapPresent() {
  return useQuery({
    queryKey: ["basemap-present"],
    queryFn: async () =>
      (await fetch("/basemap/map.pmtiles", { method: "HEAD" })).ok,
    staleTime: Infinity,
  });
}

/* The size question, keyed by the exact regions so reopening the same view
   does not re-plan. One request carries the whole selection: the server
   dedups overlapping picks by tile id, so the answer is the real price of
   the set, not the sum of its parts. Short staleTime rather than Infinity:
   the answer changes when the source archive does, which is rare but real. */
export function useBasemapEstimate(regions: Region[] | null) {
  return useQuery({
    queryKey: ["basemap-estimate", regions],
    /* Five minutes, not two: a Brazil-sized selection plans some twenty
       million tile ids server-side, exactly and cooperatively, and honest
       slowness beats a timeout that aborts a working estimate. */
    queryFn: () => post(Estimate, "basemap-estimate", { regions }, 300_000),
    enabled: regions !== null && regions.length > 0,
    staleTime: 5 * 60_000,
    retry: false,
  });
}

/* Polled while a download runs, quiet otherwise. Always mounted alongside the
   map, so a download keeps reporting even with the card closed, and progress
   survives closing and reopening it. */
export function useBasemapStatus() {
  return useQuery({
    queryKey: ["basemap-status"],
    queryFn: () => post(JobStatus, "basemap-status"),
    refetchInterval: (query) =>
      query.state.data && isRunning(query.state.data.job) ? 1000 : false,
  });
}

export function useBasemapDownload() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: (regions: Region[]) =>
      post(z.object({ ok: z.boolean() }), "basemap-download", { regions }),
    /* Refetch immediately so the poll loop sees the running state and starts
       ticking; without this it would sleep until something else asked. */
    onSuccess: () => client.invalidateQueries({ queryKey: ["basemap-status"] }),
  });
}

export function useBasemapCancel() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: () => post(z.object({ ok: z.boolean() }), "basemap-cancel"),
    onSuccess: () => client.invalidateQueries({ queryKey: ["basemap-status"] }),
  });
}
