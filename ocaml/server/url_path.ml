(* Turning a request target into a path we are willing to open.

   This is the module that stops `GET /../../etc/passwd`, and the decision is
   not made here. `Tessarium_UrlPath.resolve` is extracted from F*, where
   two theorems are proved of it: every segment it accepts is non-empty, is
   neither `.` nor `..`, and carries no `/`, `\\` or NUL; and a target that
   DECODES to a traversal is refused however it was spelled, which is what
   fixes percent-decoding before validation rather than after. See
   `fstar/Tessarium.UrlPath.fst`.

   What is left of the DECISION here is the conversion at the edge. The proved
   resolver works on byte lists because a request target is octets until
   something decodes it, and because the three bytes that matter -- `/`, `.`
   and NUL -- cannot occur inside a multi-byte UTF-8 sequence. Everything
   below `resolve`, though -- [extension], [content_type], [cache_control] --
   is still hand-written and still trusted, and [content_type] is not a
   cosmetic decision. The proof covers which files may be opened, not what is
   said about them afterwards.

   [string_of_bytes] walks the list once. Written the obvious way, with
   [List.nth] inside [String.init], it is quadratic -- 4 KB of path took 6.6
   ms against 20 us for the string code this replaced, and `resolve` runs
   from [Route.of_request] on every request, before the rate limiter and on
   the only domain the server has. *)

let bytes_of_string s =
  List.init (String.length s) (fun i -> Z.of_int (Char.code s.[i]))

let string_of_bytes bs =
  String.of_seq (Seq.map (fun b -> Char.chr (Z.to_int b)) (List.to_seq bs))

(* Longer than any asset this app serves, and the point past which a target
   costs more to refuse than it is worth reading. The proved resolver works on
   a list of boxed integers, one per byte, so it is linear with a fat constant
   -- 6.5 ms for 64 KB against 0.27 ms for the string code, measured -- and
   cohttp-eio reads the request line with no size limit of its own.

   This is a resource limit, not a safety one, which is why it is here and not
   in the F*: refusing a target early can only shrink the set that is
   accepted, and both theorems constrain what happens when one IS accepted.
   Neither can be weakened by refusing more. *)
let max_target_bytes = 8192

(* [resolve target] is the list of path segments to open under the asset root,
   or [None] if the target is one we refuse.

   A directory target resolves to index.html so the app is reachable at `/`. *)
let resolve target =
  if String.length target > max_target_bytes then None
  else
    match Tessarium_UrlPath.resolve (bytes_of_string target) with
    | None -> None
    | Some segments -> Some (List.map string_of_bytes segments)

let extension name =
  match String.rindex_opt name '.' with
  | None -> ""
  | Some i -> String.lowercase_ascii (String.sub name i (String.length name - i))

(* Only what this app actually serves. An unknown type is deliberately
   octet-stream rather than a guess: a wrong Content-Type on a script is a
   security question, not a cosmetic one. *)
let content_type name =
  match extension name with
  | ".html" -> "text/html; charset=utf-8"
  | ".js" | ".mjs" -> "text/javascript; charset=utf-8"
  | ".css" -> "text/css; charset=utf-8"
  | ".json" -> "application/json; charset=utf-8"
  | ".svg" -> "image/svg+xml"
  | ".png" -> "image/png"
  | ".jpg" | ".jpeg" -> "image/jpeg"
  | ".webp" -> "image/webp"
  | ".ico" -> "image/x-icon"
  | ".woff" -> "font/woff"
  | ".woff2" -> "font/woff2"
  | ".ttf" -> "font/ttf"
  | ".pbf" -> "application/x-protobuf"
  | ".pmtiles" -> "application/octet-stream"
  | ".wasm" -> "application/wasm"
  | ".txt" | ".md" -> "text/plain; charset=utf-8"
  | _ -> "application/octet-stream"

(* Vite emits content-hashed filenames, so those are immutable forever. Nothing
   else is: index.html must be revalidated or a rebuild is invisible. *)
let cache_control segments =
  let name = match List.rev segments with [] -> "" | last :: _ -> last in
  let hashed =
    (* `index-D4ipvZ4X.js` -- a dash then 8+ base64url characters then the
       extension. *)
    let base =
      match String.rindex_opt name '.' with
      | None -> name
      | Some i -> String.sub name 0 i
    in
    match String.rindex_opt base '-' with
    | None -> false
    | Some i ->
        let tag = String.sub base (i + 1) (String.length base - i - 1) in
        String.length tag >= 8
        && String.for_all
             (function
               | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' -> true
               | _ -> false)
             tag
  in
  if hashed then "public, max-age=31536000, immutable"
  else "no-cache"
