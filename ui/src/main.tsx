import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { IconSet } from "./components/icons";
import { Toasts } from "./components/Toasts";
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
      {
        /* No tooltip provider. Radix needed one at the root to share its
          open/close delay between triggers; React Aria groups that inside
          TooltipTrigger, so the delay lives next to the component that uses
          it -- see components/IconButton.tsx. */
      }
      {
        /* Around everything that draws a glyph, which is the gate, the map
          and the toasts alike: the icon set follows the palette, and one
          provider is one subscription rather than one per icon. */
      }
      <IconSet>
        <App />
        {
          /* Top centre so it sits over neither the address panel on desktop
            nor a thumb on mobile. Its two timings are not defaults and are
            asserted end to end -- see ../toast.ts. */
        }
        <Toasts />
      </IconSet>
    </QueryClientProvider>
  </StrictMode>,
);
