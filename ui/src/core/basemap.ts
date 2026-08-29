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

/* The whole world, deeper than the zoom 4 overview every package ships.
   Measured against the Protomaps planet build: zoom 6 is about 45 MB; zoom 7
   would quadruple it. It merges with the shipped overview rather than
   replacing it, so what this costs is the levels in between, and it goes to
   world.pmtiles, where no region removal can reach it. */
export const WORLD: Region = {
  min_lon: -180,
  min_lat: -85,
  max_lon: 180,
  max_lat: 85,
  max_zoom: 6,
};

const RegionProgress = z.object({
  label: z.string(),
  done_bytes: z.number().int().nonnegative(),
  total_bytes: z.number().int().nonnegative(),
  planned: z.boolean(),
});
export type RegionProgress = z.infer<typeof RegionProgress>;

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
    /* One row per picked region, in the order they were asked for. Bytes
       here are what the network delivered for that region -- tiles already
       on disk belong to whoever fetched them, so these do not sum to
       done_bytes above, which counts the whole archive being rewritten.
       `planned` is false while a region big enough to be split still has
       parts to plan, so its total can still grow. */
    regions: z.array(RegionProgress),
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
  z.object({
    state: z.literal("exporting"),
    done_bytes: z.number(),
    total_bytes: z.number(),
  }),
  z.object({ state: z.literal("removed"), freed_bytes: z.number() }),
  /* An export finished and is sitting in the export directory, ready to be
     saved. Its own state rather than "done" because there is somewhere to
     send the user: the file. */
  z.object({
    state: z.literal("exported"),
    file: z.string(),
    bytes: z.number().int().nonnegative(),
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
  || job.state === "assets" || job.state === "removing"
  || job.state === "compacting" || job.state === "indexing"
  || job.state === "exporting";

/* One row of the download ledger: a region the archive was asked to hold,
   as recorded inside the archive itself. `completed` is epoch seconds; zero
   means the tiles predate the ledger and their age is unknown -- which the
   UI treats as "probably stale" rather than "fresh". */
const LedgerEntry = z.object({
  id: z.string(),
  name: z.string(),
  /* The file holding this region's tiles, which is the file to carry away:
     a download writes its own archive, so there is nothing to build and
     nothing to wait for. Empty for a region still living inside the old
     merged map.pmtiles, which has to be extracted out of it first -- the
     export flow below, which exists for exactly that case. */
  file: z.string(),
  completed: z.number().int().nonnegative(),
  source: z.string(),
  bytes: z.number().int().nonnegative(),
  regions: z.number().int().positive(),
  max_zoom: z.number().int().nonnegative(),
  /* The world overview, which is the ground under every region rather than
     a place of its own. Since downloads split into one file per region it
     has its own archive and writes no record, so nothing made today is
     flagged here -- but an install from before that split has it inside the
     old merged map.pmtiles as an ordinary entry, under whatever the picker
     called it. The server decides this from what the entry holds, not from
     its name, and says so here rather than leaving the page to guess. */
  overview: z.boolean(),
});
export type LedgerEntry = z.infer<typeof LedgerEntry>;
const Ledger = z.object({
  entries: z.array(LedgerEntry),
  /* Whether any archive is on disk, which the entries cannot say: a world
     overview fetched with the extraction tool writes no entry and is still
     a map. */
  held: z.boolean(),
});

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
/* Any archive, not just the downloaded one. The world overview alone is a
   drawn, labelled planet -- it is step 1 of the documented setup, with the
   region as step 2 -- and reporting "no basemap found" over it was a banner
   contradicting the map behind it. Asked of the server rather than probed
   for with a HEAD per file, because probing for one that is absent puts a
   404 in the console on a configuration that is entirely correct. */
export function useBasemapPresent() {
  return useQuery({
    queryKey: ["basemap-present"],
    queryFn: async () => (await post(Ledger, "basemap-ledger")).held,
    staleTime: Infinity,
  });
}

/* The size question, keyed by the exact regions so reopening the same view
   does not re-plan. One request carries the whole selection: the server
   dedups overlapping picks by tile id, so the answer is the real price of
   the set, not the sum of its parts. Short staleTime rather than Infinity:
   the answer changes when the source archive does, which is rare but real. */
export function useBasemapEstimate(regions: Region[] | null, world = false) {
  return useQuery({
    /* `world` is part of the key: the same box priced against the overview
       and against the detail archive are two different answers. */
    queryKey: ["basemap-estimate", regions, world],
    /* Five minutes, not two: a Brazil-sized selection plans some twenty
       million tile ids server-side, exactly and cooperatively, and honest
       slowness beats a timeout that aborts a working estimate. */
    queryFn: () =>
      post(
        Estimate,
        "basemap-estimate",
        { regions, ...(world ? { world: true } : {}) },
        300_000,
      ),
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
       validates it, so the picker never invents one it cannot store.

       `world` says which archive this joins. The overview is its own file
       and keeps no ledger entry -- it belongs to no place, and it is what
       the map falls back to everywhere -- so a region download must not be
       able to take it away, and the server checks that a download claiming
       to be one really covers the planet. */
    mutationFn: (
      { regions, name, labels, world }: {
        regions: Region[];
        name?: string;
        /* One label per region, in the same order. The server echoes these
           back in the status so the progress rows keep their names across a
           reload -- the ledger stores only the one combined name, which
           cannot label six separate bars. */
        labels?: string[];
        world?: boolean;
      },
    ) =>
      post(z.object({ ok: z.boolean() }), "basemap-download", {
        regions,
        ...(name !== undefined ? { name } : {}),
        ...(labels !== undefined ? { labels } : {}),
        ...(world ? { world: true } : {}),
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

/* ------------------------------------------------- carrying maps by hand */

/* Writing a downloaded region out as a file, so it can be carried to a
   machine with no internet. The file is built server-side into the export
   directory and then saved by the browser over an ordinary GET, which is
   what makes a multi-gigabyte export resumable and keeps it off the
   JavaScript heap entirely. */
export function useBasemapExport() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: (id: string) =>
      post(z.object({ ok: z.boolean() }), "basemap-export", { id }),
    onSuccess: () => client.invalidateQueries({ queryKey: ["basemap-status"] }),
  });
}

const Exports = z.array(
  z.object({ file: z.string(), bytes: z.number().int().nonnegative() }),
);
export type Exports = z.infer<typeof Exports>;

/* What is sitting in the export directory. Listed from disk rather than
   remembered, because these outlive the session that made them: the point is
   to collect several over an evening and copy them all at once. */
export function useBasemapExports() {
  return useQuery({
    queryKey: ["basemap-exports"],
    queryFn: () => post(Exports, "basemap-exports"),
  });
}

export function useDeleteExport() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: (file: string) =>
      post(z.object({ ok: z.boolean() }), "basemap-export-delete", { file }),
    onSuccess: () =>
      client.invalidateQueries({ queryKey: ["basemap-exports"] }),
  });
}

/* Where the browser saves an export from. Same origin, so the CSP is happy
   and nothing leaves this machine. */
export const exportUrl = (file: string) =>
  `/basemap/export/${encodeURIComponent(file)}`;

/* And where it saves a downloaded region from: the archive the download
   itself wrote, served from the basemap directory it already lives in. No
   copy is made anywhere -- this URL is the file. */
export const regionUrl = (file: string) =>
  `/basemap/${encodeURIComponent(file)}`;

const Staged = z.discriminatedUnion("staged", [
  z.object({ staged: z.literal(false) }),
  z.object({
    staged: z.literal(true),
    name: z.string().nullable(),
    bytes: z.number().int().nonnegative(),
    min_zoom: z.number().int().nonnegative(),
    max_zoom: z.number().int().nonnegative(),
    tiles: z.number().int().nonnegative(),
    regions: z.array(z.object({
      min_lon: z.number(),
      min_lat: z.number(),
      max_lon: z.number(),
      max_lat: z.number(),
      max_zoom: z.number().int().nonnegative(),
    })),
  }),
]);
export type Staged = z.infer<typeof Staged>;
/* The half of [Staged] that actually describes a file. Named because a
   conditional expression widens back to the whole union, so the component
   holding "the staged file, or nothing" has to say which half it means. */
export type StagedReady = Extract<Staged, { staged: true; }>;

/* What has been uploaded and is waiting to be merged. */
export function useStagedImport() {
  return useQuery({
    queryKey: ["basemap-staged"],
    queryFn: () => post(Staged, "basemap-staged"),
  });
}

/* Sending the file up.

   XHR rather than fetch, for one reason: fetch cannot report upload
   progress, and this is a multi-gigabyte body going to a server the user is
   watching. A progress bar that sits at zero for four minutes reads as a
   hang. The File is handed over as-is, so the browser streams it from disk
   and it never lands on the JavaScript heap. */
export function useUploadImport() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: (
      { file, onProgress }: {
        file: File;
        onProgress?: (sent: number, total: number) => void;
      },
    ) =>
      new Promise<Staged>((resolve, reject) => {
        const xhr = new XMLHttpRequest();
        xhr.open("POST", "/import");
        xhr.setRequestHeader("content-type", "application/octet-stream");
        xhr.upload.addEventListener("progress", (e) => {
          if (e.lengthComputable) onProgress?.(e.loaded, e.total);
        });
        xhr.addEventListener("load", () => {
          let json: unknown = null;
          try {
            json = JSON.parse(xhr.responseText) as unknown;
          } catch {
            json = null;
          }
          if (xhr.status < 200 || xhr.status >= 300) {
            const message = json && typeof json === "object" && "error" in json
              ? String((json as { error: unknown; }).error)
              : `upload failed (${xhr.status})`;
            reject(new Error(message));
            return;
          }
          const parsed = Staged.safeParse(json);
          if (!parsed.success) {
            reject(new Error("the server described that file oddly"));
            return;
          }
          resolve(parsed.data);
        });
        xhr.addEventListener("error", () =>
          reject(new Error("the upload could not reach the app")));
        xhr.addEventListener("abort", () =>
          reject(new Error("the upload was stopped")));
        xhr.send(file);
      }),
    onSuccess: () => client.invalidateQueries({ queryKey: ["basemap-staged"] }),
  });
}

/* Merging what was uploaded. Everything downstream is the ordinary download
   path with a file for a source, so the region lands in the ledger and the
   search index exactly as a downloaded one does. */
export function useCommitImport() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: () => post(z.object({ ok: z.boolean() }), "basemap-import"),
    onSuccess: () => {
      void client.invalidateQueries({ queryKey: ["basemap-status"] });
      void client.invalidateQueries({ queryKey: ["basemap-staged"] });
    },
  });
}

export function useDiscardImport() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: () =>
      post(z.object({ ok: z.boolean() }), "basemap-import-discard"),
    onSuccess: () => client.invalidateQueries({ queryKey: ["basemap-staged"] }),
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
  /* How well the row answered the NAME, straight from the index. Lower is
     better, and rows sharing one are rows the index considers equally good
     answers -- the set the dropdown is free to re-order on the country and
     state it can work out and the index cannot. */
  score: z.number(),
});
export type PlaceResult = z.infer<typeof PlaceResult>;

const PlaceResults = z.object({ results: z.array(PlaceResult) });

/* [allowed] is the privacy gate, and it is a required argument rather than an
   option with a default because the default would be the wrong one. An
   address must never reach the place index, and the caller is the only party
   that knows whether what was typed is an address. Passing false leaves the
   query disabled, which means no request is made at all -- not a request
   whose result is discarded. */
export function usePlaceSearch(
  query: string,
  allowed: boolean,
  limit: number,
) {
  const trimmed = query.trim();
  return useQuery({
    /* The limit is part of the key: a wider ask is a different answer, and
       serving the eight-row cache for a forty-row question would drop the
       rows the wider ask was made for. */
    queryKey: ["place-search", trimmed, limit],
    queryFn: () => post(PlaceResults, "basemap-search", { q: trimmed, limit }),
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
