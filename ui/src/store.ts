/* Application state.

   Everything that is not the result of a call into the core lives here: which
   square is selected, whether the map is unlocked, whether the address is
   concealed. Results of core calls live in React Query instead.

   Held in memory only. This application persists nothing -- no localStorage,
   no cookie, no URL state -- and a display preference is not worth being the
   exception that makes that sentence untrue. */

import { create } from "zustand";
import { applyLocale, getLocale, type Locale } from "./i18n";

export type Cell = {
  latLo: number;
  latHi: number;
  lonLo: number;
  lonHi: number;
};

export type Selection = {
  address: string;
  lat: number;
  lon: number;
  cell: Cell;
};

export type FlyTo = { lat: number; lon: number; nonce: number; };

type AppState = {
  unlocked: boolean;
  selection: Selection | null;
  flyTo: FlyTo | null;
  /* Privacy mode, ON by default. An address is a secret, and the cost of the
     two states is not symmetric: revealing one the user did not ask to reveal
     hands it to whoever is behind them, while hiding one they did want costs a
     click. Survives changing squares in both directions -- someone who
     revealed it is not asked again on the next square, and someone who hid it
     for a screen share does not get it back. */
  concealed: boolean;
  basemapFailed: boolean;
  /* Whether the offline-maps card is open. In the store rather than local to
     the map because the missing-basemap banner opens it from outside. */
  downloadOpen: boolean;
  /* Mirrors Paraglide's in-memory locale. Kept here so that changing language
     re-renders the tree: the message functions read the locale when they are
     called, and nothing would call them again otherwise. */
  locale: Locale;

  setLocale: (locale: Locale) => void;
  setUnlocked: () => void;
  setLocked: () => void;
  select: (selection: Selection) => void;
  requestFlyTo: (lat: number, lon: number) => void;
  toggleConcealed: () => void;
  setBasemapFailed: () => void;
  clearBasemapFailed: () => void;
  openDownload: () => void;
  closeDownload: () => void;
};

export const useAppStore = create<AppState>()((set) => ({
  unlocked: false,
  selection: null,
  flyTo: null,
  concealed: true,
  basemapFailed: false,
  downloadOpen: false,
  locale: getLocale() as Locale,

  setLocale: (locale) => {
    applyLocale(locale);
    set({ locale });
  },
  setUnlocked: () => set({ unlocked: true }),
  setLocked: () =>
    set({
      unlocked: false,
      selection: null,
      flyTo: null,
      concealed: true,
      downloadOpen: false,
    }),
  select: (selection) => set({ selection }),
  /* A counter, not a timestamp: looking up the same address twice has to fly
     there twice, and a monotonic counter says that without reaching for a
     clock. */
  requestFlyTo: (lat, lon) =>
    set((state) => ({
      flyTo: { lat, lon, nonce: (state.flyTo?.nonce ?? 0) + 1 },
    })),
  toggleConcealed: () => set((state) => ({ concealed: !state.concealed })),
  setBasemapFailed: () => set({ basemapFailed: true }),
  clearBasemapFailed: () => set({ basemapFailed: false }),
  openDownload: () => set({ downloadOpen: true }),
  closeDownload: () => set({ downloadOpen: false }),
}));
