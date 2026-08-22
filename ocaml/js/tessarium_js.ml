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

(* The extracted core, compiled to JavaScript alongside this file.

   It is no longer what the app computes with. Since the browser half of the
   switch landed, the worker's encode, decode and grid answer from
   wasm/core.wasm -- the same F* by way of KaRaMeL and zig -- and this bundle
   supplies what that module cannot: the wordlist codec both ways, BIP-39
   validation and generation, the KDF's inputs, and the band table itself.
   [core] therefore backs only the exports below that the vector suite still
   drives (ocaml/js/test/test_vectors.cjs). Nothing a user does reaches it. *)
let core = Tessarium.extracted_core

let jstr = Js.string
let ostr = Js.to_string

(* A refusal crossing to JavaScript keeps its code, so the browser can say the
   same thing in six languages. The English sentence travels with it and is
   what the worker falls back to for anything the catalogue has no entry for;
   see ui/src/core/refusal.ts. *)
let jrefusal (r : Tessarium.refusal) =
  object%js
    val code = jstr r.Tessarium.code
    val arg = jstr r.Tessarium.arg
    val message = jstr r.Tessarium.message
  end

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
         | Error e -> inputs "" "" (Js.Opt.return (jrefusal e))
         | Ok () -> (
             let mnemonic = ostr mnemonic and passphrase = ostr passphrase in
             match Tessarium.kdf_salt ~passphrase with
             | exception Tessarium.Bad_passphrase e ->
                 inputs "" "" (Js.Opt.return (jrefusal e))
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
         | Error e -> Js.some (jrefusal e)

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

       (* ------------------------------------------- the degree wrappers

          The app no longer calls any of the four below: the worker converts
          degrees to nanodegrees at its own boundary and asks the wasm core.
          They are kept, and they are not dead weight -- they are the OCaml
          side of js/worker-differential.mjs, which drives the real worker and
          these in one process and requires them to agree point for point,
          address for address, cell for cell. That is what stops the worker's
          conversion and its cell walk from drifting away from the extraction
          they were transcribed from. Delete these and that wall has nothing
          to compare against. *)
       method encodeDeg keyHex lat lon =
         let key = string_of_hex (ostr keyHex) in
         jstr (Tessarium.encode_z ~core ~key ~lat:(ns_of_deg lat) ~lon:(ns_of_deg lon))

       method decodeDeg keyHex addr =
         let key = string_of_hex (ostr keyHex) in
         match core.Tessarium.decode ~key (Tessarium.address_of_string (ostr addr)) with
         | None -> Js.null
         | Some (lat, lon) ->
             Js.some
               (object%js
                  val lat = deg_of_ns lat
                  val lon = deg_of_ns lon
               end)

       (* Corners of the cell containing a point, in degrees. *)
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

          The browser's overlay is walked in ui/public/core.worker.js now,
          over the wasm core's `bounds`. That walk is in BigInt nanodegrees,
          NOT in floats -- crossing a cell boundary in floating point is the
          one thing the integer grid exists to prevent, and moving the walk
          out of OCaml did not relax it. This method is the reference the
          walk is held to, in js/worker-differential.mjs. *)
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

       (* ---------------------------------------------- the wasm core's needs

          The browser answers from wasm/core.wasm, which is the same F*
          extracted to C. Two things it cannot supply for itself, both of
          them data this bundle already holds:

          - the band table, which the wasm needs handed over and sealed
            before it can answer. Float64Array because every entry is below
            2^53 and therefore exact, and because a typed array crosses to
            JavaScript without a per-element conversion.
          - the wordlist codec, both directions. The proved core works in
            indices; turning those into words and back is the one part of an
            address that is not arithmetic, and it stays here so there is a
            single wordlist in the browser rather than a second copy shipped
            beside the wasm. *)
       method cumTable =
         let t = Tessarium_Table_Data.cumcols_list in
         let n = List.length t in
         let a = new%js Typed_array.float64Array n in
         List.iteri
           (fun i v -> Typed_array.set a i (Js.number_of_float (Z.to_float v)))
           t;
         a

       method addressOfIndices w1 w2 w3 n =
         jstr
           (Tessarium.address_to_string
              (Z.of_int w1, Z.of_int w2, Z.of_int w3, Z.of_int n))

       (* "complete" | "partial" | "no" -- see Tessarium.address_shape.
          The search box asks this BEFORE it asks the server anything, so
          that an address never reaches the place index. A string rather
          than a boolean because "not yet, keep quiet" is a third answer and
          collapsing it into either of the other two leaks or annoys. *)
       method addressShape s = jstr (Tessarium.address_shape_string (ostr s))

       (* Returns the indices, or a refusal naming which word or which part
          is wrong -- it does NOT raise.

          It used to. An OCaml exception reaching JavaScript arrives as an
          ARRAY, and the worker dug the message out of its last element; that
          worked only while the payload was a string, and it became a record
          the moment refusals grew codes. Returning the refusal makes the
          shape the caller's business rather than js_of_ocaml's
          representation of an exception. *)
       method indicesOfAddress addr =
         let indices w1 w2 w3 n error =
           object%js
             val w1 = w1
             val w2 = w2
             val w3 = w3
             val n = n
             val error = error
           end
         in
         match Tessarium.address_of_string (ostr addr) with
         | w1, w2, w3, n ->
             indices (Z.to_int w1) (Z.to_int w2) (Z.to_int w3) (Z.to_int n)
               Js.null
         | exception Tessarium.Invalid_address e ->
             indices 0 0 0 0 (Js.some (jrefusal e))
    end)
