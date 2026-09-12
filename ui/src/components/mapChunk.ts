/* The map is a separate download, and this is the one place that asks for it.

   MapLibre and the basemap style are most of what this application ships, and
   none of it is reachable until a phrase has been accepted. Importing MapView
   statically put all of it in the entry chunk, so the phrase screen -- the
   only screen a visitor sees before deciding whether to use this at all --
   waited on the map engine before it could be typed into.
*/

export const loadMapView = () => import("./MapView");
