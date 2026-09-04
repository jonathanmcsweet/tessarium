/* The map, the grid overlay, and the click that turns a square into words. */

import { layers, namedFlavor } from "@protomaps/basemaps";
import { useQueryClient } from "@tanstack/react-query";
import maplibregl from "maplibre-gl";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
} from "react";
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
import { goTo } from "../core/camera";
import {
  absentRects,
  blankEdges,
  centreIsBlank,
  rectsToFeatures,
} from "../core/coverage";
import { createLoadingTracker } from "../core/loading";
import { fetchAddress, fetchGrid } from "../core/queries";
import { sayError } from "../core/refusal";
import { formatBytes, getLocale } from "../i18n";
import { m } from "../paraglide/messages";
import { useAppStore } from "../store";
import { type ResolvedTheme, useResolvedTheme } from "../theme";
import { toastError, toastNote, toastSuccess } from "../toast";
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

/* The map under the map. Its depth comes from the server -- see
   /world.json -- because it is a fact about which archives are on disk. */
const FLOOR_SOURCE = "protomaps-floor";

/* How long a pan is left to settle before the browse cache fetches what is
   missing. Named once because the coverage note has to outwait it: saying
   "not downloaded" about tiles that are already on their way is worse than
   saying nothing for a moment. */
const BROWSE_SETTLE_MS = 1200;

/* A ceiling on cells per viewport. Reached only when the viewport is unusually
   large for the zoom; truncation is drawn as a warning rather than silently
   producing a grid that stops halfway across the screen. */
const CELL_LIMIT = 12000;

/* How often to ask the map whether it has settled, while the loading bar is
   up. Only ever runs while the bar is visible, so it costs nothing in the
   ordinary case; short enough that a bar the `idle` event forgot about comes
   down before it reads as stuck. */
const SETTLE_POLL_MS = 250;

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

/* Whether a palette puts the map on a pale ground. Five schemes, and every
   map-side choice below -- the flavour, the sprite sheet, the overlay -- turns
   on this rather than on a list of names, so a sixth palette answers one
   question instead of being added to three lists. */
const isLight = (scheme: Scheme) =>
  scheme === "light" || scheme === "cyber-light";

/* Which pre-drawn sprite sheet the style asks for.

   The icons a map draws -- route-number shields most visibly -- are baked
   images, not flavour colours, so nothing in the palette can reach them.
   Protomaps' answer is a sheet per flavour, drawn once at build time, and
   we already carry all five; the style just names one. Naming `light` for
   every scheme, which is what this did, is what put white motorway shields
   on a black map: the map went dark around icons that could not follow.

   Low light takes `dark` rather than `black`. Their shields are the same
   near-black badge, but `black` is a reduced sheet -- Protomaps draws the
   points of interest for light and dark only -- so choosing it would trade
   white shields for 35 missing icons. A red sheet would need one drawn,
   which is a basemap build step and is on the roadmap. */
const spriteSheet = (scheme: Scheme) => (isLight(scheme) ? "light" : "dark");

/* The style, rebuilt whenever the archive on disk is replaced. Tiles come
   through the server's /tiles endpoint rather than from the archive file
   directly: the server is what knows about BOTH archives -- the browse
   cache and the main one -- and a missing tile is a quiet 204 instead of a
   logged error. The version number lands in the tile URL as a query string
   so MapLibre's per-URL caching cannot keep old tiles over new bytes. */
const buildStyle = (
  version: number,
  scheme: Scheme,
): maplibregl.StyleSpecification => ({
  version: 8,
  /* Everything the style needs is served from this origin. A style that
     reaches a CDN for glyphs looks fine online and renders unlabelled the
     first time someone opens it offline. */
  glyphs: "/basemap/fonts/{fontstack}/{range}.pbf",
  /* MapLibre appends .json and .png, so this names the flavour rather
     than the directory: sprites/v4/light.json and light.png. */
  sprite: `${window.location.origin}/basemap/sprites/v4/${spriteSheet(scheme)}`,
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
    /* The floor: the same tiles, cut to the depth that is everywhere.

       A tile source is one pyramid with one depth, and ours has holes --
       the downloader lets you take any region to any depth and they land
       in one archive. Renderers are built on the opposite assumption, that
       every tile inside the declared range exists, so a hole is drawn as
       an empty tile. Empty counts as data, so it WINS over the coarse tile
       already on screen: zoom into a region you only hold coarsely and the
       map you were looking at is replaced by nothing.

       Two sources instead of one, which is how the offline map apps do it
       -- a world dataset that is never absent, with regional detail
       composited over it. This one stops at the deepest zoom the archives
       cover the WHOLE planet at, so it is never asked for a tile that is
       not there; past that depth MapLibre overzooms rather than requesting,
       and an overzoomed tile cannot be missing. The detail source keeps its
       holes, and a hole in the TOP layer of two is transparent rather than
       blank.

       That depth is the server's to state and never a number written here:
       it is a fact about which archives are on disk and how complete they
       are, and a guess at it puts the holes straight back. /world.json
       carries it, the way /tiles.json carries the downloaded source's. The
       two do not overlap -- the detail source starts one zoom below where
       this one stops -- so a viewport is fetched once, not twice. */
    [FLOOR_SOURCE]: {
      type: "vector",
      url: `/world.json?v=${version}`,
    },
  },
  /* Place names follow the interface language, so switching to French does
     not leave an English map under translated controls. Protomaps wants a
     bare language subtag, not the full locale. */
  layers: basemapLayers(scheme),
});

/* The floor's layers, then the detail's, then the app's own on top.

   Re-ided, because the generator names layers after what they draw and not
   after the source they draw it from -- all 71 collide otherwise, and a
   style with two layers of one name is rejected. The background is dropped
   from the floor set for the same reason it exists only once: it paints the
   ground, and the detail set already carries it.

   The symbol layers are KEPT. Stripping them would be the obvious
   economy -- labels are the thing most likely to double -- and it would
   take the labels away from exactly the places where the floor is the only
   map there is. Somewhere you have not downloaded, the city name is the
   most useful thing on the screen.

   They do not double where detail exists, and the reason is order rather
   than collision: the detail set opens with `earth`, an opaque fill, so
   wherever the detail tile has data it paints over the whole floor stack
   underneath -- labels included. Checked on screen at London z11 and z16.
   That makes the ordering load-bearing: move a floor layer above the
   detail's ground and the duplication becomes real, with nothing left to
   prevent it. */
/* The low-light map: "black" with warmth added, key by key.

   Two moves, matching the two complaints a cold map draws in the dark. The
   ROADS -- black's near-neutral #14/#1f/#29 greys -- take a small red lift
   so a motorway is a warm line rather than a grey one. The LABELS, which are
   the brightest marks on the map, move from grey to a soft red: black's
   #999 city name would glow white-blue in a dark room, and that is the one
   thing this theme exists to prevent. Halos and the ground are left alone;
   they are already dark.

   Route-number shields are sprite images, not flavour colours, so they are
   not reachable from here at all -- `spriteSheet` above is what stops them
   being white, by asking for the dark sheet. Drawing a RED one is a basemap
   build step, noted on the roadmap. */
const NIGHT_ROADS = {
  tunnel_minor: "#2b2020",
  tunnel_link: "#2b2020",
  tunnel_major: "#2b2020",
  tunnel_highway: "#2b2020",
  minor_service: "#221a1a",
  minor_a: "#2f2323",
  minor_b: "#221a1a",
  link: "#221a1a",
  major: "#332626",
  highway: "#3a2929",
  bridges_minor: "#221a1a",
  bridges_link: "#2f2626",
  bridges_major: "#2f2626",
  bridges_highway: "#3a2929",
} as const;

const NIGHT_LABELS = {
  roads_label_minor: "#7a5c5c",
  roads_label_major: "#8a6666",
  ocean_label: "#9a7a7a",
  subplace_label: "#8a6a6a",
  city_label: "#c89d9d",
  state_label: "#6a5252",
  country_label: "#a07d7d",
  address_label: "#6a5252",
} as const;

const nightFlavor = (base: ReturnType<typeof namedFlavor>) => ({
  ...base,
  ...NIGHT_ROADS,
  ...NIGHT_LABELS,
});

const basemapLayers = (
  scheme: Scheme,
): maplibregl.LayerSpecification[] => {
  const lang = getLocale().split("-")[0] ?? "en";
  /* Protomaps ships a flavour per scheme, so a dark application does not
     have to sit next to a white map. Same generator, same layer ids -- only
     the paint differs -- which is why swapping it is a style rebuild and
     not a special case anywhere else. */
  /* Protomaps has no red flavour, so low light starts from "black" -- its
     darkest, least chromatic set -- and tints it here. Roads take a slight
     warm lift and the labels, which are the lightest things the map draws,
     move from grey toward a soft red so nothing on the map is a cold white
     in a room someone is keeping dark. */
  const flavor = scheme === "night"
    ? nightFlavor(namedFlavor("black"))
    : namedFlavor(isLight(scheme) ? "light" : "dark");
  const floor = layers(FLOOR_SOURCE, flavor, { lang })
    .filter((layer) => layer.type !== "background")
    .map((layer) => ({ ...layer, id: `${FLOOR_SOURCE}-${layer.id}` }));
  const detail = layers("protomaps", flavor, { lang });
  /* The ground goes under BOTH, which means pulling it out of the detail set
     rather than leaving it where the generator put it. Left in place it sits
     above the floor's layers and paints over every one of them -- which is
     what it did, and the screen stayed exactly as blank as before while the
     floor's tiles loaded happily underneath. */
  const ground = detail.filter((layer) => layer.type === "background");
  const over = detail.filter((layer) => layer.type !== "background");
  return [...ground, ...floor, ...over];
};

/* The grid and selection overlay, added on load and re-added after every
   style swap -- setStyle discards custom sources and layers. */
/* The grid and the coverage wash are drawn by this application rather than
   by the basemap, so they do not come with the flavour and have to be told
   which ground they are landing on. Dark values are lighter than the map,
   the way the light ones are darker than it: the point of both is to be
   read against the cartography, not to be a particular colour. */
type Scheme = ResolvedTheme;

/* The overlay's colours, read from the palette the document is wearing.

   These lived here once, as a Record over the five schemes -- a second copy
   of the palette that styles.css already owned, and the selection colour
   really was a copy: it is the accent, and the two had to be edited in
   step. Now styles.css is the only home (--color-map-* per palette), read
   through getComputedStyle so the engine that owns the cascade -- media
   queries included -- is the one resolving it. MapLibre needs literal
   colour strings, not var() references, which is why this is a read and
   not a stylesheet rule.

   Called at layer-add time, never cached: applyTheme sets the attribute
   synchronously in the store action, so by the time a style rebuild runs,
   the document is already wearing the palette being read. A missing token
   throws rather than painting MapLibre's silent black. */
const overlayColors = () => {
  const token = (name: string): string => {
    const value = getComputedStyle(document.documentElement)
      .getPropertyValue(name)
      .trim();
    if (!value) throw new Error(`css token ${name} is not defined`);
    return value;
  };
  return {
    blank: token("--color-map-blank"),
    blankOpacity: Number(token("--map-blank-opacity")),
    edge: token("--color-map-edge"),
    grid: token("--color-map-grid"),
    /* The selected square and its pin: the loudest mark on the map wears
       the palette's own accent, the same token the address line spends. */
    select: token("--color-accent"),
    /* And the pin's separating ring is what the palette says sits against
       a filled accent. It was a literal #ffffff -- a colour belonging to
       no palette, and in low light a pure white flash on the one screen
       built to avoid one. */
    onSelect: token("--color-on-accent"),
  };
};

const addOverlay = (map: maplibregl.Map) => {
  /* Adding twice throws. Cannot happen today, but the callers are event
     listeners around a style swap whose timing MapLibre does not promise. */
  if (map.getSource("coverage")) return;
  const colors = overlayColors();
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
    /* Heavier than a hint on purpose, and only ever over ground the map
       draws nothing at all for: there is no cartography underneath to
       obscure there, and a wash faint enough to be tasteful over a drawn
       map was invisible over a blank one -- 1.2:1 against the background,
       which is no signal at all. What keeps it off a drawn map is the data
       it is given, not this. */
    paint: {
      "fill-color": colors.blank,
      "fill-opacity": colors.blankOpacity,
    },
  });
  map.addLayer({
    id: "coverage-line",
    type: "line",
    source: "coverage-edge",
    paint: {
      "line-color": colors.edge,
      "line-width": 1.5,
      "line-opacity": 0.85,
    },
  });

  map.addLayer({
    id: "grid-lines",
    type: "line",
    source: "grid",
    paint: {
      "line-color": colors.grid,
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
    paint: { "fill-color": colors.select, "fill-opacity": 0.35 },
  });
  map.addLayer({
    id: "selection-outline",
    type: "line",
    source: "selection",
    filter: ["==", ["geometry-type"], "Polygon"],
    paint: { "line-color": colors.select, "line-width": 2 },
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
      "circle-color": colors.select,
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
      "circle-color": colors.select,
      "circle-stroke-color": colors.onSelect,
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

/* A note over the map: transparent to the pointer, wide enough for a
   sentence in any of six languages. bg-card, not white: this floats over
   the map in both themes, and a literal white here was exactly the thing
   the token audit could not see -- it shipped as a white pill with
   near-white text through the dark theme's whole first release. */
const NOTE = "map-note pointer-events-none max-w-full border border-line "
  + "bg-card/95 px-4 py-1.5 text-center text-sm shadow-card";

/* One that offers something to do lays its text and action out in a row,
   wrapping on a narrow screen rather than pushing the button off the map.
   The pill itself stays transparent to the pointer and only the button takes
   it back: on a phone this sits over the bottom of the map, which is exactly
   where a thumb starts a pan, and a pill that swallowed that drag made the
   map feel broken. */
const NOTE_ACTION =
  "action flex flex-wrap items-center justify-center gap-x-2.5 gap-y-1 "
  + "py-1.5 pr-2 pl-4 text-left";

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
  /* Null when the middle of the view has a tile at the zoom being drawn:
     the note is about where the user is looking, not about a corner of the
     screen. */
  const [blank, setBlank] = useState(false);
  const [zoom, setZoom] = useState(0);
  /* Bumped after every style swap so the effects that draw onto the style
     (grid, selection) know their sources were just recreated empty. */
  const [styleEpoch, setStyleEpoch] = useState(0);
  const styleVersion = useRef(0);

  /* The scheme the style is built from. Mirrored into a ref because the
     style is built inside effects and callbacks that must not re-run when
     it changes -- the rebuild below is what handles a change, once, rather
     than every listener re-registering. */
  const scheme = useResolvedTheme(useAppStore((s) => s.theme));
  const schemeRef = useRef(scheme);
  schemeRef.current = scheme;

  const client = useQueryClient();
  const selection = useAppStore((s) => s.selection);
  const select = useAppStore((s) => s.select);
  const flyTo = useAppStore((s) => s.flyTo);
  const requestFlyTo = useAppStore((s) => s.requestFlyTo);
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
      style: buildStyle(styleVersion.current, schemeRef.current),
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
     starts fetching; idle waits for the map to be fully drawn AND the
     camera to rest. So the bar shows while the map is still working --
     tiles genuinely lagging, or a flyTo longer than the tracker's delay
     still settling -- which is the user-facing meaning of "rendering but
     not done yet". The tracker only guards against flicker on sub-delay
     bursts, which every small pan fires.

     `idle` alone is not enough to take the bar back down. MapLibre fires it
     from inside a render, and it renders only while something is dirty -- so
     a load that resolves with nothing new to draw can raise the bar and then
     never fire the event that lowers it. Rare while every tile was a fresh
     download; ordinary now that they come back from the cache in
     milliseconds, and it showed up as a stuck bar in the end-to-end suite
     with the map itself reporting fully loaded. While the bar is up, ask the
     map instead of waiting to be told. */
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !ready) return;
    let poll: ReturnType<typeof setInterval> | undefined;
    const stopPolling = () => {
      if (poll !== undefined) {
        clearInterval(poll);
        poll = undefined;
      }
    };
    const tracker = createLoadingTracker((on) => {
      setTilesLoading(on);
      if (!on) return stopPolling();
      poll ??= setInterval(() => {
        if (map.loaded() && !map.isMoving()) tracker.idle();
      }, SETTLE_POLL_MS);
    });
    const onLoading = () => tracker.loading();
    const onIdle = () => tracker.idle();
    map.on("dataloading", onLoading);
    map.on("idle", onIdle);
    return () => {
      stopPolling();
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
  const gridSeq = useRef(0);
  const refreshGrid = useCallback(async () => {
    const map = mapRef.current;
    if (!map) return;
    /* Only the newest question gets to answer -- the same hazard
       refreshCoverage guards against below, for the same reason. fetchGrid
       goes through React Query with a 30s staleTime, so panning back to
       somewhere visited seconds ago resolves from cache in a microtask while
       the fresh viewport is still walking the grid in the worker. The older
       answer then lands second and paints its cells over the viewport the
       user has already left, and drags setTruncated back with it. */
    const mine = ++gridSeq.current;
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
       no key and costs no MAC calls -- it is a walk over the integer grid.

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
    if (!g || mine !== gridSeq.current) return;

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

     The camera zoom is sent as it is, and the server decides what to
     answer about. Past a source's own depth MapLibre overzooms the deepest
     tiles it has rather than asking for more, so the question does have to
     be clamped -- but only the server knows how deep the downloaded
     archives really go, and having the browser clamp against the depth
     `/tiles.json` advertised is what forced that number to lie. */
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

    const view = regionOf(map);
    /* Capped at the deepest zoom the tile grid is cut to, which is a limit
       of the format rather than a fact about what is downloaded: the
       server refuses a question past it. Everything else about how deep to
       ask is the server's to decide. */
    const zoom = Math.max(
      0,
      Math.min(MAX_TILE_ZOOM, Math.floor(map.getZoom())),
    );

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

    /* The wash says "nothing is drawn here", and since the floor went in
       that is usually false: these tiles are missing at the zoom being
       DISPLAYED, and the floor draws underneath them anyway. Darkening a
       map the user can plainly see would be the rug-pull again in another
       form, so the fill gets no rectangles at all where there is a floor to
       obscure -- withheld rather than made transparent, so that "is the
       blank ground painted" stays a question about what is on screen.

       The edge line is not withheld. It marks where the downloaded detail
       stops, which is true either way and is the one thing on screen that
       shows the shape of what you hold. */
    fill.setData({
      type: "FeatureCollection",
      features: answer.floor
        ? []
        : rectsToFeatures(absentRects(answer), answer.zoom),
    });
    edge.setData({
      type: "FeatureCollection",
      features: blankEdges(answer, answer.zoom),
    });
    setBlank(centreIsBlank(answer));
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
      setBlank(false);
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
    map.setStyle(buildStyle(styleVersion.current, schemeRef.current));
  }, []);

  /* The map's labels are asked for in the interface language, and
     `basemapLayers` reads that language once, when the style is built. So a
     language chosen after the map exists reached the panel and left the map
     in the old one until something else happened to rebuild the style -- a
     download, or a removal. Rebuilding here is what makes the comment above
     `basemapLayers` describe the behaviour rather than the intent.

     Skipped on the first run: the map was created with the current language
     already, and rebuilding it on mount would throw away the style the map
     just loaded. */
  const locale = useAppStore((s) => s.locale);
  const styledFor = useRef(locale);
  useEffect(() => {
    if (!ready || styledFor.current === locale) return;
    styledFor.current = locale;
    rebuildBasemap();
  }, [locale, ready, rebuildBasemap]);

  /* Same shape for the colour scheme, and for the same reason: the flavour
     and the overlay's own colours are read when the style is built, so a
     theme chosen afterwards -- or a device that turned dark at dusk --
     needs the style rebuilt to reach the map. Skipped on the first run,
     where the map was created with the current scheme already. */
  const styledAs = useRef(scheme);
  useEffect(() => {
    if (!ready || styledAs.current === scheme) return;
    styledAs.current = scheme;
    rebuildBasemap();
  }, [scheme, ready, rebuildBasemap]);

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
  /* Turning browsing OFF deletes cache.pmtiles, and the floor's depth is
     measured across every archive including that one -- so a cache that had
     completed a shallow zoom level takes the floor down with it, leaving the
     style advertising a depth the archives no longer reach. That is a hole
     at the floor's own maxzoom, which is the rug-pull again. Rebuilding asks
     the server for both depths afresh. Only on the way off: a floor that
     turns out to be deeper than advertised draws fine, it is the other
     direction that breaks. */
  const wasBrowsing = useRef(browseEnabled);
  useEffect(() => {
    if (wasBrowsing.current && !browseEnabled && ready) rebuildBasemap();
    wasBrowsing.current = browseEnabled;
  }, [browseEnabled, ready, rebuildBasemap]);
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
              /* Both sources. They read the same archive through the same
                 endpoint but keep their own copies, so refreshing one
                 leaves the other holding the empty tile it cached from a
                 204 -- and the floor is the one drawn where tiles were
                 missing, which is exactly where a browse fetch lands. */
              map.refreshTiles("protomaps");
              map.refreshTiles(FLOOR_SOURCE);
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
     changes the next download, not the one being confirmed.

     Published to the store rather than held here: the card itself now draws
     in the side panel, which has no map to ask. This is the only thing the
     map has to hand over for that to work. */
  const setDownloadRegion = useAppStore((s) => s.setDownloadRegion);
  useEffect(() => {
    if (!downloadOpen) {
      setDownloadRegion(null);
      return;
    }
    const map = mapRef.current;
    if (map) setDownloadRegion(regionOf(map));
  }, [downloadOpen, setDownloadRegion]);

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
      toastSuccess(m.map_download_done());
      /* The archive exists now; the cached "absent" answer must not outlive
         it and resurrect the banner, and every cached estimate is stale --
         tiles just landed on disk that the numbers do not know about.
         Inactive estimates are DROPPED, not merely invalidated: a query
         with no live observer never refetches, and a reopened download
         card would be served the stale answer synchronously -- flashing a
         world offer the disk already satisfied -- while the refetch runs.
         Dropped, the card starts at pending and says nothing wrong. */
      client.setQueryData(["basemap-present"], true);
      client.removeQueries({
        queryKey: ["basemap-estimate"],
        type: "inactive",
      });
      client.invalidateQueries({ queryKey: ["basemap-estimate"] });
      client.invalidateQueries({ queryKey: ["basemap-ledger"] });
      client.invalidateQueries({ queryKey: ["basemap-coverage"] });
      clearBasemapFailed();
      closeDownload();
      rebuildBasemap();
    } else if (job.state === "removed") {
      toastSuccess(
        job.freed_bytes === 0
          ? m.map_removed_none()
          : m.map_removed_done({ size: formatBytes(job.freed_bytes) }),
      );
      /* Tiles left the disk -- and removing the last region deletes the
         archive outright, so "present" is a question again, not a fact. */
      client.invalidateQueries({ queryKey: ["basemap-present"] });
      client.removeQueries({
        queryKey: ["basemap-estimate"],
        type: "inactive",
      });
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
      client.removeQueries({
        queryKey: ["basemap-estimate"],
        type: "inactive",
      });
      client.invalidateQueries({ queryKey: ["basemap-estimate"] });
      client.invalidateQueries({ queryKey: ["basemap-present"] });
    } else if (job.state === "cancelled") {
      toastNote(m.map_download_cancelled());
      client.invalidateQueries({ queryKey: ["basemap-ledger"] });
      client.invalidateQueries({ queryKey: ["basemap-coverage"] });
      client.removeQueries({
        queryKey: ["basemap-estimate"],
        type: "inactive",
      });
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
          toastError(sayError(e));
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
  /* Asking for an address selects the square it names, as well as going
     there. The camera and the selection are set together rather than the
     selection waiting for the flight to land: the panel is then right from
     the moment the answer is known, and a user who interrupts the flight --
     by dragging, or by asking for somewhere else -- still has the square
     they asked about rather than whichever one they happened to leave.

     Selected through the same encode-and-select path a click uses, not from
     the address that was typed. A decoded point re-encodes to the address it
     came from under any key, so trusting the typed string would show the
     panel a cell nothing had confirmed; going through `selectAt` means the
     panel's square is derived exactly like every other square on the map. */
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !ready || !flyTo) return;
    goTo(map, [flyTo.lon, flyTo.lat], Math.max(map.getZoom(), 20));
    void selectAt(flyTo.lat, flyTo.lon);
  }, [flyTo, ready, selectAt]);

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
  const noteShown = blank && !downloadOpen;
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
      {
        /* Small, low-contrast, and transparent to the pointer: it is a
          keyboard aid, not a control. */
      }
      <div
        className="reticle pointer-events-none absolute top-1/2 left-1/2 z-2 size-4.5 -translate-x-1/2 -translate-y-1/2 border-2 border-[rgba(18,33,47,0.55)]"
        aria-hidden
      />
      {
        /* Search sits over the map rather than in the panel: it moves the
          map, and the panel is about the square already chosen. */
      }
      <div className="map-search absolute top-2.5 left-2.5 z-2 w-[min(22rem,calc(100%-5.5rem))]">
        <PlaceSearch
          center={() => {
            const c = mapRef.current?.getCenter();
            return c ? { lon: c.lng, lat: c.lat } : null;
          }}
          onPick={(lon, lat) => {
            const map = mapRef.current;
            if (!map) return;
            /* Close enough to read streets, not so close that a town
              centre fills the screen with one building. */
            goTo(map, [lon, lat], Math.max(map.getZoom(), 15));
          }}
          /* An address names one square, so this goes all the way in --
             requestFlyTo lands at zoom 20 where onPick stops at 15 -- and it
             selects that square, which a place pick does not: a town is a
             place to look at, an address is a square to be told about. */
          onPickAddress={(lon, lat) => requestFlyTo(lat, lon)}
        />
      </div>
      {
        /* One column, because these are not mutually exclusive: a view can
          be outside coverage AND too far out for the grid, and two notes
          pinned to the same corner would sit on top of each other. */
      }
      {
        /* Centred on the uncovered part of the map, not on the map, or a
          note drifts under the drawer as it widens. The container spans the
          map and only the notes inside it take the pointer, or it would
          swallow clicks meant for the map itself. */
      }
      <div
        className="map-notes pointer-events-none absolute bottom-7 left-[calc((100%-var(--panel-offset,340px))/2)] flex w-max max-w-[80%] -translate-x-1/2 flex-col-reverse items-center gap-2"
        ref={notesRef}
      >
        {
          /* Hidden while the card is open: the note's whole purpose is to
            open that card, and leaving it on top of the thing it just
            opened puts a pill over the controls and wins the hit test. */
        }
        {blank && !downloadOpen && (
          <div className={`${NOTE} ${NOTE_ACTION}`} role="status">
            {
              /* One message, because there is only one fact the app can
                state honestly here: the detail is not downloaded. What the
                floor actually draws underneath ranges from a full country
                map to a single stretched polygon, and which of those you
                are looking at depends on how far past the floor's own depth
                the camera has gone -- so a note promising "this is the
                wider map" is a promise the app cannot keep, and one saying
                "no map here" contradicts a map the user can see. Saying
                neither is the only thing true in both. */
            }
            <span>{m.map_coverage_gap()}</span>
            <button
              type="button"
              className="note-action btn pointer-events-auto px-3.5 text-sm"
              onClick={() =>
                openDownload()}
            >
              {m.map_coverage_download()}
            </button>
          </div>
        )}
        {zoom < GRID_MIN_ZOOM && (
          <div className={NOTE} role="status">
            {m.map_zoom_for_grid()}
          </div>
        )}
        {truncated && (
          <div
            className={`${NOTE} warn border-notice-soft-line bg-notice-soft text-warn`}
            role="status"
          >
            {m.map_too_many_squares()}
          </div>
        )}
      </div>
    </div>
  );
}
