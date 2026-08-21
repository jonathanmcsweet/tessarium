(* Emit a large corpus of (point, cell, centre, address) for an independent
   implementation to check.

   This exists because the extraction pipeline is trusted rather than verified.
   The F* is proved, but nothing proves the OCaml that came out of it says the
   same thing, and the 47 committed vectors are a thin bridge across that gap.
   An independently written implementation disagreeing is the only signal
   available, so it is worth giving it a lot to disagree about.

   The corpus is deliberately unbalanced towards band seams. Uniformly random
   points essentially never land on one -- there are 4096 seams in 1.8e11
   nanodegrees of latitude -- and seams are exactly where two bands could both
   claim a point or leave a gap. That is the failure `theorem_injective` rules
   out in the F*, and the case where an extraction bug would be least visible. *)

let usage () =
  prerr_endline
    "usage: differential [--count N] [--seed S] [--mnemonic WORDS] \
     [--passphrase P] [--bench] [--out FILE]";
  exit 2

(* The historical default. Kept stable so an old corpus and a new one with no
   flags mean the same thing. *)
let default_mnemonic =
  "abandon abandon abandon abandon abandon abandon abandon abandon abandon \
   abandon abandon abandon abandon abandon abandon abandon abandon abandon \
   abandon abandon abandon abandon abandon art"

let () =
  let count = ref 100_000 and seed = ref 20260817 in
  let bench = ref false and out = ref "-" in
  (* One key exercises one permutation. A sweep worth trusting varies the
     key too -- that is what drags the KDF and the Feistel schedule into the
     differential, not just the grid. *)
  let mnemonic = ref default_mnemonic and passphrase = ref "" in
  let rec parse = function
    | [] -> ()
    | "--count" :: v :: r -> count := int_of_string v; parse r
    | "--seed" :: v :: r -> seed := int_of_string v; parse r
    | "--mnemonic" :: v :: r -> mnemonic := v; parse r
    | "--passphrase" :: v :: r -> passphrase := v; parse r
    | "--out" :: v :: r -> out := v; parse r
    | "--bench" :: r -> bench := true; parse r
    | _ -> usage ()
  in
  parse (List.tl (Array.to_list Sys.argv));

  (* The extracted core on purpose: this corpus is what the independent
     JS implementation and the wasm build are checked AGAINST, so it must
     come from the leg those two do not share. *)
  let core = Tessarium.extracted_core in

  let key =
    Tessarium.derive_key ~kdf:Tessarium_argon2.kdf ~mnemonic:!mnemonic
      ~passphrase:!passphrase
  in

  let lat_min = Z.of_string "-90000000000" in
  let lon_min = Z.of_string "-180000000000" in
  let lat_span = Z.of_string "180000000000" in
  let lon_span = Z.of_string "360000000000" in
  let rows = Tessarium_Table.rows in
  let rows_per_band = Tessarium_Table.rows_per_band in
  let bands = Tessarium_Table.bands in

  (* The lowest latitude in row r. Taken from the extracted spec rather than
     recomputed here, so a bug in `edge` cannot be hidden by this file
     independently reproducing it. *)
  let row_edge r = Tessarium_Spec.edge r lat_min lat_span rows in

  let rnd = Random.State.make [| !seed |] in
  let rand_z bound = Z.of_int64 (Random.State.int64 rnd (Z.to_int64 bound)) in

  let points = ref [] in
  let add lat lon = points := (lat, lon) :: !points in

  (* Every band seam, straddled. Row b*rows_per_band is the first row of band
     b, so its lower edge is the seam; one nanodegree below it belongs to the
     previous band. *)
  let seams = ref 0 in
  for b = 0 to Z.to_int bands - 1 do
    let r = Z.mul (Z.of_int b) rows_per_band in
    let e = row_edge r in
    List.iter
      (fun lat ->
        if Z.geq lat lat_min && Z.leq lat (Z.add lat_min lat_span) then begin
          add lat (rand_z lon_span |> Z.add lon_min);
          incr seams
        end)
      [ Z.sub e Z.one; e; Z.add e Z.one ]
  done;

  (* Poles, antimeridian, equator, prime meridian, and the exact corners --
     every value the clamping and folding branches single out. *)
  let edges =
    [
      (lat_min, lon_min);
      (lat_min, Z.add lon_min lon_span);
      (Z.add lat_min lat_span, lon_min);
      (Z.add lat_min lat_span, Z.add lon_min lon_span);
      (Z.zero, Z.zero);
      (Z.zero, lon_min);
      (Z.zero, Z.add lon_min lon_span);
      (Z.add lat_min lat_span, Z.zero);
      (lat_min, Z.zero);
      (Z.one, Z.minus_one);
      (Z.minus_one, Z.one);
    ]
  in
  List.iter (fun (a, b) -> add a b) edges;

  for _ = 1 to !count do
    add (Z.add lat_min (rand_z lat_span)) (Z.add lon_min (rand_z lon_span))
  done;

  let points = List.rev !points in
  let total = List.length points in

  if !bench then begin
    (* Timed separately from the corpus write, which is dominated by IO. *)
    let sample = List.filteri (fun i _ -> i < 20000) points in
    let n = List.length sample in
    let t0 = Unix.gettimeofday () in
    let addrs =
      List.map (fun (lat, lon) -> Tessarium.encode_z ~core ~key ~lat ~lon) sample
    in
    let t1 = Unix.gettimeofday () in
    List.iter
      (fun a -> ignore (Tessarium.decode ~core ~key a))
      addrs;
    let t2 = Unix.gettimeofday () in
    Printf.eprintf "encode %.2f us/op   decode %.2f us/op   (%d ops each)\n%!"
      ((t1 -. t0) *. 1e6 /. float_of_int n)
      ((t2 -. t1) *. 1e6 /. float_of_int n)
      n
  end;

  let oc = if !out = "-" then stdout else open_out !out in
  Printf.fprintf oc "# tessarium differential corpus\n";
  Printf.fprintf oc "# mnemonic: %s\n" !mnemonic;
  if !passphrase <> "" then
    Printf.fprintf oc "# passphrase: %s\n" !passphrase;
  (* The derived key, so a consumer whose contract starts AT the key (the
     wasm core wall) can skip the KDF; the independent JS implementation
     keeps deriving it from the mnemonic on its own. Test corpus only --
     the mnemonic above is already public. *)
  Printf.fprintf oc "# key: %s\n"
    (String.concat ""
       (List.map (fun c -> Printf.sprintf "%02x" (Char.code c))
          (List.init (String.length key) (String.get key))));
  Printf.fprintf oc "# seed %d, %d points (%d at band seams)\n" !seed total !seams;
  Printf.fprintf oc "# lat_ns lon_ns cell centre_lat_ns centre_lon_ns address\n";
  (* The proved theorems, restated as runtime assertions over the whole
     corpus. The F* proves them about the source and fstar/check replays
     the extraction on fixed points with a test round function; this is
     the third leg: the COMPOSED binary -- extracted core, zarith, the
     real keyed-BLAKE2s round function -- obeying the same laws on every corpus
     point. A binary that violates one here has a bug the other two legs
     sit upstream of: in the crypto injection, the linker, or the
     compiler's treatment of this exact composition. *)
  let violations = ref 0 in
  let law name ok lat lon =
    if not ok then begin
      incr violations;
      Printf.eprintf "LAW VIOLATED %s at lat=%s lon=%s\n" name
        (Z.to_string lat) (Z.to_string lon)
    end
  in
  List.iter
    (fun (lat, lon) ->
      let cell = Tessarium_Grid.point_to_cell lat lon in
      let clat, clon = Tessarium_Grid.cell_to_point cell in
      let address = Tessarium.encode_z ~core ~key ~lat ~lon in
      (* Each restated EXACTLY as its theorem is stated -- preconditions,
         longitude fold and all. Asserting one comparison more than the
         proof claims turns a correct binary into a false alarm: the
         first cut of this leg compared raw longitude where the theorem
         folds it, and flagged half the corpus. *)
      (* theorem_roundtrip: the cell's own centre names the same cell. *)
      law "roundtrip" (Tessarium_Grid.point_to_cell clat clon = cell)
        lat lon;
      (* theorem_containment: the point lies inside its cell's bounds --
         stated only for lat < lat_min + lat_span, and for the FOLDED
         longitude, so the antimeridian's two spellings name one cell. *)
      (* The precondition comes from the EXTRACTED Spec, not this file's
         local literals, for the same reason row_edge does above: this
         file must not be able to hide a Spec bug by reproducing it. *)
      (if
         Z.lt lat
           (Z.add Tessarium_Spec.lat_min Tessarium_Spec.lat_span)
       then begin
         let lat_lo, lat_hi, lon_lo, lon_hi =
           Tessarium_Grid.cell_bounds cell
         in
         let folded = Tessarium_Grid.lon_fold lon in
         law "containment"
           (Z.leq lat_lo lat && Z.lt lat lat_hi
           && Z.leq lon_lo folded && Z.lt folded lon_hi)
           lat lon
       end);
      (* theorem_decode_encode: decoding what was encoded never fails and
         answers with this exact cell's representative point. Slightly
         STRONGER than the theorem, deliberately: the theorem is stated
         on address tuples, and this round-trips through the address
         string -- so a formatter bug fails here too, mislabeled as a law
         violation, which is the safe direction. *)
      (match Tessarium.decode ~core ~key address with
      | Ok (dlat, dlon) ->
          law "decode-encode"
            (Z.equal (Z.of_int dlat) clat && Z.equal (Z.of_int dlon) clon)
            lat lon
      | Error _ -> law "decode-encode" false lat lon);
      Printf.fprintf oc "%s %s %s %s %s %s\n" (Z.to_string lat) (Z.to_string lon)
        (Z.to_string cell) (Z.to_string clat) (Z.to_string clon)
        address)
    points;
  if !violations > 0 then begin
    Printf.eprintf "%d proved laws violated at runtime\n" !violations;
    exit 1
  end;
  (* Said on success too, so tools/check-suites.sh can demand the line:
     a law leg that quietly stopped running must be distinguishable from
     one that ran and held. *)
  Printf.eprintf "proved laws hold at runtime over %d points\n" total;
  if !out <> "-" then close_out oc;
  Printf.eprintf "wrote %d points (%d straddling band seams)\n" total !seams
