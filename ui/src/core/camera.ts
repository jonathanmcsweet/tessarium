/* Where the camera goes when something asks for a place.

   Two call sites -- a place picked from the search index, a square named by
   an address -- and one rule between them, because the problem they share
   belongs to neither. `flyTo` flies: it arcs OUT to a zoom that fits the
   whole journey on screen and back in at the far end. From street zoom, any
   journey longer than the screen arcs through zoom levels the map holds no
   tiles for, so what the user watches is the background colour until the
   destination arrives. One city in Georgia to the next looks exactly like
   London to Atlanta, because in both the arc is over tiles nobody has.

   So: animate what fits on the screen, and go straight to what does not. A
   jump asks the network for the destination and nothing else -- a handful of
   tiles instead of every zoom level in between.

   The threshold is a time, not a distance, and MapLibre draws the line
   itself: `speed` gives it its own model of how long a flight takes, and past
   `maxDuration` it lands at once instead. That number used to be a fixed
   `duration: 1200` -- an instruction to cram the Atlantic into 1.2 seconds,
   which it obediently did. It is now a ceiling on how long we are willing to
   animate.

   Reduced motion needs nothing here: MapLibre honours the media query for
   any movement not marked `essential`, and a search result is not. */

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
