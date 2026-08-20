/* React Query over the core worker.

   Every call that crosses into the worker goes through here. The worker is a
   separate process holding a key we cannot read back, so from this side it
   behaves exactly like a remote service: asynchronous, fallible, and worth
   caching. That is what React Query is for, and it is why calls that never
   touch the network still belong in it.

   Two shapes:
   - queries for questions with stable answers (is this phrase valid, which
     cells cover this box, what is this square called). Pure functions of
     their inputs, so `staleTime: Infinity` is exactly right.
   - mutations for actions (unlock, lock, generate, look up an address). */

import {
  type QueryClient,
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import type { Cell } from "../store";
import { type Bounds, Core, type Grid } from "./client";

/* One worker for the life of the tab. Rebuilding it would mean re-running
   the KDF, and it holds the key, so its lifetime is the session's. */
let instance: Core | null = null;
export const core = (): Core => (instance ??= new Core());

export const keys = {
  validate: (phrase: string) => ["validate", phrase] as const,
  grid: (bounds: Bounds, limit: number) => ["grid", bounds, limit] as const,
  encode: (lat: number, lon: number) => ["encode", lat, lon] as const,
};

/* Checksum and wordlist only, so this is instant and safe on every keystroke.
   Cached forever because the answer for a given phrase cannot change: typing a
   word and deleting it again costs one call, not two. */
export function useValidatePhrase(phrase: string) {
  const trimmed = phrase.trim();
  return useQuery({
    queryKey: keys.validate(trimmed),
    queryFn: () => core().validate(trimmed),
    enabled: trimmed.length > 0,
    staleTime: Infinity,
    gcTime: Infinity,
  });
}

export function useUnlock() {
  return useMutation({
    mutationFn: (input: { mnemonic: string; passphrase: string; }) =>
      core().unlock(input.mnemonic, input.passphrase),
  });
}

export function useGeneratePhrase() {
  return useMutation({ mutationFn: () => core().generate() });
}

/* Locking has to clear the cache as well as the key. Cell geometry is
   keyless and harmless, but an encoded address is exactly the thing "lock"
   promises to forget, and it would otherwise sit in the query cache. */
export function useLock() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: () => core().lock(),
    onSettled: () => {
      client.removeQueries({ queryKey: ["encode"] });
      client.removeQueries({ queryKey: ["validate"] });
    },
  });
}

export function useDecodeAddress() {
  return useMutation({
    mutationFn: (address: string) => core().decode(address),
  });
}

/* The map drives these from its own event handlers rather than from a render,
   so they are fetched imperatively. Going through the query client rather than
   calling the worker directly still buys deduplication: a drag that fires
   several `moveend` events at the same position asks once. */
export const fetchGrid = (
  client: QueryClient,
  bounds: Bounds,
  limit: number,
): Promise<Grid> =>
  client.fetchQuery({
    queryKey: keys.grid(bounds, limit),
    queryFn: () => core().grid(bounds, limit),
    staleTime: 30_000,
  });

export const fetchAddress = (
  client: QueryClient,
  lat: number,
  lon: number,
): Promise<{ address: string; cell: Cell; }> =>
  client.fetchQuery({
    queryKey: keys.encode(lat, lon),
    queryFn: async () => {
      /* A degenerate bounding box returns exactly the cell containing the
         point, computed the same way as every other cell rather than by
         rounding here. */
      const [{ address }, exact] = await Promise.all([
        core().encode(lat, lon),
        core().grid({ latLo: lat, lonLo: lon, latHi: lat, lonHi: lon }, 1),
      ]);
      if (exact.count === 0) throw new Error("no cell contains that point");
      return {
        address,
        cell: {
          latLo: exact.cells[0]!,
          latHi: exact.cells[1]!,
          lonLo: exact.cells[2]!,
          lonHi: exact.cells[3]!,
        },
      };
    },
    staleTime: Infinity,
  });
