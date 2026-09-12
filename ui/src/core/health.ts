import { useQuery } from "@tanstack/react-query";

/* Not parsed with zod, unlike every other response: /healthz has a body this
   has no use for.*/
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
