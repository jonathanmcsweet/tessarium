/* Application state.

   Everything that is not the result of a call into the core lives here: which
   square is selected, whether the map is unlocked, whether the address is
   concealed. Results of core calls live in React Query instead.

   Held in memory only. This application persists nothing -- no localStorage,
   no cookie, no URL state -- and a display preference is not worth being the
   exception that makes that sentence untrue. */

import { create } from "zustand";
import { applyLocale, getLocale, type Locale } from "./i18n";
import { applyTheme, DEFAULT_THEME, type Theme } from "./theme";

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

/* The map's viewport at the moment the downloader was opened. Structural,
   not imported from core/basemap: the panel renders the downloader now, and
   pulling that module's type in would drag the map chunk into the shell. */
export type ViewRegion = {
  min_lon: number;
  min_lat: number;
  max_lon: number;
  max_lat: number;
  max_zoom: number;
};

/* Bounds for the panel drawer, in px. The floor is what the download card's
   own controls need before they start wrapping into unreadable columns; the
   ceiling keeps the map from being squeezed out of its own screen. */
export const PANEL_MIN = 300;
export const PANEL_MAX = 720;
export const PANEL_DEFAULT = 340;

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
  /* The square's coordinates, same policy as its address: they name where
     someone is, so they start hidden and stay as the user set them. */
  coordsConcealed: boolean;
  basemapFailed: boolean;
  /* Frozen when the downloader opens, cleared when it closes: panning while
     it is open changes the NEXT download, not the one being confirmed. It
     lives here rather than in MapView because the panel draws the card and
     the map is what knows the viewport. */
  downloadRegion: ViewRegion | null;
  /* Drawer width. In memory only, like everything else here -- see the note
     at the top of this file; a remembered width is not worth being the
     exception that makes "persists nothing" untrue. */
  panelWidth: number;
  /* Collapsed is not width 0. The width someone dragged to is theirs and is
     kept while the drawer is shut, so reopening returns it rather than
     resetting to the default. */
  panelCollapsed: boolean;
  /* Whether the offline-maps card is open. In the store rather than local to
     the map because the missing-basemap banner opens it from outside. */
  downloadOpen: boolean;
  /* Mirrors Paraglide's in-memory locale. Kept here so that changing language
     re-renders the tree: the message functions read the locale when they are
     called, and nothing would call them again otherwise. */
  locale: Locale;
  /* Light, dark, or whatever the device says. In memory only, like
     everything else here: the note at the top of this file is the whole
     reason the language menu is session-only too, and a colour scheme is
     not worth being the exception that makes it untrue. "system" is the
     start, so the answer is right before anyone touches it. */
  theme: Theme;

  setLocale: (locale: Locale) => void;
  setTheme: (theme: Theme) => void;
  setUnlocked: () => void;
  setLocked: () => void;
  select: (selection: Selection) => void;
  requestFlyTo: (lat: number, lon: number) => void;
  toggleConcealed: () => void;
  toggleCoordsConcealed: () => void;
  toggleAllConcealed: () => void;
  setDownloadRegion: (region: ViewRegion | null) => void;
  setPanelWidth: (width: number) => void;
  togglePanel: () => void;
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
  coordsConcealed: true,
  basemapFailed: false,
  downloadOpen: false,
  downloadRegion: null,
  panelWidth: PANEL_DEFAULT,
  panelCollapsed: false,
  locale: getLocale() as Locale,
  theme: DEFAULT_THEME,

  setLocale: (locale) => {
    applyLocale(locale);
    set({ locale });
  },
  setTheme: (theme) => {
    applyTheme(theme);
    set({ theme });
  },
  setUnlocked: () => set({ unlocked: true }),
  setLocked: () =>
    set({
      unlocked: false,
      selection: null,
      flyTo: null,
      concealed: true,
      coordsConcealed: true,
      downloadOpen: false,
      downloadRegion: null,
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
  toggleCoordsConcealed: () =>
    set((state) => ({ coordsConcealed: !state.coordsConcealed })),
  /* One control for every hidden value at once. Anything still hidden means
     the next press reveals -- so a half-revealed panel goes fully open rather
     than fully shut, which is what someone reaching for a "show everything"
     button is asking for. */
  toggleAllConcealed: () =>
    set((state) => {
      const hiding = state.concealed || state.coordsConcealed;
      return { concealed: !hiding, coordsConcealed: !hiding };
    }),
  setDownloadRegion: (region: ViewRegion | null) =>
    set({ downloadRegion: region }),
  setPanelWidth: (width: number) =>
    set({
      panelWidth: Math.min(PANEL_MAX, Math.max(PANEL_MIN, Math.round(width))),
    }),
  togglePanel: () =>
    set((state) => ({ panelCollapsed: !state.panelCollapsed })),
  setBasemapFailed: () => set({ basemapFailed: true }),
  clearBasemapFailed: () => set({ basemapFailed: false }),
  openDownload: () => set({ downloadOpen: true }),
  closeDownload: () => set({ downloadOpen: false }),
}));
