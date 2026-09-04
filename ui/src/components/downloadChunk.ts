/* The offline-maps card is a separate download, and this is the one place
   that asks for it.

   It has to be, now that the card draws in the side panel rather than over
   the map. AddressPanel is in the entry chunk -- it is mounted the moment
   the gate opens -- so importing the card there statically put its ~290 KB
   (most of it the region catalogue) on the phrase screen, which is the one
   screen a visitor sees before deciding whether to use this at all. The
   end-to-end suite caught it: the gate went from under 200 KB to 292 KB.

   Same shape and same reason as mapChunk.ts, including keeping the
   specifier written once so the split stays one chunk. */

export const loadDownloadCard = () => import("./DownloadCard");
