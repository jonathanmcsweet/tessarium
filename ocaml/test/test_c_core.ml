(* The side-by-side wall: the KaRaMeL-emitted C core against the
   extracted-OCaml core with digestif injected -- same keys, same points,
   every entry point. This is the "old and new run side by side until
   byte-identical" gate the roadmap set for retiring the extracted core,
   and it is what watches the FFI stubs' unproved plumbing (table copy,
   key packing, value conversions).

   Deterministic: corners plus Lehmer draws from a fixed seed. *)

module C_core = Tessarium_c_core.C_core

let lat_min = Z.of_string "-90000000000"
let lat_span = Z.of_string "180000000000"
let lon_min = Z.of_string "-180000000000"
let lon_span = Z.of_string "360000000000"

let lehmer = ref (Z.of_int 20260821)
let m61 = Z.sub (Z.shift_left Z.one 61) Z.one

let next bound =
  lehmer := Z.rem (Z.mul !lehmer (Z.of_string "381471956995469")) m61;
  Z.rem !lehmer bound

let keys =
  List.init 3 (fun v ->
      String.init 32 (fun j -> Char.chr (((v * 41) + (j * 7) + 3) land 0xff)))

(* Corners first (pole, both antimeridians, the domain corner, a band
   seam -- computed by the extracted Spec.edge, the same discipline as
   gen_check), then generated points. *)
let points =
  let seam =
    Tessarium_Spec.edge
      (Z.mul (Z.of_int 1337) Tessarium_Table.rows_per_band)
      lat_min lat_span Tessarium_Table.rows
  in
  [ (Z.add lat_min lat_span, Z.zero);
    (lat_min, Z.zero);
    (Z.zero, lon_min);
    (Z.zero, Z.add lon_min lon_span);
    (seam, Z.of_int 5_000_000);
    (Z.pred seam, Z.of_int 5_000_000);
    (Z.zero, Z.zero) ]
  @ List.init 2000 (fun _ ->
        (Z.add lat_min (next (Z.succ lat_span)),
         Z.add lon_min (next (Z.succ lon_span))))

let failures = ref 0
let checks = ref 0

let fail fmt =
  incr failures;
  Printf.eprintf fmt

let zs = Z.to_string

let () =
  let tweak = Tessarium.tweak in
  let rf = Tessarium.round_fn in
  (* encode + decode of the answer, both cores, every key x point *)
  List.iter
    (fun key ->
      List.iter
        (fun (lat, lon) ->
          incr checks;
          let (a1, a2, a3, an) as oaddr =
            Tessarium_Api.encode rf key tweak lat lon
          in
          let c1, c2, c3, cn = C_core.encode ~key ~lat ~lon in
          if not (Z.equal a1 c1 && Z.equal a2 c2 && Z.equal a3 c3 && Z.equal an cn)
          then
            fail "encode disagrees at %s %s under key %d\n" (zs lat) (zs lon)
              (Char.code key.[0]);
          incr checks;
          let od = Tessarium_Api.decode rf key tweak oaddr in
          let cd = C_core.decode ~key oaddr in
          (match (od, cd) with
          | FStar_Pervasives_Native.Some (ola, olo), Some (cla, clo)
            when Z.equal ola cla && Z.equal olo clo -> ()
          | _ ->
              fail "decode of own address disagrees at %s %s\n" (zs lat)
                (zs lon)))
        points)
    keys;
  (* scanned addresses: agreement on Some AND None, both cores. Both
     outcomes must actually occur -- a corpus drift that starved either
     branch would leave the flag=0 path (or the happy path) untested
     while staying green. *)
  let somes = ref 0 and nones = ref 0 in
  List.iter
    (fun key ->
      for _ = 1 to 500 do
        incr checks;
        let addr =
          Tessarium_Codec.to_address (next Tessarium_Spec.addr_space)
        in
        let od = Tessarium_Api.decode rf key tweak addr in
        let cd = C_core.decode ~key addr in
        match (od, cd) with
        | FStar_Pervasives_Native.None, None -> incr nones
        | FStar_Pervasives_Native.Some (ola, olo), Some (cla, clo)
          when Z.equal ola cla && Z.equal olo clo -> incr somes
        | _ ->
            let w1, w2, w3, n = addr in
            fail "decode disagrees on %s.%s.%s.%s\n" (zs w1) (zs w2) (zs w3)
              (zs n)
      done)
    keys;
  if !somes = 0 || !nones = 0 then
    fail "the scan corpus starved a branch: %d resolved, %d rejected\n" !somes
      !nones;
  (* bounds: key-independent, one pass *)
  List.iter
    (fun (lat, lon) ->
      incr checks;
      (* both return (lat_lo, lat_hi, lon_lo, lon_hi) *)
      let ola_lo, ola_hi, olo_lo, olo_hi =
        Tessarium_Api.bounds_of_point lat lon
      in
      let cla_lo, cla_hi, clo_lo, clo_hi = C_core.bounds_of_point ~lat ~lon in
      if not
           (Z.equal ola_lo cla_lo && Z.equal ola_hi cla_hi
           && Z.equal olo_lo clo_lo && Z.equal olo_hi clo_hi)
      then fail "bounds disagree at %s %s\n" (zs lat) (zs lon))
    points;
  if !failures > 0 then begin
    Printf.eprintf "%d of %d side-by-side checks failed\n" !failures !checks;
    exit 1
  end;
  Printf.printf
    "the C core and the extracted core agree on %d side-by-side checks (%d keys, %d points, %d scanned addresses)\n"
    !checks (List.length keys) (List.length points) 1500
