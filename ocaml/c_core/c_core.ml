(* The OCaml face of the KaRaMeL-emitted verified core.

   NOT the production path yet: the server still answers from the
   extracted-OCaml core with digestif injected, and keeps doing so until
   the side-by-side wall (ocaml/test/test_c_core.ml) has said
   byte-identical for long enough to retire it -- the roadmap's phase
   order. This module exists so the wall can drive both cores today and
   the server can switch by changing one call later.

   Signatures mirror the extracted core's conventions: absolute
   nanodegree Z coordinates in, the offset arithmetic confined here. *)

let lat_min = Z.of_string "-90000000000"
let lat_max = Z.of_string "90000000000"
let lon_min = Z.of_string "-180000000000"
let lon_max = Z.of_string "180000000000"

external init_ : int array -> unit = "caml_ccore_init"

external encode_ : string -> int -> int -> int * int * int * int
  = "caml_ccore_encode"

external decode_ : string -> int -> int -> int -> int -> int * int * int
  = "caml_ccore_decode"

external bounds_ : int -> int -> int * int * int * int = "caml_ccore_bounds"

(* The same 4097-entry table the extracted core reads, handed across the
   FFI once. Z.to_int is exact: every entry is below 2^36. *)
let initialised = ref false

(* Single-domain init: the C globals and this ref are unsynchronised.
   Fine for the wall and today's callers; the server-switch phase must
   initialise before forking domains. *)
let ensure_init () =
  if not !initialised then begin
    init_
      (Array.of_list (List.map Z.to_int Tessarium_Table_Data.cumcols_list));
    initialised := true
  end

let check_range lat lon =
  if Z.lt lat lat_min || Z.gt lat lat_max then
    invalid_arg (Printf.sprintf "latitude %s out of range" (Z.to_string lat));
  if Z.lt lon lon_min || Z.gt lon lon_max then
    invalid_arg (Printf.sprintf "longitude %s out of range" (Z.to_string lon))

let encode ~key ~lat ~lon =
  ensure_init ();
  check_range lat lon;
  let w1, w2, w3, n =
    encode_ key (Z.to_int (Z.sub lat lat_min)) (Z.to_int (Z.sub lon lon_min))
  in
  (Z.of_int w1, Z.of_int w2, Z.of_int w3, Z.of_int n)

(* Out-of-domain addresses (a word index >= 2048, n >= 10000) raise here
   where the extracted core would compute over unbounded nats; every call
   site sits behind address_of_string, which cannot produce them. Noted
   so "switch by changing one call" stays honest about the edge. *)
let decode ~key (w1, w2, w3, n) =
  ensure_init ();
  let flag, dlat, dlon =
    decode_ key (Z.to_int w1) (Z.to_int w2) (Z.to_int w3) (Z.to_int n)
  in
  if flag = 0 then None
  else Some (Z.add lat_min (Z.of_int dlat), Z.add lon_min (Z.of_int dlon))

let bounds_of_point ~lat ~lon =
  ensure_init ();
  check_range lat lon;
  (* (lat_lo, lat_hi, lon_lo, lon_hi), as offsets; same order as
     Tessarium_Api.bounds_of_point once the corner is added back. *)
  let la_lo, la_hi, lo_lo, lo_hi =
    bounds_ (Z.to_int (Z.sub lat lat_min)) (Z.to_int (Z.sub lon lon_min))
  in
  ( Z.add lat_min (Z.of_int la_lo),
    Z.add lat_min (Z.of_int la_hi),
    Z.add lon_min (Z.of_int lo_lo),
    Z.add lon_min (Z.of_int lo_hi) )
