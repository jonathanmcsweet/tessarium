(* A ustar/pax reader, for the glyph-and-sprite tarball.

   Written here rather than taken as a dependency because the need is one
   read-only traversal of one well-formed archive, and a tar WRITER -- where
   the format's hair actually is -- is not needed at all.

   Pure: bytes in, (path, contents) list out. The caller decides where files
   land; this module only refuses entries that try to escape (absolute paths,
   ".."), because a tarball is remote input no matter how reputable the host. *)

let block = 512

let trimmed s =
  (* Fixed-width, NUL-padded fields; some writers space-pad octal. *)
  let s = match String.index_opt s '\000' with
    | Some i -> String.sub s 0 i
    | None -> s
  in
  String.trim s

(* A tarball arriving over a connection that dropped is a partial one, and
   its last header is whatever bytes made it. Every field below is therefore
   checked rather than believed, and a failed check is a [Failure] because
   that is the shape the download job turns into a message the user reads --
   an Invalid_argument out of String.sub is an uncaught exception instead.

   Refusing base-256 size fields (the GNU encoding for files over 8 GB) along
   with the garbage is deliberate: nothing in a glyph-and-sprite tarball is
   that size, so the two are indistinguishable here and both are wrong. *)
let malformed what = failwith ("the assets archive is " ^ what)

let octal s =
  let s = trimmed s in
  if s = "" then 0
  else
    match int_of_string_opt ("0o" ^ s) with
    | Some n when n >= 0 -> n
    | _ -> malformed "malformed: a header field is not an octal number"

(* PAX extended headers carry "len key=value\n" records; a "path" record
   overrides the next entry's name, which is how names longer than 100 bytes
   arrive. GitHub's tarballs use exactly this. *)
let pax_path payload =
  let rec scan pos acc =
    if pos >= String.length payload then acc
    else
      match String.index_from_opt payload pos ' ' with
      | None -> acc
      | Some sp -> (
          (* The record's own length has to cover the digits and the space it
             just read, and has to stay inside the payload -- otherwise the
             String.subs below run off the end, and a length of zero makes
             one of them negative. *)
          match int_of_string_opt (String.sub payload pos (sp - pos)) with
          | Some len when len > sp - pos && pos + len <= String.length payload
            ->
              let record = String.sub payload pos (len - 1) in
              let record =
                String.sub record (sp - pos + 1)
                  (String.length record - (sp - pos + 1))
              in
              let acc =
                match String.index_opt record '=' with
                | Some eq when String.sub record 0 eq = "path" ->
                    Some
                      (String.sub record (eq + 1) (String.length record - eq - 1))
                | _ -> acc
              in
              scan (pos + len) acc
          | _ -> acc)
  in
  scan 0 None

let safe path =
  path <> ""
  && (not (String.length path > 0 && path.[0] = '/'))
  && String.split_on_char '/' path
     |> List.for_all (fun seg -> seg <> ".." && seg <> "")

let list (data : string) : (string * string) list =
  let len = String.length data in
  let rec entries pos pending_path acc =
    if pos + block > len then List.rev acc
    else
      let header = String.sub data pos block in
      if String.for_all (fun c -> c = '\000') header then List.rev acc
      else
        let name = trimmed (String.sub header 0 100) in
        let size = octal (String.sub header 124 12) in
        (* The payload has to actually be there. Without this, a connection
           that dropped mid-entry reaches String.sub with a size past the end
           of what arrived. *)
        if size > len - (pos + block) then
          malformed "truncated: an entry claims more bytes than arrived";
        let typeflag = header.[156] in
        let prefix = trimmed (String.sub header 345 155) in
        let payload_blocks = (size + block - 1) / block in
        let next = pos + block + (payload_blocks * block) in
        let payload () = String.sub data (pos + block) size in
        match typeflag with
        | 'x' ->
            (* Applies to the immediately following entry only. *)
            entries next (pax_path (payload ())) acc
        | 'g' -> entries next pending_path acc
        | '0' | '\000' ->
            let path =
              match pending_path with
              | Some p -> p
              | None -> if prefix = "" then name else prefix ^ "/" ^ name
            in
            let acc = if safe path then (path, payload ()) :: acc else acc in
            entries next None acc
        | _ ->
            (* Directories, links, and anything exotic: skipped. Directories
               are implied by the file paths; links from a remote archive are
               a request this code should not honour. *)
            entries next None acc
  in
  entries 0 None []
