(* tessarium HTTP service.

   Deliberately thin. The interesting logic is all in the extracted core; this
   layer is I/O and caching only.

   OPEN QUESTION (roadmap Phase 5): whether this service should ever see a
   seed phrase at all. Client-side derivation with the server reduced to a
   dumb tile helper is the better privacy story and should be settled before
   the API shape hardens. The /encode and /decode routes below take a key id
   rather than a mnemonic precisely to keep that door open. *)

let key_cache : (string, Tessarium.Tessarium_core.key) Hashtbl.t = Hashtbl.create 64

(* Session keys are held in memory only, never logged, never persisted. *)
let key_for id =
  match Hashtbl.find_opt key_cache id with
  | Some k -> Ok k
  | None -> Error "unknown session key; POST /session first"

let json_error status msg =
  Dream.json ~status (Yojson.Safe.to_string (`Assoc [ "error", `String msg ]))

let parse_ns s = try Some (Int64.to_int (Int64.of_string s)) with _ -> None

let () =
  Dream.run ~interface:"0.0.0.0" ~port:8080
  @@ Dream.logger
  @@ Dream.router
       [
         Dream.get "/health" (fun _ ->
             Dream.json
               (Yojson.Safe.to_string
                  (`Assoc
                    [ "status", `String "ok";
                      "grid", `String Tessarium.Tessarium_core.grid_version;
                      "cells", `Int Tessarium.Tessarium_core.total_cells ])));

         (* Derive and cache a session key. The mnemonic is used and dropped;
            it is never written to a log or a store. *)
         Dream.post "/session" (fun req ->
             let%lwt body = Dream.body req in
             match Yojson.Safe.from_string body with
             | `Assoc fields -> (
                 match List.assoc_opt "mnemonic" fields with
                 | Some (`String m) -> (
                     match Tessarium.Tessarium_core.validate_mnemonic m with
                     | Error e -> json_error `Bad_Request e
                     | Ok () ->
                         let key =
                           Tessarium.Tessarium_core.derive_key ~mnemonic:m ~passphrase:""
                         in
                         let id = Dream.random 16 |> Dream.to_base64url in
                         Hashtbl.replace key_cache id key;
                         Dream.json
                           (Yojson.Safe.to_string
                              (`Assoc [ "session", `String id ])))
                 | _ -> json_error `Bad_Request "expected {\"mnemonic\": ...}")
             | _ | (exception _) -> json_error `Bad_Request "malformed JSON");

         Dream.get "/encode/:session/:lat/:lon" (fun req ->
             match key_for (Dream.param req "session") with
             | Error e -> json_error `Not_Found e
             | Ok key -> (
                 match
                   (parse_ns (Dream.param req "lat"), parse_ns (Dream.param req "lon"))
                 with
                 | Some lat_ns, Some lon_ns -> (
                     try
                       Dream.json
                         (Yojson.Safe.to_string
                            (`Assoc
                              [ "address",
                                `String (Tessarium.Tessarium_core.encode key ~lat_ns ~lon_ns) ]))
                     with Tessarium.Tessarium_core.Out_of_range m ->
                       json_error `Bad_Request m)
                 | _ ->
                     json_error `Bad_Request
                       "lat and lon must be integer nanodegrees"));

         Dream.get "/decode/:session/:address" (fun req ->
             match key_for (Dream.param req "session") with
             | Error e -> json_error `Not_Found e
             | Ok key -> (
                 match Tessarium.Tessarium_core.decode key (Dream.param req "address") with
                 | Error e -> json_error `Not_Found e
                 | Ok (lat_ns, lon_ns) ->
                     Dream.json
                       (Yojson.Safe.to_string
                          (`Assoc [ "lat_ns", `Int lat_ns; "lon_ns", `Int lon_ns ]))));
       ]
