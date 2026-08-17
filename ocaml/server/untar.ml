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

let octal s =
  let s = trimmed s in
  if s = "" then 0 else int_of_string ("0o" ^ s)

(* PAX extended headers carry "len key=value\n" records; a "path" record
   overrides the next entry's name, which is how names longer than 100 bytes
   arrive. GitHub's tarballs use exactly this. *)
let pax_path payload =
  let rec scan pos acc =
    if pos >= String.length payload then acc
    else
      match String.index_from_opt payload pos ' ' with
      | None -> acc
      | Some sp ->
          let len = int_of_string (String.sub payload pos (sp - pos)) in
          let record = String.sub payload pos (len - 1) in
          let record = String.sub record (sp - pos + 1) (String.length record - (sp - pos + 1)) in
          let acc =
            match String.index_opt record '=' with
            | Some eq when String.sub record 0 eq = "path" ->
                Some (String.sub record (eq + 1) (String.length record - eq - 1))
            | _ -> acc
          in
          scan (pos + len) acc
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
