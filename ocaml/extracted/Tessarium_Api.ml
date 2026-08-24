open Prims
let encode (f : ('key, 'tweak) Tessarium_Feistel.round_fn) (k : 'key)
  (t : 'tweak) (lat : Tessarium_Spec.lat_ns) (lon : Tessarium_Spec.lon_ns) :
  Tessarium_Codec.address=
  Tessarium_Codec.to_address
    (Tessarium_Feistel.encrypt f k t (Tessarium_Grid.point_to_cell lat lon))
let decode (f : ('key, 'tweak) Tessarium_Feistel.round_fn) (k : 'key)
  (t : 'tweak) (a : Tessarium_Codec.address) :
  (Tessarium_Spec.lat_ns * Tessarium_Spec.lon_ns)
    FStar_Pervasives_Native.option=
  let i = Tessarium_Feistel.decrypt f k t (Tessarium_Codec.from_address a) in
  if i < Tessarium_Table.total_cells
  then FStar_Pervasives_Native.Some (Tessarium_Grid.cell_to_point i)
  else FStar_Pervasives_Native.None
let bounds_of_point (lat : Tessarium_Spec.lat_ns)
  (lon : Tessarium_Spec.lon_ns) :
  (Prims.int * Prims.int * Prims.int * Prims.int)=
  Tessarium_Grid.cell_bounds (Tessarium_Grid.point_to_cell lat lon)
