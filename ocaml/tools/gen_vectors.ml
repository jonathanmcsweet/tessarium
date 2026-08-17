(* Generate vectors/vectors.json from vectors/inputs.json, using the verified
   core.

   This is what makes the F* the source of truth. The vectors used to be
   produced by the Python reference, which meant every implementation checked
   against it -- including the extracted core -- was ultimately being checked
   against a hand-written Python script. That inverted the trust ordering the
   whole architecture exists to establish.

   The split is deliberate: `inputs.json` holds the questions and is committed,
   `vectors.json` holds the answers and is generated. Which points to test is
   arbitrary and worth keeping stable; what the answers are is the thing under
   test.

   Run with --check to compare against the committed file without writing,
   which is how CI notices the extracted core drifting away from its vectors. *)

(* Paths are overridable so dune can run --check inside its sandbox, where
   nothing sits where the source tree says it does. *)
let positional =
  Array.to_list Sys.argv |> List.tl |> List.filter (fun a -> a <> "--check")

let nth_or n default = match List.nth_opt positional n with Some p -> p | None -> default
let inputs_path = nth_or 0 "vectors/inputs.json"
let vectors_path = nth_or 1 "vectors/vectors.json"

let member k = function
  | `Assoc l -> ( match List.assoc_opt k l with Some v -> v | None -> failwith ("missing " ^ k))
  | _ -> failwith "expected an object"

let to_str = function `String s -> s | _ -> failwith "expected a string"
let to_list = function `List l -> l | _ -> failwith "expected a list"

let to_int = function
  | `Int i -> i
  | `Intlit s -> int_of_string s
  | _ -> failwith "expected an integer"

let unhex h =
  String.init (String.length h / 2) (fun i ->
      Char.chr (int_of_string ("0x" ^ String.sub h (2 * i) 2)))

let hex s =
  String.concat ""
    (List.init (String.length s) (fun i -> Printf.sprintf "%02x" (Char.code s.[i])))

let generate inputs =
  let mnemonics =
    List.map
      (fun m ->
        ( to_str (member "name" m),
          to_str (member "mnemonic" m),
          match member "passphrase" m with `String p -> p | _ -> "" ))
      (to_list (member "mnemonics" inputs))
  in
  let feistel_key = unhex (to_str (member "feistel_key" inputs)) in
  let feistel_x = List.map to_int (to_list (member "feistel_x" inputs)) in
  let points =
    List.map
      (fun p -> (to_int (member "lat_ns" p), to_int (member "lon_ns" p)))
      (to_list (member "points" inputs))
  in
  let address_mnemonic = to_str (member "address_mnemonic" inputs) in
  let address_points = to_int (member "address_points" inputs) in

  let keys =
    List.map
      (fun (name, m, passphrase) ->
        (name, Tessarium.derive_key ~mnemonic:m ~passphrase))
      mnemonics
  in

  let key_derivation =
    List.map2
      (fun (name, mnemonic, passphrase) (_, key) ->
        `Assoc
          [
            ("name", `String name);
            ("mnemonic", `String mnemonic);
            ("passphrase", `String passphrase);
            ("key", `String (hex key));
          ])
      mnemonics keys
  in

  (* The Feistel vectors use a fixed key rather than a derived one, so they
     exercise the permutation independently of key derivation. *)
  let feistel_vectors =
    List.map
      (fun x ->
        let y =
          Tessarium_Feistel.encrypt Tessarium.round_fn feistel_key
            Tessarium.grid_version (Z.of_int x)
        in
        `Assoc [ ("x", `Int x); ("y", `Int (Z.to_int y)) ])
      feistel_x
  in

  let grid_vectors =
    List.map
      (fun (lat, lon) ->
        let cell = Tessarium_Grid.point_to_cell (Z.of_int lat) (Z.of_int lon) in
        let clat, clon = Tessarium_Grid.cell_to_point cell in
        `Assoc
          [
            ("lat_ns", `Int lat);
            ("lon_ns", `Int lon);
            ("cell", `Int (Z.to_int cell));
            ("centre_lat_ns", `Int (Z.to_int clat));
            ("centre_lon_ns", `Int (Z.to_int clon));
          ])
      points
  in

  let addr_key = List.assoc address_mnemonic keys in
  let addresses =
    List.filteri (fun i _ -> i < address_points) points
    |> List.map (fun (lat, lon) ->
           `Assoc
             [
               ("mnemonic", `String address_mnemonic);
               ("lat_ns", `Int lat);
               ("lon_ns", `Int lon);
               ( "address",
                 `String (Tessarium.encode ~key:addr_key ~lat_ns:lat ~lon_ns:lon) );
             ])
  in

  (* Addresses that name no location. The address space is larger than the
     number of cells, so about 35% of word combinations decode to nothing --
     which ones is decided entirely by the permutation, and changes completely
     whenever the grid version does.

     Generated rather than written down for exactly that reason. A hand-picked
     example quietly becomes a valid address at the next grid change, and the
     test asserting that it is refused goes on passing until it doesn't. That
     happened: `zoo.zoo.zoo.9999` was invalid under grid 1 and is valid under
     grid 2. *)
  let invalid_addresses =
    let wanted = 4 in
    let rec search i found =
      if List.length found >= wanted then List.rev found
      else if i > 100_000 then
        failwith "no invalid addresses found -- the address space is suspiciously full"
      else
        let addr =
          Tessarium.address_to_string
            ( Z.of_int (i mod 2048),
              Z.of_int (i * 7 mod 2048),
              Z.of_int (i * 13 mod 2048),
              Z.of_int (i * 3 mod 10000) )
        in
        match Tessarium.decode ~key:addr_key addr with
        | Error _ -> search (i + 1) (addr :: found)
        | Ok _ -> search (i + 1) found
    in
    search 1 []
  in

  `Assoc
    [
      ("grid_version", `String Tessarium.grid_version);
      ("total_cells", `Int (Z.to_int Tessarium.total_cells));
      ("address_space", `Int (Z.to_int Tessarium.address_space));
      ( "feistel",
        `Assoc
          [
            ("a", `Int (Z.to_int Tessarium_Spec.fe_a));
            ("b", `Int (Z.to_int Tessarium_Spec.fe_b));
            ("rounds", `Int (Z.to_int Tessarium_Feistel.rounds));
          ] );
      ("key_derivation", `List key_derivation);
      ("feistel_vectors", `List feistel_vectors);
      ("grid_vectors", `List grid_vectors);
      ("addresses", `List addresses);
      ("invalid_addresses", `List (List.map (fun a -> `String a) invalid_addresses));
    ]

(* Compared as parsed values rather than as text: the committed file was
   written by Python's json module and this one by Yojson, so they differ in
   whitespace and agree in every way that matters. *)
let rec equal a b =
  match (a, b) with
  | `Assoc x, `Assoc y ->
      List.length x = List.length y
      && List.for_all
           (fun (k, v) -> match List.assoc_opt k y with Some w -> equal v w | None -> false)
           x
  | `List x, `List y -> List.length x = List.length y && List.for_all2 equal x y
  | (`Int _ | `Intlit _), (`Int _ | `Intlit _) -> to_int a = to_int b
  | _ -> a = b

(* Pretty-printed: this file is read by people diffing a grid change, and a
   single line of 47 points is not reviewable. *)
let write path json =
  let out = open_out path in
  output_string out (Yojson.Safe.pretty_to_string ~std:true json);
  output_char out '\n';
  close_out out

let () =
  let check_only = Array.exists (String.equal "--check") Sys.argv in
  let inputs = Yojson.Safe.from_file inputs_path in
  let generated = generate inputs in
  let committed =
    try Some (Yojson.Safe.from_file vectors_path) with _ -> None
  in
  match committed with
  | Some c when equal c generated ->
      print_endline "vectors reproduce exactly from the verified core";
      if not check_only then
        write vectors_path generated
  | Some _ when check_only ->
      prerr_endline
        "the verified core no longer reproduces vectors/vectors.json.\n\
         Either the core changed behaviour, or the vectors were edited by hand.";
      exit 1
  | Some _ ->
      write vectors_path generated;
      print_endline
        "vectors DIFFER from the committed file and have been rewritten. \
         Inspect the diff before committing -- every address anyone has \
         written down under this grid has just changed."
  | None ->
      write vectors_path generated;
      print_endline "wrote fresh vectors"
