open Prims
type cell = Prims.nat
let row_of (lat : Tessarium_Spec.lat_ns) : Prims.nat=
  if lat = (Tessarium_Spec.lat_min + Tessarium_Spec.lat_span)
  then Tessarium_Table.rows - Prims.int_one
  else
    Tessarium_Spec.bucket lat Tessarium_Spec.lat_min Tessarium_Spec.lat_span
      Tessarium_Table.rows
let lon_fold (lon : Tessarium_Spec.lon_ns) : Prims.int=
  if lon = (Tessarium_Spec.lon_min + Tessarium_Spec.lon_span)
  then Tessarium_Spec.lon_min
  else lon
let col_of (lon : Tessarium_Spec.lon_ns) (k : Prims.pos) : Prims.nat=
  let v = lon_fold lon in
  Tessarium_Spec.bucket v Tessarium_Spec.lon_min Tessarium_Spec.lon_span k
let band_of_row (r : Prims.nat) : Prims.nat=
  r / Tessarium_Table.rows_per_band
let row_in_band (r : Prims.nat) : Prims.nat=
  let b = band_of_row r in r - (b * Tessarium_Table.rows_per_band)
let point_to_cell (lat : Tessarium_Spec.lat_ns) (lon : Tessarium_Spec.lon_ns)
  : cell=
  let r = row_of lat in
  let b = band_of_row r in
  let k = Tessarium_Table.col_counts b in
  let i = row_in_band r in
  let c = col_of lon k in ((Tessarium_Table.offsets b) + (i * k)) + c
let rec band_search (lo : Prims.nat) (hi : Prims.nat) (index : Prims.nat) :
  Prims.nat=
  if lo = hi
  then lo
  else
    (let mid = ((lo + hi) + Prims.int_one) / (Prims.of_int 2) in
     if (Tessarium_Table.offsets mid) <= index
     then band_search mid hi index
     else band_search lo (mid - Prims.int_one) index)
let band_of_cell (index : cell) : Prims.nat=
  band_search Prims.int_zero (Tessarium_Table.bands - Prims.int_one) index
let decompose (index : cell) :
  (Prims.nat, Prims.nat, Prims.nat) FStar_Pervasives.dtuple3=
  let b = band_of_cell index in
  let k = Tessarium_Table.col_counts b in
  let rem = index - (Tessarium_Table.offsets b) in
  let i = rem / k in
  let c = (mod) rem k in
  let r = (b * Tessarium_Table.rows_per_band) + i in
  FStar_Pervasives.Mkdtuple3 (r, b, c)
let cell_to_point (index : cell) :
  (Tessarium_Spec.lat_ns * Tessarium_Spec.lon_ns)=
  let uu___ = decompose index in
  match uu___ with
  | FStar_Pervasives.Mkdtuple3 (r, b, c) ->
      let k = Tessarium_Table.col_counts b in
      let lat =
        Tessarium_Spec.lat_min +
          (((((Prims.of_int 2) * r) + Prims.int_one) *
              Tessarium_Spec.lat_span)
             / ((Prims.of_int 2) * Tessarium_Table.rows)) in
      let lon =
        Tessarium_Spec.lon_min +
          (((((Prims.of_int 2) * c) + Prims.int_one) *
              Tessarium_Spec.lon_span)
             / ((Prims.of_int 2) * k)) in
      (lat, lon)
let cell_bounds (index : cell) :
  (Prims.int * Prims.int * Prims.int * Prims.int)=
  let uu___ = decompose index in
  match uu___ with
  | FStar_Pervasives.Mkdtuple3 (r, b, c) ->
      let k = Tessarium_Table.col_counts b in
      ((Tessarium_Spec.edge r Tessarium_Spec.lat_min Tessarium_Spec.lat_span
          Tessarium_Table.rows),
        (Tessarium_Spec.edge (r + Prims.int_one) Tessarium_Spec.lat_min
           Tessarium_Spec.lat_span Tessarium_Table.rows),
        (Tessarium_Spec.edge c Tessarium_Spec.lon_min Tessarium_Spec.lon_span
           k),
        (Tessarium_Spec.edge (c + Prims.int_one) Tessarium_Spec.lon_min
           Tessarium_Spec.lon_span k))
