(* RFC 9110 section 14 byte ranges.

   PMTiles is read entirely through range requests -- the client fetches a
   header, then a directory, then individual tiles, out of one file it never
   downloads whole. Getting this wrong does not fail loudly; it hands back the
   wrong bytes and the map renders as garbage.

   Single ranges only. Multipart/byteranges is legal to decline, and declining
   is a full response rather than an error, so a client asking for several
   ranges still works. *)

type span = {
  first : int;  (** inclusive *)
  last : int;  (** inclusive *)
}

type t =
  | Whole  (** no range asked for, or one we decline to honour *)
  | Partial of span
  | Unsatisfiable

let length_of s = s.last - s.first + 1

(* A syntactically invalid Range is ignored rather than rejected (RFC 9110
   section 14.2): the response is the whole representation, not a 400. *)
let parse ~header ~length =
  let int_opt s = int_of_string_opt (String.trim s) in
  let suffix ~n =
    (* "-500" means the last 500 bytes. Zero bytes is unsatisfiable, not
       empty. *)
    if n <= 0 then Unsatisfiable
    else if length = 0 then Unsatisfiable
    else Partial { first = max 0 (length - n); last = length - 1 }
  in
  let from ~first ~last =
    if first < 0 || first >= length then Unsatisfiable
    else
      match last with
      | Some l when l < first -> Whole (* inverted: malformed, so ignore *)
      | Some l -> Partial { first; last = min l (length - 1) }
      | None -> Partial { first; last = length - 1 }
  in
  match header with
  | None -> Whole
  | Some h -> (
      let h = String.trim h in
      let prefix = "bytes=" in
      let n = String.length prefix in
      if
        String.length h <= n
        || not (String.equal (String.lowercase_ascii (String.sub h 0 n)) prefix)
      then Whole
      else
        let spec = String.sub h n (String.length h - n) in
        (* Several ranges is a valid request we choose not to serve. *)
        if String.contains spec ',' then Whole
        else
          match String.index_opt spec '-' with
          | None -> Whole
          | Some i -> (
              let lhs = String.sub spec 0 i in
              let rhs = String.sub spec (i + 1) (String.length spec - i - 1) in
              match (String.trim lhs, String.trim rhs) with
              | "", "" -> Whole
              | "", r -> (
                  match int_opt r with Some n -> suffix ~n | None -> Whole)
              | l, "" -> (
                  match int_opt l with
                  | Some first -> from ~first ~last:None
                  | None -> Whole)
              | l, r -> (
                  match (int_opt l, int_opt r) with
                  | Some first, Some last -> from ~first ~last:(Some last)
                  | _ -> Whole)))

let content_range span ~length =
  Printf.sprintf "bytes %d-%d/%d" span.first span.last length

(* 416 carries the length so the client can retry with a range that exists. *)
let unsatisfiable_content_range ~length = Printf.sprintf "bytes */%d" length
