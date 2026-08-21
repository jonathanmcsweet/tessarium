/* The in-app map downloader's client side.

   These calls go to our own server, which does the actual fetching: the
   browser names a region of the world and nothing else. Where the tiles come
   from is the server's command line, so a compromised page cannot redirect
   the download — and the CSP's connect-src 'self' holds, because every
   request here is same-origin.

   All of it lives in React Query per the house rule for network state, and
   every response is parsed with zod rather than cast, same as the worker
   boundary and for the same reason. */

import {
  type QueryClient,
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
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
    state: z.literal("removing"),
    done_bytes: z.number(),
    total_bytes: z.number(),
  }),
  z.object({
    state: z.literal("compacting"),
    done_bytes: z.number(),
    total_bytes: z.number(),
  }),
  z.object({
    state: z.literal("indexing"),
    done_tiles: z.number(),
    total_tiles: z.number(),
  }),
  z.object({
    state: z.literal("done"),
    total_bytes: z.number(),
    parts: z.number().int().min(1),
  }),
  z.object({ state: z.literal("removed"), freed_bytes: z.number() }),
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
  || job.state === "assets" || job.state === "removing"
  || job.state === "compacting" || job.state === "indexing";

/* One row of the download ledger: a region the archive was asked to hold,
   as recorded inside the archive itself. `completed` is epoch seconds;
   zero means the tiles predate the ledger and their age is unknown --
   which the UI treats as "probably stale" rather than "fresh". */
const LedgerEntry = z.object({
  id: z.string(),
  name: z.string(),
  completed: z.number().int().nonnegative(),
  source: z.string(),
  bytes: z.number().int().nonnegative(),
  regions: z.number().int().positive(),
  max_zoom: z.number().int().nonnegative(),
});
export type LedgerEntry = z.infer<typeof LedgerEntry>;
const Ledger = z.object({ entries: z.array(LedgerEntry) });

const Settings = z.object({
  update_reminder_days: z.number().int().nonnegative(),
  /* Whether missing viewport tiles are fetched and kept while browsing
     online. Off by default: an offline-first tool must not phone home on
     every pan without being asked. */
  browse_cache: z.boolean(),
});
export type Settings = z.infer<typeof Settings>;

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
    /* The name is what the ledger will call this download; the server
       validates it, so the picker never invents one it cannot store. */
    mutationFn: ({ regions, name }: { regions: Region[]; name?: string; }) =>
      post(z.object({ ok: z.boolean() }), "basemap-download", {
        regions,
        ...(name !== undefined ? { name } : {}),
      }),
    /* Refetch immediately so the poll loop sees the running state and starts
       ticking; without this it would sleep until something else asked. */
    onSuccess: () => client.invalidateQueries({ queryKey: ["basemap-status"] }),
  });
}

/* What the archive holds, straight from the archive: the list is read from
   map.pmtiles metadata on every ask, so it can never disagree with the
   tiles on disk. Invalidated when a job reaches a terminal state. */
export function useBasemapLedger() {
  return useQuery({
    queryKey: ["basemap-ledger"],
    queryFn: () => post(Ledger, "basemap-ledger"),
  });
}

export function useBasemapUpdate() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: (id: string) =>
      post(z.object({ ok: z.boolean() }), "basemap-update", { id }),
    onSuccess: () => client.invalidateQueries({ queryKey: ["basemap-status"] }),
  });
}

export function useBasemapRemove() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: (id: string) =>
      post(z.object({ ok: z.boolean() }), "basemap-remove", { id }),
    onSuccess: () => client.invalidateQueries({ queryKey: ["basemap-status"] }),
  });
}

/* Server-side, deliberately: the browser persists nothing here (asserted in
   the e2e suite), so the reminder threshold lives next to the archive it
   describes. */
export function useBasemapSettings() {
  return useQuery({
    queryKey: ["basemap-settings"],
    queryFn: () => post(Settings, "basemap-settings"),
    staleTime: Infinity,
  });
}

export function useSaveBasemapSettings() {
  const client = useQueryClient();
  return useMutation({
    /* A partial patch: either field alone writes just itself. */
    mutationFn: (
      patch: { update_reminder_days?: number; browse_cache?: boolean; },
    ) => post(Settings, "basemap-settings", patch),
    onSuccess: (data) => client.setQueryData(["basemap-settings"], data),
  });
}

/* One viewport's missing tiles, fetched into the browse cache. Quiet on
   purpose: this fires on pan-stop, and neither its errors nor its progress
   deserve a toast -- being offline is a normal state, not a failure. */
export function useBasemapBrowse() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: (view: {
      min_lon: number;
      min_lat: number;
      max_lon: number;
      max_lat: number;
      zoom: number;
    }) =>
      post(
        z.object({
          ok: z.boolean(),
          fetched: z.number().int().nonnegative(),
          /* The depth the server actually wrote, which its source may have
             clamped below the one asked for. */
          zoom: z.number().int().nonnegative(),
        }),
        "basemap-browse",
        view,
      ),
    /* A browse that fetched something may have pushed the cache past its
       threshold and started a compaction -- a real running job. Wake the
       status poll so the progress shows and a Download click during it
       gets a comprehensible refusal, not a mystery. */
    onSuccess: ({ fetched }) => {
      if (fetched > 0) {
        client.invalidateQueries({ queryKey: ["basemap-status"] });
      }
    },
  });
}

/* A place name, from the index built when the region was downloaded. Never
   a network geocoder: the query names where the user is going, and that is
   the one thing this application is arranged not to tell anyone. */
export const PlaceResult = z.object({
  name: z.string(),
  kind: z.string(),
  layer: z.string(),
  weight: z.number(),
  lon: z.number(),
  lat: z.number(),
});
export type PlaceResult = z.infer<typeof PlaceResult>;

const PlaceResults = z.object({ results: z.array(PlaceResult) });

/* [allowed] is the privacy gate, and it is a required argument rather than an
   option with a default because the default would be the wrong one. An
   address must never reach the place index, and the caller is the only party
   that knows whether what was typed is an address. Passing false leaves the
   query disabled, which means no request is made at all -- not a request
   whose result is discarded. */
export function usePlaceSearch(query: string, allowed: boolean) {
  const trimmed = query.trim();
  return useQuery({
    queryKey: ["place-search", trimmed],
    queryFn: () =>
      post(PlaceResults, "basemap-search", { q: trimmed, limit: 8 }),
    /* Two characters is where the answer stops being "most of the map". */
    enabled: allowed && trimmed.length >= 2,
    /* The index only changes when a region is downloaded or removed, so a
       repeated query is genuinely the same answer. */
    staleTime: 5 * 60_000,
    retry: false,
  });
}

export function useBasemapCancel() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: () => post(z.object({ ok: z.boolean() }), "basemap-cancel"),
    onSuccess: () => client.invalidateQueries({ queryKey: ["basemap-status"] }),
  });
}

/* ------------------------------------------------------------- coverage */

/* Which of a viewport's tiles this server can actually serve, so the map
   can draw the edge of what is on disk instead of leaving a blank screen
   to be read as a broken application.

   The answer describes the ARCHIVES, not the download ledger: a browsed
   tile is a tile the map draws, and an archive can hold tiles no ledger
   entry claims. `present` is one character per tile, north-west first,
   west to east and then south. */
const Coverage = z.object({
  zoom: z.number().int().nonnegative(),
  x: z.number().int().nonnegative(),
  y: z.number().int().nonnegative(),
  w: z.number().int().positive(),
  h: z.number().int().positive(),
  present: z.string().regex(/^[01]*$/),
  /* Deepest zoom with a tile under the middle cell of the rectangle above;
     -1 for none at any zoom. It is what decides whether the middle of the
     view is blank, so it is measured server-side at that same cell rather
     than re-derived here from the mask. */
  depth: z.number().int().min(-1),
  /* Whether the map UNDER the map draws here -- a different question from
     the depth, and the one that decides what the app may claim. An archive
     holding one city still holds the single zoom-0 tile of the planet, so
     its depth over anywhere is 0; whether that amounts to a map on screen
     depends on the floor covering the world at that zoom, which is a fact
     about the whole archive rather than about this view. Answered by the
     server, which is what measures the floor's depth in the first place. */
  floor: z.boolean(),
}).refine((c) => c.present.length === c.w * c.h, {
  /* The one invariant that spans fields, and so the one zod would not
     check on its own. A short string reads as "covered" for every tile it
     does not mention -- silently under-reporting the blank, which is the
     failure this feature exists to prevent. */
  message: "present must carry one character per tile of w x h",
});
export type Coverage = z.infer<typeof Coverage>;

/* Driven from the map's own move handlers, so fetched imperatively -- the
   same arrangement the grid uses, and for the same reason: a drag fires
   several settled events at one position and the query client answers the
   repeats from cache.

   The staleness window is short rather than infinite: tiles arrive while
   browsing and leave when a region is removed, and the mask must not
   outlive either. */
export const fetchCoverage = (
  client: QueryClient,
  view: {
    min_lon: number;
    min_lat: number;
    max_lon: number;
    max_lat: number;
    zoom: number;
  },
): Promise<Coverage> =>
  client.fetchQuery({
    queryKey: ["basemap-coverage", view],
    queryFn: () => post(Coverage, "basemap-coverage", view, 15_000),
    staleTime: 10_000,
    retry: false,
  });
