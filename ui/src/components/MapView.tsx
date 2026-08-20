/* The map, the grid overlay, and the click that turns a square into words. */

import { layers, namedFlavor } from "@protomaps/basemaps";
import { useQueryClient } from "@tanstack/react-query";
import { Download } from "lucide-react";
import maplibregl from "maplibre-gl";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
} from "react";
import { toast } from "sonner";
import {
  fetchCoverage,
  isRunning,
  type Job,
  type Region,
  useBasemapBrowse,
  useBasemapPresent,
  useBasemapSettings,
  useBasemapStatus,
} from "../core/basemap";
import {
  absentRects,
  blankEdges,
  centreIsBlank,
  rectsToFeatures,
} from "../core/coverage";
import { createLoadingTracker } from "../core/loading";
import { fetchAddress, fetchGrid } from "../core/queries";
import { formatBytes, getLocale } from "../i18n";
import { m } from "../paraglide/messages";
import { useAppStore } from "../store";
import { toastError } from "../toast";
import { DownloadCard } from "./DownloadCard";
import { IconButton } from "./IconButton";
import { PlaceSearch } from "./PlaceSearch";
import "maplibre-gl/dist/maplibre-gl.css";

/* The end-to-end test's handle on the live map. The map holds tiles and
   geometry, never the key or an address, so exposing it forfeits nothing. */
declare global {
  interface Window {
    __tessarium_map?: maplibregl.Map;
  }
}

/* Below this the squares are smaller than a fingertip and the overlay is
   noise. A 3 m cell is about 5 px at z18 and 20 px at z20. */
const GRID_MIN_ZOOM = 18;

/* The deepest tile the basemap is cut to, and the deepest this server will
   answer a coverage query about. Past it the map overzooms the tiles it
   has rather than asking for more, so this is the zoom a question about
   what is on disk has to be asked at. */
const MAX_TILE_ZOOM = 15;

/* How long a pan is left to settle before the browse cache fetches what is
   missing. Named once because the coverage note has to outwait it: saying
   "not downloaded" about tiles that are already on their way is worse than
   saying nothing for a moment. */
const BROWSE_SETTLE_MS = 1200;

/* A ceiling on cells per viewport. Reached only when the viewport is unusually
   large for the zoom; truncation is drawn as a warning rather than silently
   producing a grid that stops halfway across the screen. */
const CELL_LIMIT = 12000;

/* The grid is drawn as empty squares at every zoom. Addresses are never
   written onto the map, however far in you go.

   This is a security boundary, not a layout preference. Each (address, real
   place) pair an attacker holds is material for searching out the phrase that
   links them; a screenshot of a labelled grid is fifty such pairs in one
   image, shared by someone who thought they were showing a street. One square
   at a time, in the panel, on purpose. */

const emptyGeoJson = {
  type: "FeatureCollection" as const,
  features: [] as GeoJSON.Feature[],
};

/* The style, rebuilt whenever the archive on disk is replaced. Tiles come
   through the server's /tiles endpoint rather than from the archive file
   directly: the server is what knows about BOTH archives -- the browse
   cache and the main one -- and a missing tile is a quiet 204 instead of a
   logged error. The version number lands in the tile URL as a query string
   so MapLibre's per-URL caching cannot keep old tiles over new bytes. */
const buildStyle = (version: number): maplibregl.StyleSpecification => ({
  version: 8,
  /* Everything the style needs is served from this origin. A style that
     reaches a CDN for glyphs looks fine online and renders unlabelled the
     first time someone opens it offline. */
  glyphs: "/basemap/fonts/{fontstack}/{range}.pbf",
  /* MapLibre appends .json and .png, so this names the flavour rather
     than the directory: sprites/v4/light.json and light.png. */
  sprite: `${window.location.origin}/basemap/sprites/v4/light`,
  sources: {
    protomaps: {
      type: "vector",
      /* TileJSON from the server, never hardcoded numbers: the zoom range
         and bounds come from the archive headers, and the maxzoom is
         load-bearing -- overzoom starts from the source's stated depth, so
         a wrong 15 over a world-at-z6 archive renders blank at street
         zoom over data the archive holds. */
      url: `/tiles.json?v=${version}`,
      attribution:
        '<a href="https://protomaps.com">Protomaps</a> © <a href="https://openstreetmap.org">OpenStreetMap</a>',
    },
  },
  /* Place names follow the interface language, so switching to French does
     not leave an English map under translated controls. Protomaps wants a
     bare language subtag, not the full locale. */
  layers: layers("protomaps", namedFlavor("light"), {
    lang: getLocale().split("-")[0] ?? "en",
  }),
});

/* The grid and selection overlay, added on load and re-added after every
   style swap -- setStyle discards custom sources and layers. */
const addOverlay = (map: maplibregl.Map) => {
  /* Adding twice throws. Cannot happen today, but the callers are event
     listeners around a style swap whose timing MapLibre does not promise. */
  if (map.getSource("coverage")) return;
  map.addSource("coverage", { type: "geojson", data: emptyGeoJson });
  map.addSource("coverage-edge", { type: "geojson", data: emptyGeoJson });
  map.addSource("grid", { type: "geojson", data: emptyGeoJson });
  map.addSource("selection", { type: "geojson", data: emptyGeoJson });

  /* Added before the grid and the selection so those draw on top of it:
     this says where the BASEMAP stops, and the grid works past that edge
     -- an address is arithmetic, not a lookup, so covering it up would
     say the opposite of what is true. Muted rather than alarming for the
     same reason: outside coverage is a normal place to be. */
  map.addLayer({
    id: "coverage-blank",
    type: "fill",
    source: "coverage",
    /* Heavier than a hint on purpose. It only ever covers tiles the map
       draws nothing for, so there is no cartography underneath to obscure,
       and a wash faint enough to be tasteful over a drawn map was
       invisible over a blank one -- 1.2:1 against the background, which
       is no signal at all. The note carries the meaning in words; this
       carries the shape. */
    paint: { "fill-color": "#41505f", "fill-opacity": 0.42 },
  });
  map.addLayer({
    id: "coverage-line",
    type: "line",
    source: "coverage-edge",
    paint: {
      "line-color": "#5f7183",
      "line-width": 1.5,
      "line-opacity": 0.85,
    },
  });

  map.addLayer({
    id: "grid-lines",
    type: "line",
    source: "grid",
    paint: {
      "line-color": "#1b3a5c",
      "line-width": 0.6,
      /* Fades in as the squares become large enough to aim at, rather
         than appearing abruptly at a threshold. */
      "line-opacity": [
        "interpolate",
        ["linear"],
        ["zoom"],
        GRID_MIN_ZOOM,
        0,
        GRID_MIN_ZOOM + 1,
        0.35,
      ],
    },
  });

  map.addLayer({
    id: "selection-fill",
    type: "fill",
    source: "selection",
    filter: ["==", ["geometry-type"], "Polygon"],
    paint: { "fill-color": "#e8452c", "fill-opacity": 0.35 },
  });
  map.addLayer({
    id: "selection-outline",
    type: "line",
    source: "selection",
    filter: ["==", ["geometry-type"], "Polygon"],
    paint: { "line-color": "#e8452c", "line-width": 2 },
  });
  /* A ~3 m square is sub-pixel until street level, so zoomed out the
     selection would be invisible -- exactly when someone has just looked an
     address up and is watching the map fly. A pin marks the square until
     the square itself is big enough to see, then fades out as the grid
     fades in. Declarative on purpose: the style owns visibility, and a
     style swap re-adds it with everything else. */
  map.addLayer({
    id: "selection-pin-halo",
    type: "circle",
    source: "selection",
    filter: ["==", ["geometry-type"], "Point"],
    maxzoom: GRID_MIN_ZOOM + 1,
    paint: {
      "circle-radius": 11,
      "circle-color": "#e8452c",
      "circle-opacity": [
        "interpolate",
        ["linear"],
        ["zoom"],
        GRID_MIN_ZOOM,
        0.25,
        GRID_MIN_ZOOM + 1,
        0,
      ],
    },
  });
  map.addLayer({
    id: "selection-pin",
    type: "circle",
    source: "selection",
    filter: ["==", ["geometry-type"], "Point"],
    maxzoom: GRID_MIN_ZOOM + 1,
    paint: {
      "circle-radius": 5,
      "circle-color": "#e8452c",
      "circle-stroke-color": "#ffffff",
      "circle-stroke-width": 2,
      "circle-opacity": [
        "interpolate",
        ["linear"],
        ["zoom"],
        GRID_MIN_ZOOM,
        1,
        GRID_MIN_ZOOM + 1,
        0,
      ],
      "circle-stroke-opacity": [
        "interpolate",
        ["linear"],
        ["zoom"],
        GRID_MIN_ZOOM,
        1,
        GRID_MIN_ZOOM + 1,
        0,
      ],
    },
  });
};

/* The viewport as a download request. Clamped: a wrapped world view reports
   longitudes past ±180, and the server (rightly) refuses them. Zoom 15 is
   the source's deepest level; vector tiles overzoom crisply past it. */
const MERCATOR_MAX_LAT = 85.0511;
const regionOf = (map: maplibregl.Map): Region => {
  const b = map.getBounds();
  return {
    min_lon: Math.max(-180, b.getWest()),
    min_lat: Math.max(-MERCATOR_MAX_LAT, b.getSouth()),
    max_lon: Math.min(180, b.getEast()),
    max_lat: Math.min(MERCATOR_MAX_LAT, b.getNorth()),
    max_zoom: 15,
  };
};

const cellPolygon = (cell: {
  latLo: number;
  latHi: number;
  lonLo: number;
  lonHi: number;
}): GeoJSON.Feature => ({
  type: "Feature",
  properties: {},
  geometry: {
    type: "Polygon",
    coordinates: [
      [
        [cell.lonLo, cell.latLo],
        [cell.lonHi, cell.latLo],
        [cell.lonHi, cell.latHi],
        [cell.lonLo, cell.latHi],
        [cell.lonLo, cell.latLo],
      ],
    ],
  },
});

/* The square's centre, for the zoomed-out pin. */
const cellCenter = (cell: {
  latLo: number;
  latHi: number;
  lonLo: number;
  lonHi: number;
}): GeoJSON.Feature => ({
  type: "Feature",
  properties: {},
  geometry: {
    type: "Point",
    coordinates: [
      (cell.lonLo + cell.lonHi) / 2,
      (cell.latLo + cell.latHi) / 2,
    ],
  },
});

export function MapView() {
  const container = useRef<HTMLDivElement>(null);
  /* `mapRef`, not `m` -- `m` is the message namespace throughout the UI. */
  const mapRef = useRef<maplibregl.Map | null>(null);
  const [ready, setReady] = useState(false);
  /* Tiles in flight for longer than the tracker's delay. Drives the bar
     across the top of the map -- indeterminate on purpose: MapLibre does
     not report done-versus-total tiles in any stable way, so a percentage
     would be theatre. */
  const [tilesLoading, setTilesLoading] = useState(false);
  const [truncated, setTruncated] = useState(false);
  /* Null when the middle of the view has a tile: the note is about where
     the user is looking, not about a corner of the screen. [depth] is the
     deepest zoom the archives hold there, -1 for nothing at all, which is
     a different sentence. */
  const [blank, setBlank] = useState<{ depth: number; } | null>(null);
  const [zoom, setZoom] = useState(0);
  /* Bumped after every style swap so the effects that draw onto the style
     (grid, selection) know their sources were just recreated empty. */
  const [styleEpoch, setStyleEpoch] = useState(0);
  const styleVersion = useRef(0);

  const client = useQueryClient();
  const selection = useAppStore((s) => s.selection);
  const select = useAppStore((s) => s.select);
  const flyTo = useAppStore((s) => s.flyTo);
  /* Read during render, not inside the effect: the component re-renders
     when the locale changes, so this is the honest dependency. */
  useAppStore((s) => s.locale);
  const mapLabel = m.map_label();
  const setBasemapFailed = useAppStore((s) => s.setBasemapFailed);
  const clearBasemapFailed = useAppStore((s) => s.clearBasemapFailed);
  const downloadOpen = useAppStore((s) => s.downloadOpen);
  const openDownload = useAppStore((s) => s.openDownload);
  const closeDownload = useAppStore((s) => s.closeDownload);

  /* ------------------------------------------------------------- setup */
  useEffect(() => {
    if (!container.current || mapRef.current) return;

    const map = new maplibregl.Map({
      container: container.current,
      style: buildStyle(styleVersion.current),
      center: [-0.1278, 51.5074],
      zoom: 19,
      maxZoom: 23,
      hash: false,
      attributionControl: { compact: true },
      /* Arrow keys pan, +/- zoom. On by default; named here because it is
         load-bearing for keyboard access rather than incidental. */
      keyboard: true,
    });
    mapRef.current = map;
    window.__tessarium_map = map;

    map.addControl(new maplibregl.NavigationControl({ visualizePitch: false }));
    map.addControl(
      new maplibregl.GeolocateControl({
        positionOptions: { enableHighAccuracy: true },
        trackUserLocation: false,
      }),
    );
    map.addControl(
      new maplibregl.ScaleControl({ maxWidth: 120, unit: "metric" }),
    );

    map.on("load", () => {
      addOverlay(map);
      setZoom(map.getZoom());
      setReady(true);
    });

    return () => {
      map.remove();
      mapRef.current = null;
      delete window.__tessarium_map;
    };
  }, []);

  /* The loading bar's feed: dataloading fires when any source or the style
     starts fetching, idle when the map is fully drawn. The tracker holds
     the bar back through sub-delay bursts (every pan fires these), so it
     appears only when arrival is genuinely lagging -- a long flight to an
     area whose detail is still streaming in. */
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !ready) return;
    const tracker = createLoadingTracker(setTilesLoading);
    const onLoading = () => tracker.loading();
    const onIdle = () => tracker.idle();
    map.on("dataloading", onLoading);
    map.on("idle", onIdle);
    return () => {
      tracker.dispose();
      map.off("dataloading", onLoading);
      map.off("idle", onIdle);
      setTilesLoading(false);
    };
  }, [ready]);

  /* A missing basemap must not look like a broken application. The grid and
     the addressing still work over blank space, so say what is missing
     instead of showing an empty screen. Asked of the server directly with a
     HEAD request: MapLibre's error events describe a failed fetch without
     naming what failed, and sniffing their messages misses. */
  const basemapPresent = useBasemapPresent();
  useEffect(() => {
    if (basemapPresent.data === false) setBasemapFailed();
  }, [basemapPresent.data, setBasemapFailed]);

  /* -------------------------------------------------------- grid refresh */
  const refreshGrid = useCallback(async () => {
    const map = mapRef.current;
    if (!map) return;
    setZoom(map.getZoom());

    const source = map.getSource("grid") as
      | maplibregl.GeoJSONSource
      | undefined;
    if (map.getZoom() < GRID_MIN_ZOOM) {
      setTruncated(false);
      source?.setData(emptyGeoJson);
      return;
    }

    const b = map.getBounds();
    /* Geometry only. The overlay never carries addresses, so a refresh needs
       no key and costs no HMACs -- it is a walk over the integer grid.

       A refresh in flight when the user locks still has to fail harmlessly,
       so the catch stays. */
    const g = await fetchGrid(
      client,
      {
        latLo: b.getSouth(),
        lonLo: b.getWest(),
        latHi: b.getNorth(),
        lonHi: b.getEast(),
      },
      CELL_LIMIT,
    ).catch(() => null);
    if (!g) return;

    setTruncated(g.truncated);

    const features: GeoJSON.Feature[] = new Array(g.count);
    for (let i = 0; i < g.count; i++) {
      features[i] = cellPolygon({
        latLo: g.cells[i * 4]!,
        latHi: g.cells[i * 4 + 1]!,
        lonLo: g.cells[i * 4 + 2]!,
        lonHi: g.cells[i * 4 + 3]!,
      });
    }
    source?.setData({ type: "FeatureCollection", features });
  }, [client]);

  // biome-ignore lint/correctness/useExhaustiveDependencies: styleEpoch is deliberate -- a style swap recreates the grid source empty, so the effect must re-run to refill it
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !ready) return;
    map.on("moveend", refreshGrid);
    map.on("zoomend", refreshGrid);
    void refreshGrid();
    return () => {
      map.off("moveend", refreshGrid);
      map.off("zoomend", refreshGrid);
    };
  }, [ready, refreshGrid, styleEpoch]);

  /* ------------------------------------------------------- coverage edge */

  /* Where the basemap stops. Asked of the server after every settled move,
     because the honest answer is "which tiles are on disk right now" and
     that changes under the map: a download adds them, a removal takes them
     away, and browsing fills them in while the user pans.

     The zoom asked about is the one MapLibre will REQUEST -- the camera
     zoom floored, clamped to the source's own depth -- not the camera
     zoom. Past the source's maxzoom the map overzooms the deepest tiles it
     has rather than asking for more, so a query at the camera zoom would
     report a blank that is not on screen. */
  const coverageSeq = useRef(0);
  const refreshCoverage = useCallback(async () => {
    const map = mapRef.current;
    if (!map) return;
    /* Only the newest question gets to answer. React Query hands back a
       cached view in a microtask while a fresh one is still in flight, so
       returning to somewhere you were ten seconds ago resolves BEFORE the
       place you passed through -- and the older answer then painted over
       the newer one. Sitting on blank ground, that cleared the wash and
       the note and left the app saying nothing at all, which is the state
       this whole feature exists to replace. */
    const mine = ++coverageSeq.current;
    const fill = map.getSource("coverage") as
      | maplibregl.GeoJSONSource
      | undefined;
    const edge = map.getSource("coverage-edge") as
      | maplibregl.GeoJSONSource
      | undefined;
    if (!fill || !edge) return;

    const source = map.getSource("protomaps") as unknown as {
      maxzoom?: number;
    } | undefined;
    /* Clamped to the depth the tile grid is cut to, not just to what the
       source says: MapLibre reports a vector source's spec default of 22
       until tiles.json arrives, so the first query after every style swap
       asked about zoom 19 over an archive that stops at 15 -- which the
       server refused, four times a run. */
    const deepest = Math.min(
      MAX_TILE_ZOOM,
      typeof source?.maxzoom === "number" ? source.maxzoom : MAX_TILE_ZOOM,
    );
    const view = regionOf(map);
    const zoom = Math.max(0, Math.min(deepest, Math.floor(map.getZoom())));

    /* A failure here must leave the map alone rather than claim the world
       is blank: the server is on loopback, but a query can still be cut
       off mid-style-swap or refused for asking about too much at once. */
    const answer = await fetchCoverage(client, {
      min_lon: view.min_lon,
      min_lat: view.min_lat,
      max_lon: view.max_lon,
      max_lat: view.max_lat,
      zoom,
    }).catch(() => null);
    if (!answer || mine !== coverageSeq.current) return;

    fill.setData({
      type: "FeatureCollection",
      features: rectsToFeatures(absentRects(answer), answer.zoom),
    });
    edge.setData({
      type: "FeatureCollection",
      features: blankEdges(answer, answer.zoom),
    });
    setBlank(centreIsBlank(answer) ? { depth: answer.depth } : null);
  }, [client]);

  /* Nothing to say when there is no archive at all -- the missing-basemap
     banner already says it, and a grey wash under it would be a second
     voice saying the same thing worse. */
  const coverageOff = basemapPresent.data === false;
  /* Read here rather than reaching for [browseEnabled], which is declared
     with the browse effect further down: the same fact, and this effect
     must not depend on the order the two happen to be written in. */
  const browseSettles = useBasemapSettings().data?.browse_cache === true;
  // biome-ignore lint/correctness/useExhaustiveDependencies: styleEpoch is deliberate -- a style swap recreates the coverage sources empty, so the effect must re-run to refill them
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !ready) return;
    if (coverageOff) {
      setBlank(null);
      return;
    }
    /* Browsing fetches the viewport's missing tiles 1.2 s after a pan
       settles, so asking immediately would wash the screen grey and offer
       a download for the tiles the app is already fetching -- every pan,
       for over a second. When browsing is on the question waits until
       after that fetch would have landed; the browse's own success
       refreshes this sooner when tiles really do arrive. */
    let timer: ReturnType<typeof setTimeout> | undefined;
    const refresh = () => {
      clearTimeout(timer);
      if (!browseSettles) {
        void refreshCoverage();
        return;
      }
      timer = setTimeout(() => void refreshCoverage(), BROWSE_SETTLE_MS + 400);
    };
    map.on("moveend", refresh);
    map.on("zoomend", refresh);
    refresh();
    return () => {
      clearTimeout(timer);
      map.off("moveend", refresh);
      map.off("zoomend", refresh);
    };
  }, [ready, refreshCoverage, styleEpoch, coverageOff, browseSettles]);

  /* -------------------------------------------------- offline downloads */

  /* Swap in the freshly downloaded archive without reloading the page -- a
     reload would drop the key and send the user back to the phrase gate. */
  const rebuildBasemap = useCallback(() => {
    const map = mapRef.current;
    if (!map) return;
    styleVersion.current += 1;
    /* Listener BEFORE setStyle. When MapLibre's style diff succeeds it
       fires style.load synchronously inside the setStyle call, so a
       listener registered after the call has already missed it -- which is
       how the grid silently vanished after every download. When the diff
       fails, MapLibre rebuilds the style from scratch and the event fires
       asynchronously instead; registering first serves both timings. */
    map.once("style.load", () => {
      addOverlay(map);
      setStyleEpoch((epoch) => epoch + 1);
    });
    map.setStyle(buildStyle(styleVersion.current));
  }, []);

  /* ------------------------------------------------------ browse cache */

  /* When the user has opted in and is online, a settled pan fetches the
     viewport's missing tiles into the cache. Debounced past the pan, one
     in flight at a time, and silent: offline is a normal state here, not
     an error to toast about. The server enforces the setting again -- this
     gate is UX, that one is policy. */
  const settings = useBasemapSettings();
  const browseMutate = useBasemapBrowse().mutate;
  const browseInFlight = useRef(false);
  const browseEnabled = settings.data?.browse_cache === true;
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !ready || !browseEnabled) return;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const settle = () => {
      clearTimeout(timer);
      timer = setTimeout(() => {
        if (!navigator.onLine || browseInFlight.current) return;
        browseInFlight.current = true;
        const view = regionOf(map);
        /* Floor, not round: a vector source's displayed canonical zoom is
           the floor of the camera zoom, so rounding would spend the fetch
           on z+1 tiles the screen never asks for at any half-step. */
        const zoom = Math.max(0, Math.min(15, Math.floor(map.getZoom())));
        browseMutate({
          min_lon: view.min_lon,
          min_lat: view.min_lat,
          max_lon: view.max_lon,
          max_lat: view.max_lat,
          zoom,
        }, {
          onSettled: () => {
            browseInFlight.current = false;
          },
          onSuccess: ({ fetched, zoom: written }) => {
            if (fetched === 0) return;
            /* Mid-style-swap there is no source to talk to, and both calls
               below throw without one. The tiles are on disk; the style
               being built will ask for them. */
            const source = map.getSource("protomaps");
            if (!source) return;
            /* The tiles on screen were 204s a moment ago. Below the
               source's advertised depth, re-asking is enough; past it,
               MapLibre will never ask -- the source's maxzoom was pinned
               from tiles.json at style time -- so the style is rebuilt to
               learn the deeper coverage the cache just gained.

               Measured against the depth the SERVER wrote, never the one
               this pan asked for: against a source shallower than the
               camera those two differ forever, and comparing the request
               would rebuild the style on every pan, chasing tiles that can
               never arrive. */
            const maxzoom =
              (source as unknown as { maxzoom?: number; }).maxzoom;
            if (typeof maxzoom === "number" && written > maxzoom) {
              rebuildBasemap();
            } else {
              map.refreshTiles("protomaps");
            }
            /* Tiles just landed where there were none, so the grey wash
               over them is now a lie. Invalidated rather than refetched
               blindly: the cached answer for this exact view is what
               would otherwise be handed back. */
            client.invalidateQueries({ queryKey: ["basemap-coverage"] });
            void refreshCoverage();
          },
        });
      }, BROWSE_SETTLE_MS);
    };
    map.on("moveend", settle);
    settle();
    return () => {
      clearTimeout(timer);
      map.off("moveend", settle);
    };
  }, [
    ready,
    browseEnabled,
    browseMutate,
    rebuildBasemap,
    client,
    refreshCoverage,
  ]);

  /* The region is frozen when the card opens. Panning while it is open
     changes the next download, not the one being confirmed. */
  const [region, setRegion] = useState<Region | null>(null);
  useEffect(() => {
    if (!downloadOpen) {
      setRegion(null);
      return;
    }
    const map = mapRef.current;
    if (map) setRegion(regionOf(map));
  }, [downloadOpen]);

  /* Watched here rather than in the card so a download the user closed the
     card on still finishes loudly: the toast fires and the map refreshes
     whether or not the card is mounted.

     Transitions are detected by (generation, state) changing, not by having
     seen a running state first: a small region from a fast source goes
     idle-to-done entirely between two polls, and only the generation says
     the news is new. The first poll after mount is never news. */
  const basemapJob = useBasemapStatus();
  const prevJob = useRef<{ generation: number; state: Job["state"]; } | null>(
    null,
  );
  useEffect(() => {
    const current = basemapJob.data;
    if (!current) return;
    const previous = prevJob.current;
    prevJob.current = {
      generation: current.generation,
      state: current.job.state,
    };
    if (!previous) return;
    if (
      previous.generation === current.generation
      && previous.state === current.job.state
    ) {
      return;
    }
    const job = current.job;
    if (job.state === "done") {
      toast.success(m.map_download_done());
      /* The archive exists now; the cached "absent" answer must not outlive
         it and resurrect the banner, and every cached estimate is stale --
         tiles just landed on disk that the numbers do not know about. */
      client.setQueryData(["basemap-present"], true);
      client.invalidateQueries({ queryKey: ["basemap-estimate"] });
      client.invalidateQueries({ queryKey: ["basemap-ledger"] });
      client.invalidateQueries({ queryKey: ["basemap-coverage"] });
      clearBasemapFailed();
      closeDownload();
      rebuildBasemap();
    } else if (job.state === "removed") {
      toast.success(
        job.freed_bytes === 0
          ? m.map_removed_none()
          : m.map_removed_done({ size: formatBytes(job.freed_bytes) }),
      );
      /* Tiles left the disk -- and removing the last region deletes the
         archive outright, so "present" is a question again, not a fact. */
      client.invalidateQueries({ queryKey: ["basemap-present"] });
      client.invalidateQueries({ queryKey: ["basemap-estimate"] });
      client.invalidateQueries({ queryKey: ["basemap-ledger"] });
      client.invalidateQueries({ queryKey: ["basemap-coverage"] });
      rebuildBasemap();
    } else if (job.state === "failed") {
      /* Attributed when attribution is possible: a poll that saw the
         compacting state knows this failure is the fold's, not a
         download's. A fold that failed between two polls still reads as a
         download failure -- the poll simply never knew better. */
      toastError(
        previous.state === "compacting"
          ? m.map_compact_failed({ reason: job.reason })
          : m.map_download_failed({ reason: job.reason }),
      );
      /* A failure can still follow a successful archive write -- the entry
         lands with the last part's rename, before the assets fetch -- so
         the list must not keep showing the world before it. */
      client.invalidateQueries({ queryKey: ["basemap-ledger"] });
      client.invalidateQueries({ queryKey: ["basemap-coverage"] });
      client.invalidateQueries({ queryKey: ["basemap-estimate"] });
      client.invalidateQueries({ queryKey: ["basemap-present"] });
    } else if (job.state === "cancelled") {
      toast(m.map_download_cancelled());
      client.invalidateQueries({ queryKey: ["basemap-ledger"] });
      client.invalidateQueries({ queryKey: ["basemap-coverage"] });
      client.invalidateQueries({ queryKey: ["basemap-estimate"] });
      client.invalidateQueries({ queryKey: ["basemap-present"] });
      closeDownload();
    }
    /* Every ending above may have changed what is on disk -- a download
       that finished, a removal, or a failure after some parts had already
       landed -- so the mask is asked again here rather than left stale
       until the next pan. */
    if (!isRunning(job)) void refreshCoverage();
  }, [
    basemapJob.data,
    client,
    clearBasemapFailed,
    closeDownload,
    rebuildBasemap,
    refreshCoverage,
  ]);

  /* --------------------------------------------------------- selecting */
  const selectAt = useCallback(
    async (lat: number, lon: number) => {
      /* One square, one address, asked for only when the user asks. */
      const result = await fetchAddress(client, lat, lon).catch(
        (e: unknown) => {
          toastError(e instanceof Error ? e.message : String(e));
          return null;
        },
      );
      if (result) {
        select({ address: result.address, lat, lon, cell: result.cell });
      }
    },
    [client, select],
  );

  useEffect(() => {
    const map = mapRef.current;
    if (!map || !ready) return;
    const onClick = (e: maplibregl.MapMouseEvent) =>
      void selectAt(e.lngLat.lat, e.lngLat.lng);
    map.on("click", onClick);
    return () => {
      map.off("click", onClick);
    };
  }, [ready, selectAt]);

  /* Keyboard equivalent of a click. MapLibre already moves and zooms the map
     from the keyboard; what it has no notion of is "select", so Enter takes
     the square at the centre of the view -- which is where flyTo lands and
     where the reticle is drawn. Without this the map is mouse-only. */
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !ready) return;
    const canvas = map.getCanvas();
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Enter" && e.key !== " ") return;
      e.preventDefault();
      const c = map.getCenter();
      void selectAt(c.lat, c.lng);
    };
    canvas.addEventListener("keydown", onKey);
    return () => canvas.removeEventListener("keydown", onKey);
  }, [ready, selectAt]);

  /* Cursor feedback, so the map reads as clickable, and an accessible name so
     it is not an unlabelled tab stop. Re-applied when the language changes. */
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !ready) return;
    const canvas = map.getCanvas();
    canvas.style.cursor = "crosshair";
    canvas.setAttribute("role", "application");
    canvas.setAttribute("aria-label", mapLabel);
  }, [ready, mapLabel]);

  /* ---------------------------------------------------- selection drawing */
  // biome-ignore lint/correctness/useExhaustiveDependencies: styleEpoch is deliberate -- a style swap recreates the selection source empty, so the current selection must be drawn again
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !ready) return;
    const source = map.getSource("selection") as
      | maplibregl.GeoJSONSource
      | undefined;
    source?.setData(
      selection
        ? {
          type: "FeatureCollection",
          features: [cellPolygon(selection.cell), cellCenter(selection.cell)],
        }
        : emptyGeoJson,
    );
  }, [selection, ready, styleEpoch]);

  /* ------------------------------------------------------------- fly to */
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !ready || !flyTo) return;
    map.flyTo({
      center: [flyTo.lon, flyTo.lat],
      zoom: Math.max(map.getZoom(), 20),
      duration: 1200,
    });
  }, [flyTo, ready]);

  /* The note can go away without the user doing anything -- browsed tiles
     land, a fly-to settles -- and if its button held the keyboard the page
     would drop to <body>, where arrow keys and Enter do nothing at all.
     Handed back to the map, which is what the note was covering.

     Whether focus was inside is RECORDED while the note is alive rather
     than read when it goes: by the time an effect's cleanup runs, React
     has already mutated the DOM and the answer is always "no" -- which is
     how the first version of this passed review and failed the test. And
     focus leaving to nowhere (a null relatedTarget, which is what removing
     a focused element looks like) is not the user moving on, so it does
     not clear the flag. */
  const notesRef = useRef<HTMLDivElement>(null);
  const noteHeldFocus = useRef(false);
  const noteShown = blank !== null && !downloadOpen;
  useLayoutEffect(() => {
    const node = notesRef.current;
    if (!noteShown || !node) return;
    const took = () => {
      noteHeldFocus.current = true;
    };
    const gave = (event: FocusEvent) => {
      const next = event.relatedTarget as Node | null;
      if (next && !node.contains(next)) noteHeldFocus.current = false;
    };
    node.addEventListener("focusin", took);
    node.addEventListener("focusout", gave);
    return () => {
      node.removeEventListener("focusin", took);
      node.removeEventListener("focusout", gave);
      if (noteHeldFocus.current) {
        noteHeldFocus.current = false;
        mapRef.current?.getCanvas().focus();
      }
    };
  }, [noteShown]);

  return (
    <div className="map-wrap">
      <div ref={container} className="map" />
      {
        /* Indeterminate by design; see tilesLoading. Present in the tree
          only while loading, so screen readers hear the transition. */
      }
      {tilesLoading && (
        <div
          className="map-loading"
          role="progressbar"
          aria-label={m.map_loading_detail()}
        />
      )}
      {
        /* The keyboard target. Only meaningful once the map has focus, which is
          why it is announced rather than drawn. */
      }
      <p className="sr-only">{m.map_keyboard_hint()}</p>
      {
        /* Marks the square Enter will take, so keyboard use has the same
          "which one am I about to pick" feedback the pointer gets. */
      }
      <div className="reticle" aria-hidden />
      {
        /* Search sits over the map rather than in the panel: it moves the
          map, and the panel is about the square already chosen. */
      }
      <div className="map-search">
        <PlaceSearch
          onPick={(lon, lat) => {
            const map = mapRef.current;
            if (!map) return;
            /* Close enough to read streets, not so close that a town
              centre fills the screen with one building. */
            map.flyTo({
              center: [lon, lat],
              zoom: Math.max(map.getZoom(), 15),
            });
          }}
        />
      </div>
      <div className="map-actions">
        <IconButton
          label={m.map_download_open()}
          icon={<Download size={18} aria-hidden />}
          pressed={downloadOpen}
          onClick={() => (downloadOpen ? closeDownload() : openDownload())}
        />
      </div>
      {downloadOpen && region && (
        <DownloadCard region={region} job={basemapJob.data?.job} />
      )}
      {
        /* One column, because these are not mutually exclusive: a view can
          be outside coverage AND too far out for the grid, and two notes
          pinned to the same corner would sit on top of each other. */
      }
      <div className="map-notes" ref={notesRef}>
        {
          /* Hidden while the card is open: the note's whole purpose is to
            open that card, and leaving it on top of the thing it just
            opened puts a pill over the controls and wins the hit test. */
        }
        {blank && !downloadOpen && (
          <div className="map-note action" role="status">
            <span>{m.map_coverage_gap()}</span>
            <button
              type="button"
              className="note-action"
              onClick={() =>
                openDownload()}
            >
              {m.map_coverage_download()}
            </button>
          </div>
        )}
        {zoom < GRID_MIN_ZOOM && (
          <div className="map-note" role="status">
            {m.map_zoom_for_grid()}
          </div>
        )}
        {truncated && (
          <div className="map-note warn" role="status">
            {m.map_too_many_squares()}
          </div>
        )}
      </div>
    </div>
  );
}
