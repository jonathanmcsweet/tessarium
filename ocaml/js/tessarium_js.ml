(* JavaScript bindings for the extracted core.

   The same OCaml that builds the server is compiled to JS here, so the browser
   and the server run one implementation rather than two.

   Nanodegrees never cross this boundary as an OCaml [int]. js_of_ocaml
   compiles OCaml's native int to a 32-bit JS integer, and longitude reaches
   1.8e11, so anything passed that way would silently wrap. Exact values cross
   as decimal strings and are parsed straight into Zarith; the degree helpers
   are convenience only and convert at the edge, which is the one place this
   design permits a float. *)

open Js_of_ocaml

let string_of_hex h =
  String.init (String.length h / 2) (fun i ->
      Char.chr (int_of_string ("0x" ^ String.sub h (2 * i) 2)))

(* The inverse, for handing the KDF inputs to the worker: hex survives the
   Js.string round trip byte-exactly, which raw OCaml strings do not. *)
let hex_of_string s =
  String.concat ""
    (List.init (String.length s) (fun i ->
         Printf.sprintf "%02x" (Char.code s.[i])))

let ns_of_deg (d : float) = Z.of_float (Float.round (d *. 1e9))
let deg_of_ns (z : Z.t) = Z.to_float z /. 1e9

(* The extracted core, compiled to JavaScript alongside this file. The
   browser's wasm build of the same F* is a separate phase; until it lands
   the bundle answers from here. *)
let core = Tessarium.extracted_core

let jstr = Js.string
let ostr = Js.to_string

let () =
  Js.export "tessarium"
    (object%js
       val gridVersion = jstr Tessarium.grid_version
       val totalCells = jstr (Z.to_string Tessarium_Table.total_cells)

       (* The browser derives keys with the Argon2id wasm module, not with
          this bundle -- but the KDF's two INPUTS are built here, by the
          same OCaml the server runs, so the NFKD and joining rules cannot
          drift between targets. The worker feeds the returned bytes to the
          wasm and gets the 32-byte key. Always an object: `error` is null
          on success, else the reason (invalid phrase, over-long
          passphrase) ready to display. *)
       val derivationVersion = jstr Tessarium.derivation_version

       method kdfInputs mnemonic passphrase =
         let inputs password salt error =
           object%js
             val password = jstr password
             val salt = jstr salt
             val error = error
           end
         in
         match Tessarium.validate_mnemonic (ostr mnemonic) with
         | Error e -> inputs "" "" (Js.Opt.return (jstr e))
         | Ok () -> (
             let mnemonic = ostr mnemonic and passphrase = ostr passphrase in
             match Tessarium.kdf_salt ~passphrase with
             | exception Tessarium.Bad_passphrase e ->
                 inputs "" "" (Js.Opt.return (jstr e))
             | salt ->
                 inputs
                   (hex_of_string (Tessarium.kdf_password ~mnemonic))
                   (hex_of_string salt) Js.Opt.empty)

       (* Entropy in, 24 words out. The caller supplies the bytes -- in the
          browser that is `crypto.getRandomValues` -- so the randomness stays
          where it can be seen rather than being buried in here. *)
       method mnemonicOfEntropy entropyHex =
         jstr (Tessarium.mnemonic_of_entropy (string_of_hex (ostr entropyHex)))

       val entropyBytes = Tessarium.entropy_bytes

       method validateMnemonic mnemonic =
         match Tessarium.validate_mnemonic (ostr mnemonic) with
         | Ok () -> Js.null
         | Error e -> Js.some (jstr e)

       (* Exact interface: nanodegrees as decimal strings. *)
       method encodeNs keyHex latNs lonNs =
         let key = string_of_hex (ostr keyHex) in
         let lat = Z.of_string (ostr latNs) and lon = Z.of_string (ostr lonNs) in
         jstr (Tessarium.encode_z ~core ~key ~lat ~lon)

       method decodeNs keyHex addr =
         let key = string_of_hex (ostr keyHex) in
         match
           Tessarium_Api.decode Tessarium.round_fn key Tessarium.tweak
             (Tessarium.address_of_string (ostr addr))
         with
         | None -> Js.null
         | Some (lat, lon) ->
             Js.some
               (object%js
                  val latNs = jstr (Z.to_string lat)
                  val lonNs = jstr (Z.to_string lon)
               end)

       (* Degree convenience wrappers for the map, which works in degrees. *)
       method encodeDeg keyHex lat lon =
         let key = string_of_hex (ostr keyHex) in
         jstr (Tessarium.encode_z ~core ~key ~lat:(ns_of_deg lat) ~lon:(ns_of_deg lon))

       method decodeDeg keyHex addr =
         let key = string_of_hex (ostr keyHex) in
         match
           Tessarium_Api.decode Tessarium.round_fn key Tessarium.tweak
             (Tessarium.address_of_string (ostr addr))
         with
         | None -> Js.null
         | Some (lat, lon) ->
             Js.some
               (object%js
                  val lat = deg_of_ns lat
                  val lon = deg_of_ns lon
               end)

       (* Corners of the cell containing a point, in degrees. This is what
          draws the grid overlay. *)
       method cellBoundsDeg lat lon =
         let a, b, c, d =
           Tessarium.cell_bounds_z ~core ~lat:(ns_of_deg lat) ~lon:(ns_of_deg lon)
         in
         object%js
           val latLo = deg_of_ns a
           val latHi = deg_of_ns b
           val lonLo = deg_of_ns c
           val lonHi = deg_of_ns d
         end

       (* Every cell overlapping a viewport, as a flat Float64Array of
          [latLo, latHi, lonLo, lonHi] quadruples.

          Flat and typed rather than an array of objects: a z20 viewport is a
          few thousand cells, and allocating four JS objects per cell to throw
          away on the next map movement is how a map loses its frame budget.

          The walk itself happens in the core, in integer nanodegrees. Stepping
          cell to cell in JavaScript would mean crossing cell boundaries in
          floating point, which is the one thing the integer grid exists to
          prevent. *)
       method gridForBounds latLo lonLo latHi lonHi limit =
         let cells, truncated =
           Tessarium.cells_in_bounds ~core ~lat_lo:(ns_of_deg latLo)
             ~lon_lo:(ns_of_deg lonLo) ~lat_hi:(ns_of_deg latHi)
             ~lon_hi:(ns_of_deg lonHi) ~limit
         in
         let n = List.length cells in
         let flat = new%js Typed_array.float64Array (n * 4) in
         List.iteri
           (fun i (a, b, c, d) ->
             let put k v = Typed_array.set flat ((i * 4) + k) (Js.number_of_float v) in
             put 0 (deg_of_ns a);
             put 1 (deg_of_ns b);
             put 2 (deg_of_ns c);
             put 3 (deg_of_ns d))
           cells;
         object%js
           val cells = flat
           val count = n
           val truncated = Js.bool truncated
         end
    end)
