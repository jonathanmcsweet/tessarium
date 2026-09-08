(* Access logging with no way to print a secret.

   There is no free-form message field, so a phrase, a key or an address has
   nowhere to be interpolated even by accident. A line holds a route shape, a
   status and a byte count.

   Two things are left out on purpose:

   - The raw request target, because it carries the query string, which the
     user and an attacker both control.
   - Anything from a request or response body. Addresses only travel in
     bodies. *)

type outcome = {
  route : Route.t;
  status : int;
  bytes : int;
  partial : bool;  (** served as a 206 *)
}

(* Everything request-derived passes through here on its way to a log line.
   `Url_path.resolve` rejects NUL, separators and a leading dot, but not CR or
   LF, and log lines are newline-delimited: `GET /%0d%0afake-looking-line`
   would otherwise write a second line that reads like this server wrote it.
   Bytes outside printable ASCII become `\xNN`, backslash included, so nothing
   in the output can end a line.

   The paths logged are the ones requests asked for, not the ones the UI build
   produced. A 404 is the case worth debugging when a page comes up blank, and
   those paths are exactly the ones the build never asked for. *)
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
  | Route.Import -> "import"
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
