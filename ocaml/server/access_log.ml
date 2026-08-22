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

(* Anything request-derived that reaches a log line goes through this first.
   `Url_path.resolve` refuses NUL, a separator and a leading dot, none of which
   is about logging -- a segment may still hold CR or LF, and a log line is
   newline-delimited, so `GET /%0d%0afake-looking-line` would otherwise write a
   second line that reads like one this server emitted. Bytes outside printable
   ASCII become `\xNN`; the backslash is escaped too, so the encoding is
   reversible and nothing in the output can end a line.

   Paths named by a request, NOT by the UI build, which is what this comment
   used to say. A 404 is the interesting case for debugging a blank page, and
   the ones worth debugging are exactly the ones the build did not ask for. *)
let printable s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      if c >= ' ' && c <= '~' && c <> '\\' then Buffer.add_char buf c
      else Buffer.add_string buf (Printf.sprintf "\\x%02x" (Char.code c)))
    s;
  Buffer.contents buf

let describe (r : Route.t) =
  match r with
  | Route.Health -> "health"
  | Route.Asset segments -> printable ("asset /" ^ String.concat "/" segments)
  | Route.Basemap segments ->
      printable ("basemap /" ^ String.concat "/" segments)
  | Route.Tile { z; x; y } -> Printf.sprintf "tile %d/%d/%d" z x y
  | Route.Tile_json { floor } -> if floor then "world.json" else "tiles.json"
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
