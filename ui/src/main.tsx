import * as Tooltip from "@radix-ui/react-tooltip";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { Toaster } from "sonner";
import { App } from "./App";
import "./i18n";
import "./styles.css";

/* No retries. Every query here is a call into a local worker: a failure is a
   locked key or a refused address, and asking again gets the same answer more
   slowly. Refetch-on-focus is off for the same reason -- nothing here goes
   stale because someone changed tabs. */
const queryClient = new QueryClient({
  defaultOptions: {
    queries: { retry: false, refetchOnWindowFocus: false },
    mutations: { retry: false },
  },
});

const root = document.getElementById("root");
if (!root) throw new Error("missing #root");

createRoot(root).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <Tooltip.Provider delayDuration={300} skipDelayDuration={200}>
        <App />
        {
          /* Top centre so it does not sit over the address panel on desktop or
            under a thumb on mobile. `closeButton` because a toast that can
            only be waited out is a trap for anyone using a keyboard. */
        }
        <Toaster
          position="top-center"
          richColors
          closeButton
          toastOptions={{ duration: 5000 }}
        />
      </Tooltip.Provider>
    </QueryClientProvider>
  </StrictMode>,
);
