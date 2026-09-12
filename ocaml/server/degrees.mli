(** PMTiles bounds, which are stored as ten-millionths of a degree.

    Not the address path: that is integer nanodegrees and never sees a float.
    The opposite direction lives in {!Pmtiles.Extract}, which is built first
    and cannot see this module. *)

val of_e7 : int -> float
(** [of_e7 v] is [v] ten-millionths of a degree, as degrees. *)
