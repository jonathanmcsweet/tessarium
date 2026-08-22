/* The map is a separate download, and this is the one place that asks for it.

   MapLibre and the basemap style are most of what this application ships, and
   none of it is reachable until a phrase has been accepted. Importing MapView
   statically put all of it in the entry chunk, so the phrase screen -- the
   only screen a visitor sees before deciding whether to use this at all --
   waited on the map engine before it could be typed into.

   Two callers, one download. `App` mounts it through `lazy()` once the gate
   opens; `PhraseEntry` starts it earlier, the moment a phrase passes its
   checksum. That earlier start is what keeps the split from costing anything
   a user can feel -- the key derivation it overlaps with is Argon2id over
   64 MB and takes far longer than this download. A visitor who never types a
   valid phrase never asks for it at all.

   Nothing here dedupes the two calls, because nothing needs to: `import()` of
   the same specifier returns the same promise from the module registry, in
   every browser and under Vite. What this function is for is keeping the
   specifier written once, so that the split stays one chunk rather than
   becoming two the next time something else wants the map. */

export const loadMapView = () => import("./MapView");
