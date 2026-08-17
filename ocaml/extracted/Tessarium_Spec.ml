open Prims
let words : Prims.pos= Prims.of_int 2048
let num_max : Prims.pos= Prims.of_int 10000
let addr_space : Prims.pos= ((words * words) * words) * num_max
let fe_a : Prims.pos= Prims.of_int 6553600
let fe_b : Prims.pos= Prims.of_int 13107200
let lat_min : Prims.int= Prims.parse_int "-90000000000"
let lat_span : Prims.pos= Prims.parse_int "180000000000"
let lon_min : Prims.int= Prims.parse_int "-180000000000"
let lon_span : Prims.pos= Prims.parse_int "360000000000"
type lat_ns = Prims.int
type lon_ns = Prims.int
let bucket (v : Prims.int) (v_min : Prims.int) (span : Prims.pos)
  (k : Prims.pos) : Prims.int= ((v - v_min) * k) / span
let edge (i : Prims.nat) (v_min : Prims.int) (span : Prims.pos)
  (k : Prims.pos) : Prims.int=
  v_min + ((((i * span) + k) - Prims.int_one) / k)
