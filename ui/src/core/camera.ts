import type { LngLatLike, Map as MapLibreMap } from "maplibre-gl";

/* MapLibre's own default. Named rather than omitted because the ceiling below
   is only meaningful next to the speed it is a ceiling on. */
export const FLY_SPEED = 1.2;

/* Beyond this the flight becomes an arrival. */
export const FLY_MAX_MS = 1200;

export function goTo(
  map: MapLibreMap,
  center: LngLatLike,
  zoom: number,
): void {
  map.flyTo({ center, zoom, speed: FLY_SPEED, maxDuration: FLY_MAX_MS });
}
