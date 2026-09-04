(* See api_guard.mli for why this is a module with an abstract type rather
   than three branches in the handler's match.

   Pure: no socket, no clock. Taking the body off the wire is the caller's
   [read], so this file can be driven by the tests with no server at all. *)

type t = { body : string }

let body t = t.body

type refusal = From_another_site | Not_json | Too_large | Not_binary
type disposal = Drained | Connection_must_close
type outcome = Allowed of t | Refused of refusal * disposal

let max_body = 1 lsl 22

(* Origin is scheme://host[:port]; Host is host[:port]. A null origin -- a
   sandboxed frame, a data: URL -- has no host and matches nothing. *)
let same_origin_as_host origin host =
  let o = String.lowercase_ascii (String.trim origin) in
  let authority =
    match String.index_opt o '/' with
    | Some i when i + 1 < String.length o && o.[i + 1] = '/' ->
        String.sub o (i + 2) (String.length o - i - 2)
    | _ -> ""
  in
  authority <> "" && String.equal authority (String.lowercase_ascii host)

(* Sec-Fetch-Site says where the request came from and every current browser
   sends it; Origin names the page behind a cross-origin write, and older
   browsers send that. curl and scripts send neither, which is what --api is
   for, so silence is allowed: this judges browsers. *)
let from_another_site header =
  match header "sec-fetch-site" with
  | Some s -> (
      match String.lowercase_ascii (String.trim s) with
      | "same-origin" | "none" -> false
      | _ -> true)
  | None -> (
      match header "origin" with
      | None -> false
      | Some o ->
          let host = Option.value (header "host") ~default:"" in
          not (same_origin_as_host o host))

let is_json header =
  match header "content-type" with
  | None -> false
  | Some v ->
      let v = String.lowercase_ascii (String.trim v) in
      let base =
        match String.index_opt v ';' with
        | Some i -> String.trim (String.sub v 0 i)
        | None -> v
      in
      String.equal base "application/json"

(* A streamed upload: same origin check, but the body is bytes rather than
   JSON and is far too large to hold in memory, so it never passes through
   [t]. The content type still has to be one a page cannot send without a
   preflight -- application/octet-stream is not on the CORS safelist, so
   requiring it buys exactly what requiring JSON buys the endpoints above,
   and a form post cannot reach this. *)
type stream = { declared : int }

let declared_length s = s.declared

let is_octet_stream header =
  match header "content-type" with
  | None -> false
  | Some v ->
      let v = String.lowercase_ascii (String.trim v) in
      let base =
        match String.index_opt v ';' with
        | Some i -> String.trim (String.sub v 0 i)
        | None -> v
      in
      String.equal base "application/octet-stream"

(* An upload must say how big it is. Not pedantry: it is the only way the
   receiver can tell a file that finished from one whose connection dropped
   three quarters of the way through -- and a truncated PMTiles archive is
   the one shape that answers every directory lookup and fails half its
   reads, which is exactly the corruption the download path already goes out
   of its way to make impossible. *)
let check_stream ~header ~declares_body =
  if from_another_site header then Error From_another_site
  else if not (is_octet_stream header) then Error Not_binary
  else if not declares_body then Error Too_large
  else
    match Option.map int_of_string_opt (header "content-length") with
    | Some (Some n) when n > 0 -> Ok { declared = n }
    | _ -> Error Too_large

let check ~header ~declares_body ~read =
  (* A refusal still has to clear the socket. [read] answers [None] only when
     the body is over the bound, and then there is nothing to be done but end
     the connection. *)
  let refuse r =
    let disposal =
      if not declares_body then Drained
      else match read () with Some _ -> Drained | None -> Connection_must_close
    in
    Refused (r, disposal)
  in
  if from_another_site header then refuse From_another_site
  else if not (is_json header) then refuse Not_json
  else if not declares_body then Allowed { body = "" }
  else
    match read () with
    | Some body -> Allowed { body }
    | None -> Refused (Too_large, Connection_must_close)
