/* The map, the grid overlay, and the click that turns a square into words. */

import { useEffect, useRef, useState, useCallback } from "react";
import maplibregl from "maplibre-gl";
import { Protocol } from "pmtiles";
import { layers, namedFlavor } from "@protomaps/basemaps";
import { type Core, type Grid, cellAt, cellContains } from "../core/client";
import "maplibre-gl/dist/maplibre-gl.css";

/* Below this the squares are smaller than a fingertip and the overlay is
   noise. A 3 m cell is about 5 px at z18 and 20 px at z20. */
const GRID_MIN_ZOOM = 18;
const LABEL_MIN_ZOOM = 20.5;

/* A ceiling on cells per viewport. Reached only when the viewport is unusually
   large for the zoom; truncation is drawn as a warning rather than silently
   producing a grid that stops halfway across the screen. */
const CELL_LIMIT = 12000;

export type Selection = {
  address: string;
  lat: number;
  lon: number;
  cell: { latLo: number; latHi: number; lonLo: number; lonHi: number };
};

type Props = {
  core: Core;
  selection: Selection | null;
  onSelect: (selection: Selection) => void;
  flyTo: { lat: number; lon: number; nonce: number } | null;
};

const emptyGeoJson = {
  type: "FeatureCollection" as const,
  features: [] as GeoJSON.Feature[],
};

const cellPolygon = (
  cell: { latLo: number; latHi: number; lonLo: number; lonHi: number },
  properties: GeoJSON.GeoJsonProperties,
): GeoJSON.Feature => ({
  type: "Feature",
  properties,
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

export function MapView({ core, selection, onSelect, flyTo }: Props) {
  const container = useRef<HTMLDivElement>(null);
  const map = useRef<maplibregl.Map | null>(null);
  const grid = useRef<Grid | null>(null);
  const [ready, setReady] = useState(false);
  const [truncated, setTruncated] = useState(false);
  const [zoom, setZoom] = useState(0);
  const [basemapFailed, setBasemapFailed] = useState(false);

  /* ------------------------------------------------------------- setup */
  useEffect(() => {
    if (!container.current || map.current) return;

    const protocol = new Protocol();
    maplibregl.addProtocol("pmtiles", protocol.tile);

    const style: maplibregl.StyleSpecification = {
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
          url: "pmtiles:///basemap/map.pmtiles",
          attribution:
            '<a href="https://protomaps.com">Protomaps</a> © <a href="https://openstreetmap.org">OpenStreetMap</a>',
        },
      },
      layers: layers("protomaps", namedFlavor("light"), { lang: "en" }),
    };

    const m = new maplibregl.Map({
      container: container.current,
      style,
      center: [-0.1278, 51.5074],
      zoom: 19,
      maxZoom: 23,
      hash: false,
      attributionControl: { compact: true },
    });
    map.current = m;

    m.addControl(new maplibregl.NavigationControl({ visualizePitch: false }));
    m.addControl(
      new maplibregl.GeolocateControl({
        positionOptions: { enableHighAccuracy: true },
        trackUserLocation: false,
      }),
    );
    m.addControl(new maplibregl.ScaleControl({ maxWidth: 120, unit: "metric" }));

    /* A missing basemap must not look like a broken application. The grid and
       the addressing still work over blank space, so say what is missing
       instead of showing an empty screen. */
    m.on("error", (e) => {
      const message = String(e.error?.message ?? "");
      if (message.includes("pmtiles") || message.includes("map.pmtiles")) {
        setBasemapFailed(true);
      }
    });

    m.on("load", () => {
      m.addSource("grid", { type: "geojson", data: emptyGeoJson });
      m.addSource("selection", { type: "geojson", data: emptyGeoJson });

      m.addLayer({
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

      m.addLayer({
        id: "grid-labels",
        type: "symbol",
        source: "grid",
        minzoom: LABEL_MIN_ZOOM,
        layout: {
          "text-field": ["get", "address"],
          "text-font": ["Noto Sans Regular"],
          "text-size": 10,
          "text-max-width": 6,
          "text-allow-overlap": false,
        },
        paint: {
          "text-color": "#123",
          "text-halo-color": "rgba(255,255,255,0.85)",
          "text-halo-width": 1.2,
        },
      });

      m.addLayer({
        id: "selection-fill",
        type: "fill",
        source: "selection",
        paint: { "fill-color": "#e8452c", "fill-opacity": 0.35 },
      });
      m.addLayer({
        id: "selection-outline",
        type: "line",
        source: "selection",
        paint: { "line-color": "#e8452c", "line-width": 2 },
      });

      setZoom(m.getZoom());
      setReady(true);
    });

    return () => {
      m.remove();
      map.current = null;
      maplibregl.removeProtocol("pmtiles");
    };
  }, []);

  /* -------------------------------------------------------- grid refresh */
  const refreshGrid = useCallback(async () => {
    const m = map.current;
    if (!m) return;
    setZoom(m.getZoom());

    if (m.getZoom() < GRID_MIN_ZOOM) {
      grid.current = null;
      setTruncated(false);
      (m.getSource("grid") as maplibregl.GeoJSONSource | undefined)?.setData(
        emptyGeoJson,
      );
      return;
    }

    const b = m.getBounds();
    const bounds = {
      latLo: b.getSouth(),
      lonLo: b.getWest(),
      latHi: b.getNorth(),
      lonHi: b.getEast(),
    };

    /* Addresses come back with the geometry when the labels will be drawn,
       and are skipped when they will not -- encoding every cell in view costs
       ten HMACs each and there is no point paying it to render nothing. */
    const wantLabels = m.getZoom() >= LABEL_MIN_ZOOM;
    /* A refresh in flight when the user locks resolves against a worker with
       no key. That is expected, not an error worth surfacing. */
    const g = await (wantLabels
      ? core.gridWithAddresses(bounds, CELL_LIMIT)
      : core.grid(bounds, CELL_LIMIT)
    ).catch(() => null);
    if (!g) return;

    grid.current = g;
    setTruncated(g.truncated);

    const features: GeoJSON.Feature[] = new Array(g.count);
    for (let i = 0; i < g.count; i++) {
      features[i] = cellPolygon(
        cellAt(g, i),
        g.addresses ? { address: g.addresses[i] } : {},
      );
    }
    (m.getSource("grid") as maplibregl.GeoJSONSource | undefined)?.setData({
      type: "FeatureCollection",
      features,
    });
  }, [core]);

  useEffect(() => {
    const m = map.current;
    if (!m || !ready) return;
    m.on("moveend", refreshGrid);
    m.on("zoomend", refreshGrid);
    void refreshGrid();
    return () => {
      m.off("moveend", refreshGrid);
      m.off("zoomend", refreshGrid);
    };
  }, [ready, refreshGrid]);

  /* -------------------------------------------------------------- click */
  useEffect(() => {
    const m = map.current;
    if (!m || !ready) return;

    const onClick = async (e: maplibregl.MapMouseEvent) => {
      const { lat, lng } = e.lngLat;

      /* Prefer the cell already in the overlay: it carries the address the
         user can see, so the panel and the map cannot disagree. */
      const g = grid.current;
      if (g?.addresses) {
        for (let i = 0; i < g.count; i++) {
          const cell = cellAt(g, i);
          if (cellContains(cell, lat, lng)) {
            onSelect({ address: g.addresses[i]!, lat, lon: lng, cell });
            return;
          }
        }
      }

      /* Otherwise ask the core directly. A degenerate bounding box returns
         exactly the cell containing the point, computed the same way as every
         other cell rather than by rounding here. */
      const [{ address }, exact] = await Promise.all([
        core.encode(lat, lng),
        core.grid({ latLo: lat, lonLo: lng, latHi: lat, lonHi: lng }, 1),
      ]);
      if (exact.count > 0) {
        onSelect({ address, lat, lon: lng, cell: cellAt(exact, 0) });
      }
    };

    m.on("click", onClick);
    return () => {
      m.off("click", onClick);
    };
  }, [ready, core, onSelect]);

  /* Cursor feedback, so the map reads as clickable. */
  useEffect(() => {
    const m = map.current;
    if (!m || !ready) return;
    m.getCanvas().style.cursor = "crosshair";
  }, [ready]);

  /* ---------------------------------------------------- selection drawing */
  useEffect(() => {
    const m = map.current;
    if (!m || !ready) return;
    const source = m.getSource("selection") as
      | maplibregl.GeoJSONSource
      | undefined;
    if (!source) return;
    source.setData(
      selection
        ? {
            type: "FeatureCollection",
            features: [cellPolygon(selection.cell, {})],
          }
        : emptyGeoJson,
    );
  }, [selection, ready]);

  /* ------------------------------------------------------------- fly to */
  useEffect(() => {
    const m = map.current;
    if (!m || !ready || !flyTo) return;
    m.flyTo({
      center: [flyTo.lon, flyTo.lat],
      zoom: Math.max(m.getZoom(), 20),
      duration: 1200,
    });
  }, [flyTo, ready]);

  return (
    <div className="map-wrap">
      <div ref={container} className="map" />
      {zoom < GRID_MIN_ZOOM && (
        <div className="map-note">Zoom in to see the grid</div>
      )}
      {truncated && (
        <div className="map-note warn">
          Too many squares in view to draw them all — zoom in
        </div>
      )}
      {basemapFailed && (
        <div className="map-note warn">
          No basemap found at <code>/basemap/map.pmtiles</code>. Addressing
          still works; run <code>tools/fetch-basemap.sh</code> to get tiles.
        </div>
      )}
    </div>
  );
}
