(* See http_cache.mli. *)

(* BLAKE2s over the bytes, truncated to 128 bits. An ETag is a cache key, not
   a signature: nothing downstream trusts it, and a collision would show a
   stale body rather than admit an attacker. 128 bits is far past the point
   where that is a real risk, and it keeps the header short. *)
let width = 32
let truncate hex = if String.length hex <= width then hex else String.sub hex 0 width
let hash s = truncate Digestif.BLAKE2S.(to_hex (digest_string s))
let suffix = function None -> "" | Some e -> "-" ^ e
let of_digest ~encoding digest =
  Printf.sprintf "\"%s%s\"" (truncate digest) (suffix encoding)

let of_bytes ~encoding body = of_digest ~encoding (hash body)

let of_stamp ~key ~size ~mtime =
  (* Sub-microsecond, which is as fine as this can be: [mtime] is an IEEE
     double of seconds since the epoch, so around 1.8e9 its own precision is
     about 240 ns whatever the filesystem records. Two writes closer together
     than that share a tag; two writes a millisecond apart do not. *)
  let ns = Int64.of_float (mtime *. 1e9) in
  of_bytes ~encoding:None (Printf.sprintf "%s\x00%x\x00%Lx" key size ns)

(* The header is a comma-separated list of entity-tags, or `*`. Commas are
   legal inside a quoted tag, so this walks the string tracking whether it is
   inside quotes rather than splitting on the character. Ours never contain
   one; a client echoing back a tag from some other server might. *)
let candidates v =
  let n = String.length v in
  let rec go i start quoted acc =
    let cut () =
      let s = String.trim (String.sub v start (i - start)) in
      if s = "" then acc else s :: acc
    in
    if i >= n then List.rev (cut ())
    else
      match v.[i] with
      | '"' -> go (i + 1) start (not quoted) acc
      | ',' when not quoted -> go (i + 1) (i + 1) quoted (cut ())
      | _ -> go (i + 1) start quoted acc
  in
  go 0 0 false []

let is_weak s = String.length s >= 2 && s.[0] = 'W' && s.[1] = '/'
let strip_weak s = if is_weak s then String.sub s 2 (String.length s - 2) else s

let is_fresh ~if_none_match ~etag =
  match if_none_match with
  | None -> false
  | Some v ->
      let want = strip_weak (String.trim etag) in
      List.exists (fun c -> c = "*" || strip_weak c = want) (candidates v)

let range_is_current ~if_range ~etag =
  match if_range with
  | None -> true
  | Some v ->
      let v = String.trim v in
      (* An HTTP-date here is a validator we never issue, so it cannot be
         current; refusing it sends the whole representation, which is the
         safe answer rather than the wrong window. *)
      (not (is_weak v)) && String.equal v (String.trim etag)
