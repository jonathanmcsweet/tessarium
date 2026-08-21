(* The OCaml face of the KaRaMeL-emitted verified core.

   THIS is the server's arithmetic: `serve.ml` injects [core] below, so
   every address the API answers with is computed by the C emitted from
   the F* proofs. The extracted-OCaml core has not gone anywhere -- it
   still generates the committed vectors, still feeds the evaluator leg,
   and still answers beside this one in test_c_core.ml's 15,549-check
   wall on every `make test` -- it simply no longer serves.

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

(* Single-domain init: the C globals and this ref are unsynchronised. The
   server calls [init] once at startup, before it serves anything, so a
   later move to multiple domains cannot race here; [ensure_init] stays
   for the tests and tools, which are single-threaded. *)
let ensure_init () =
  if not !initialised then begin
    init_
      (Array.of_list (List.map Z.to_int Tessarium_Table_Data.cumcols_list));
    initialised := true
  end

let init = ensure_init

(* A second range check, after the one in Tessarium.check_range that every
   injected call already passed. Kept because test_c_core.ml and any future
   direct caller reach these functions without that one, and because the
   emitted C's refinements are erased -- the boundary is the place to refuse.
   Deliberate duplication, not drift: if the two ever disagree the wall's
   corner cases fail. *)
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

(* The injected core, as Tessarium.core. The record is what serve.ml
   passes; the functions above are what the side-by-side wall drives. *)
let core : Tessarium.core =
  { Tessarium.encode; decode; bounds_of_point }
