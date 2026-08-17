(* Turning a request target into a path we are willing to open.

   This is the module that stops `GET /../../etc/passwd`. It is pure and
   separately tested for that reason: the safety argument is "these segments
   contain no traversal", which is checkable without a filesystem.

   Percent-decoding happens first. Validating before decoding would accept
   `%2e%2e` and hand back `..`. *)

let hex_val c =
  match c with
  | '0' .. '9' -> Some (Char.code c - Char.code '0')
  | 'a' .. 'f' -> Some (Char.code c - Char.code 'a' + 10)
  | 'A' .. 'F' -> Some (Char.code c - Char.code 'A' + 10)
  | _ -> None

let percent_decode s =
  let n = String.length s in
  let buf = Buffer.create n in
  let rec go i =
    if i >= n then Some (Buffer.contents buf)
    else if s.[i] <> '%' then (
      Buffer.add_char buf s.[i];
      go (i + 1))
    else if i + 2 >= n then None
    else
      match (hex_val s.[i + 1], hex_val s.[i + 2]) with
      | Some hi, Some lo ->
          Buffer.add_char buf (Char.chr ((hi * 16) + lo));
          go (i + 3)
      | _ -> None
  in
  go 0

let query_stripped s =
  match String.index_opt s '?' with
  | None -> ( match String.index_opt s '#' with
              | None -> s
              | Some i -> String.sub s 0 i)
  | Some i -> String.sub s 0 i

(* [resolve target] is the list of path segments to open under the asset root,
   or [None] if the target is one we refuse.

   A directory target resolves to index.html so the app is reachable at `/`. *)
let resolve target =
  match percent_decode (query_stripped target) with
  | None -> None
  | Some path ->
      let segments =
        String.split_on_char '/' path |> List.filter (fun s -> s <> "")
      in
      let unsafe s =
        s = "." || s = ".."
        || String.contains s '\000'
        || String.contains s '\\'
        (* A leading dot is not a traversal, but nothing the UI build emits
           starts with one, and dotfiles are exactly what should not leak. *)
        || (String.length s > 0 && s.[0] = '.')
      in
      if List.exists unsafe segments then None
      else match segments with [] -> Some [ "index.html" ] | s -> Some s

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
