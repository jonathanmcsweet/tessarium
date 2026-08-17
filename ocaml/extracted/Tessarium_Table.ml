open Prims
let rows : Prims.pos= Tessarium_Table_Data.rows
let bands : Prims.pos= Tessarium_Table_Data.bands
let rows_per_band : Prims.pos= Tessarium_Table_Data.rows_per_band
let total_cells : Prims.pos= Tessarium_Table_Data.total_cells
let max_col_count : Prims.pos= Tessarium_Table_Data.max_col_count
let grid_version : Prims.string= Tessarium_Table_Data.grid_version
let cum_arr : Prims.nat FStar_ImmutableArray_Base.t=
  FStar_ImmutableArray_Base.of_list Tessarium_Table_Data.cumcols_list
let cum (b : Prims.nat) : Prims.nat=
  FStar_ImmutableArray_Base.index cum_arr b
let col_counts (b : Prims.nat) : Prims.pos=
  (cum (b + Prims.int_one)) - (cum b)
let offsets (b : Prims.nat) : Prims.nat= (cum b) * rows_per_band
