(* PMTiles headers store bounds as ten-millionths of a degree; this converts
   them back. Not the address path -- that is integer nanodegrees and never
   sees a float.

   A module because this one line was written out eleven times across three
   files, nine of them in [Basemap_download]: ten chances to change the
   rounding and miss one, shifting a region's bounds by up to a tile.

   The opposite direction is in [Pmtiles.Extract] and has to be -- that
   library is built first and cannot see this one. *)

let of_e7 (v : int) : float = float_of_int v /. 1e7
