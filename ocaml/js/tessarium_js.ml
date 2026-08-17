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

let hex_of_string s =
  String.concat ""
    (List.init (String.length s) (fun i -> Printf.sprintf "%02x" (Char.code s.[i])))

let string_of_hex h =
  String.init (String.length h / 2) (fun i ->
      Char.chr (int_of_string ("0x" ^ String.sub h (2 * i) 2)))

let ns_of_deg (d : float) = Z.of_float (Float.round (d *. 1e9))
let deg_of_ns (z : Z.t) = Z.to_float z /. 1e9

let jstr = Js.string
let ostr = Js.to_string

let () =
  Js.export "tessarium"
    (object%js
       val gridVersion = jstr Tessarium.grid_version
       val totalCells = jstr (Z.to_string Tessarium_Table.total_cells)

       (* Slow by design: PBKDF2 with 2048 iterations. Call once per session,
          off the UI thread. *)
       (* Returns {key, error}; one is always null. Avoids exception interop. *)
       method deriveKey mnemonic passphrase =
         try
           let k =
             Tessarium.derive_key ~mnemonic:(ostr mnemonic)
               ~passphrase:(ostr passphrase)
           in
           object%js
             val key = Js.some (jstr (hex_of_string k))
             val error = Js.null
           end
         with Tessarium.Bad_mnemonic e ->
           object%js
             val key = Js.null
             val error = Js.some (jstr e)
           end

       method validateMnemonic mnemonic =
         match Tessarium.validate_mnemonic (ostr mnemonic) with
         | Ok () -> Js.null
         | Error e -> Js.some (jstr e)

       (* Exact interface: nanodegrees as decimal strings. *)
       method encodeNs keyHex latNs lonNs =
         let key = string_of_hex (ostr keyHex) in
         let lat = Z.of_string (ostr latNs) and lon = Z.of_string (ostr lonNs) in
         jstr (Tessarium.encode_z ~key ~lat ~lon)

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
         jstr (Tessarium.encode_z ~key ~lat:(ns_of_deg lat) ~lon:(ns_of_deg lon))

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
           Tessarium.cell_bounds_z ~lat:(ns_of_deg lat) ~lon:(ns_of_deg lon)
         in
         object%js
           val latLo = deg_of_ns a
           val latHi = deg_of_ns b
           val lonLo = deg_of_ns c
           val lonHi = deg_of_ns d
         end
    end)
