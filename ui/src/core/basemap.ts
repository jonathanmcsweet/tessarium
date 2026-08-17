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
};

const Estimate = z.object({
  total_bytes: z.number().int().nonnegative(),
  tiles: z.number().int().nonnegative(),
});
export type Estimate = z.infer<typeof Estimate>;

const Job = z.discriminatedUnion("state", [
  z.object({ state: z.literal("idle") }),
  z.object({ state: z.literal("planning") }),
  z.object({
    state: z.literal("fetching"),
    done_bytes: z.number(),
    total_bytes: z.number(),
  }),
  z.object({ state: z.literal("assets") }),
  z.object({ state: z.literal("done"), total_bytes: z.number() }),
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
): Promise<T> {
  const res = await fetch(`/api/${endpoint}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body ?? {}),
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

/* The size question, keyed by the exact region so reopening the same view
   does not re-plan. Short staleTime rather than Infinity: the answer changes
   when the source archive does, which is rare but real. */
export function useBasemapEstimate(region: Region | null) {
  return useQuery({
    queryKey: ["basemap-estimate", region],
    queryFn: () => post(Estimate, "basemap-estimate", region),
    enabled: region !== null,
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
    mutationFn: (region: Region) =>
      post(z.object({ ok: z.boolean() }), "basemap-download", region),
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
