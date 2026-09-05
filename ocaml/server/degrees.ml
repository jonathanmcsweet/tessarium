(* Degrees, and the integer ten-millionths of a degree a PMTiles header
   stores them in.

   Not the address path. The encode/decode core is integer nanodegrees from
   end to end and never sees a float; this is the tile-picking side, where a
   header's recorded bounds have to become the degrees a projection takes.

   It is here because the conversion was written out eleven times across
   three server modules -- nine of them in [Basemap_download] alone -- which
   is ten chances for a precision change to be applied nine times. A copy
   that lagged would shift a region's bounds by up to a tile, at exactly the
   seams [Tile_set.may_hold]'s slack exists to paper over.

   The other direction, degrees to e7, lives in [Pmtiles.Extract] and is
   shared from there by [Pmtiles.Build]. It cannot live here: the pmtiles
   library sits below this one, so a server module is invisible to it, and
   every caller of that direction is inside it. *)

let of_e7 (v : int) : float = float_of_int v /. 1e7
