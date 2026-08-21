(* See http_cache.mli. *)

(* BLAKE2s over the bytes, truncated to 128 bits. An ETag is a cache key, not
   a signature: nothing downstream trusts it, and a collision would show a
   stale body rather than admit an attacker. 128 bits is far past the point
   where that is a real risk, and it keeps the header short. *)
let hash s =
  let hex = Digestif.BLAKE2S.(to_hex (digest_string s)) in
  String.sub hex 0 32

let suffix = function None -> "" | Some e -> "-" ^ e

let of_digest ~encoding digest =
  Printf.sprintf "\"%s%s\"" digest (suffix encoding)

let of_bytes ~encoding body = of_digest ~encoding (hash body)

let of_stamp ~encoding ~size ~mtime =
  (* Nanoseconds so that two writes inside the same second are two tags on
     any filesystem that records them apart. *)
  let ns = Int64.of_float (mtime *. 1e9) in
  Printf.sprintf "\"%x-%Lx%s\"" size ns (suffix encoding)

(* The header is a comma-separated list of entity-tags, or `*`. Commas are
   legal inside a quoted tag, so this walks the string tracking whether it is
   inside quotes rather than splitting on the character. Ours never contain
   one; a client echoing back a tag from some other server might. *)
let candidates v =
  let n = String.length v in
  let out = ref [] and buf = Buffer.create 32 and quoted = ref false in
  let flush () =
    let s = String.trim (Buffer.contents buf) in
    if s <> "" then out := s :: !out;
    Buffer.clear buf
  in
  for i = 0 to n - 1 do
    let c = v.[i] in
    if c = '"' then begin
      quoted := not !quoted;
      Buffer.add_char buf c
    end
    else if c = ',' && not !quoted then flush ()
    else Buffer.add_char buf c
  done;
  flush ();
  List.rev !out

(* Weak comparison: the two tags are the same entry if they are equal once the
   weakness marker is dropped from either. *)
let strip_weak s =
  if String.length s >= 2 && s.[0] = 'W' && s.[1] = '/' then
    String.sub s 2 (String.length s - 2)
  else s

let is_fresh ~if_none_match ~etag =
  match if_none_match with
  | None -> false
  | Some v ->
      let want = strip_weak (String.trim etag) in
      List.exists
        (fun c -> c = "*" || strip_weak c = want)
        (candidates v)
