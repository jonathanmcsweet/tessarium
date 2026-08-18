(* Structured access logging that cannot emit a secret.

   The safety argument is structural rather than disciplinary. There is no
   free-form message field, so there is nowhere for a phrase, a key or an
   address to be interpolated even by accident. What gets logged is a closed
   variant of route shapes plus a status and a byte count.

   Two things are deliberately absent:

   - The raw request target. It carries the query string, and a query string is
     attacker-controlled and user-controlled at once.
   - Anything derived from a request or response body. Addresses only ever
     travel in bodies, so excluding bodies excludes addresses. *)

type outcome = {
  route : Route.t;
  status : int;
  bytes : int;
  partial : bool;  (** served as a 206 *)
}

(* Asset paths come from the UI build and are safe to name; they are also the
   only ones worth naming, since debugging a blank page means knowing which
   file 404ed. *)
let describe (r : Route.t) =
  match r with
  | Route.Health -> "health"
  | Route.Asset segments -> "asset /" ^ String.concat "/" segments
  | Route.Basemap segments -> "basemap /" ^ String.concat "/" segments
  | Route.Tile { z; x; y } -> Printf.sprintf "tile %d/%d/%d" z x y
  | Route.Api endpoint -> "api " ^ endpoint
  | Route.Not_found -> "not-found"
  | Route.Method_not_allowed -> "method-not-allowed"

let src = Logs.Src.create "tessarium.access" ~doc:"HTTP access log"

module Log = (val Logs.src_log src : Logs.LOG)

let emit { route; status; bytes; partial } =
  let level = if status >= 500 then Logs.Error else Logs.Info in
  Log.msg level (fun m ->
      m "%d%s %s %dB" status
        (if partial then " partial" else "")
        (describe route) bytes)
