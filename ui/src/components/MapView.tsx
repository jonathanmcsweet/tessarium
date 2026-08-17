/* The map, the grid overlay, and the click that turns a square into words. */

import { layers, namedFlavor } from "@protomaps/basemaps";
import { useQueryClient } from "@tanstack/react-query";
import { Download } from "lucide-react";
import maplibregl from "maplibre-gl";
import { Protocol } from "pmtiles";
import { useCallback, useEffect, useRef, useState } from "react";
import { toast } from "sonner";
import {
  type Job,
  type Region,
  useBasemapPresent,
  useBasemapStatus,
} from "../core/basemap";
import { fetchAddress, fetchGrid } from "../core/queries";
import { getLocale } from "../i18n";
import { m } from "../paraglide/messages";
import { useAppStore } from "../store";
import { DownloadCard } from "./DownloadCard";
import { IconButton } from "./IconButton";
import "maplibre-gl/dist/maplibre-gl.css";

/* Below this the squares are smaller than a fingertip and the overlay is
   noise. A 3 m cell is about 5 px at z18 and 20 px at z20. */
const GRID_MIN_ZOOM = 18;

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

/* The style, rebuilt whenever the archive on disk is replaced. The version
   number lands in the source URL as a query string -- the server strips it,
   but the pmtiles protocol caches per URL, and without a new URL it would
   keep reading the old archive's directories over the new bytes. */
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
      url: `pmtiles:///basemap/map.pmtiles?v=${version}`,
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
  map.addSource("grid", { type: "geojson", data: emptyGeoJson });
  map.addSource("selection", { type: "geojson", data: emptyGeoJson });

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
    paint: { "fill-color": "#e8452c", "fill-opacity": 0.35 },
  });
  map.addLayer({
    id: "selection-outline",
    type: "line",
    source: "selection",
    paint: { "line-color": "#e8452c", "line-width": 2 },
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

export function MapView() {
  const container = useRef<HTMLDivElement>(null);
  /* `mapRef`, not `m` -- `m` is the message namespace throughout the UI. */
  const mapRef = useRef<maplibregl.Map | null>(null);
  const [ready, setReady] = useState(false);
  const [truncated, setTruncated] = useState(false);
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

    const protocol = new Protocol();
    maplibregl.addProtocol("pmtiles", protocol.tile);

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
      maplibregl.removeProtocol("pmtiles");
    };
  }, []);

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

  /* -------------------------------------------------- offline downloads */

  /* Swap in the freshly downloaded archive without reloading the page -- a
     reload would drop the key and send the user back to the phrase gate. */
  const rebuildBasemap = useCallback(() => {
    const map = mapRef.current;
    if (!map) return;
    styleVersion.current += 1;
    map.setStyle(buildStyle(styleVersion.current));
    map.once("style.load", () => {
      addOverlay(map);
      setStyleEpoch((epoch) => epoch + 1);
    });
  }, []);

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
      clearBasemapFailed();
      closeDownload();
      rebuildBasemap();
    } else if (job.state === "failed") {
      toast.error(m.map_download_failed({ reason: job.reason }));
    } else if (job.state === "cancelled") {
      toast(m.map_download_cancelled());
      closeDownload();
    }
  }, [
    basemapJob.data,
    client,
    clearBasemapFailed,
    closeDownload,
    rebuildBasemap,
  ]);

  /* --------------------------------------------------------- selecting */
  const selectAt = useCallback(
    async (lat: number, lon: number) => {
      /* One square, one address, asked for only when the user asks. */
      const result = await fetchAddress(client, lat, lon).catch(
        (e: unknown) => {
          toast.error(e instanceof Error ? e.message : String(e));
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
        ? { type: "FeatureCollection", features: [cellPolygon(selection.cell)] }
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

  return (
    <div className="map-wrap">
      <div ref={container} className="map" />
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
  );
}
