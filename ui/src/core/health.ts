/* Whether the server is answering at all.

   Everything else assumes it is. The basemap calls and the tiles are the
   obvious dependants; the less obvious one is unlocking, because the two
   wasm modules the worker derives the key with are embedded in the server
   binary rather than sitting in public/. So a missing server does not
   degrade this app, it stops it: the phrase validates, the checksum goes
   green, "Open my map" fails, and all it says is "Could not open the map."

   A whole-application condition that stays true until someone starts the
   server, so it is a banner and not a toast -- see components/Banner.

   In a shipped build the server is what served this page, so this can only
   turn true if it dies under an open tab. In development Vite serves the
   page and proxies to the server, so it stays true for as long as
   `pnpm run dev` runs without one. */

import { useQuery } from "@tanstack/react-query";

/* Not parsed with zod, unlike every other response: /healthz has a body this
   has no use for. The question is only whether anything answered. */
async function ping(): Promise<true> {
  const res = await fetch("/healthz", { cache: "no-store" });
  if (!res.ok) throw new Error(`healthz answered ${res.status}`);
  return true;
}

export function useBackendDown(): boolean {
  const { isError } = useQuery({
    queryKey: ["healthz"],
    queryFn: ping,
    /* Both override the client-wide defaults in main.tsx, which turn
       retries and focus-refetching off. That is right for the worker calls
       and wrong here. A single dropped request is not an answer, so this
       retries: three attempts before a banner appears, which keeps a server
       restart from flashing one up. And returning to the tab is exactly when
       someone wants to know the server went away. */
    retry: 2,
    retryDelay: 1_000,
    refetchOnWindowFocus: true,
    /* Keeps answering the question rather than answering it once at mount.
       Cheap: an empty 200 against the origin that served the page. */
    refetchInterval: 15_000,
    staleTime: 0,
  });
  return isError;
}
