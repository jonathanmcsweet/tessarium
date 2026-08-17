(* Reading a PMTiles archive through an injected byte source.

   The source is a function, not a file handle, so the same code reads a local
   archive and a remote one over HTTP range requests. That is the whole
   interface an archive needs: it is a format designed to be read by asking
   for byte ranges and nothing else.

   Directories are cached. A tile lookup walks root then leaf, and without a
   cache every tile in a region would re-fetch and re-decompress the same leaf
   directory. *)

type source = { read : offset:int -> length:int -> string }

type t = {
  src : source;
  header : Header.t;
  root : Directory.entry array;
  leaves : (int * int, Directory.entry array) Hashtbl.t;
}

let inflate (compression : Header.compression) data =
  match compression with
  | Header.None_ | Header.Unknown -> data
  | Header.Gzip -> Gzip.decompress data
  (* Both are legal in the format and neither appears in a Protomaps build.
     Refusing loudly beats returning bytes that are not a directory. *)
  | Header.Brotli -> invalid_arg "pmtiles: brotli directories are not supported"
  | Header.Zstd -> invalid_arg "pmtiles: zstd directories are not supported"

let read_directory src header ~offset ~length =
  Directory.deserialize (inflate header.Header.internal_compression (src.read ~offset ~length))

let open_ src =
  let header = Header.parse (src.read ~offset:0 ~length:Header.size) in
  let root =
    read_directory src header ~offset:header.Header.root_offset
      ~length:header.Header.root_length
  in
  { src; header; root; leaves = Hashtbl.create 16 }

let metadata t =
  inflate t.header.Header.internal_compression
    (t.src.read ~offset:t.header.Header.metadata_offset
       ~length:t.header.Header.metadata_length)

let leaf t ~offset ~length =
  match Hashtbl.find_opt t.leaves (offset, length) with
  | Some d -> d
  | None ->
      let d =
        read_directory t.src t.header
          ~offset:(t.header.Header.leaf_offset + offset)
          ~length
      in
      Hashtbl.replace t.leaves (offset, length) d;
      d

(* Where a tile's bytes live, without fetching them. Separated from [tile] so
   an extract can plan its reads -- and deduplicate them -- before doing any.

   The spec allows leaf directories to nest, so this follows rather than
   assuming one level. *)
let locate t tile_id =
  let rec walk entries depth =
    if depth > 4 then None (* a cycle in a malformed archive *)
    else
      match Directory.find entries tile_id with
      | None -> None
      | Some e when Directory.is_leaf_pointer e ->
          walk (leaf t ~offset:e.Directory.offset ~length:e.Directory.length) (depth + 1)
      | Some e -> Some (e.Directory.offset, e.Directory.length)
  in
  walk t.root 0

let tile t tile_id =
  match locate t tile_id with
  | None -> None
  | Some (offset, length) ->
      Some (t.src.read ~offset:(t.header.Header.data_offset + offset) ~length)

(* Every tile entry in the archive, leaf pointers resolved, in tile-id order.
   Runs are kept as runs; the caller decides whether to expand them. This is
   what a merge walks: the whole contents, not one lookup. *)
let entries t =
  let rec expand depth entry_list =
    List.concat_map
      (fun e ->
        if Directory.is_leaf_pointer e then
          if depth >= 4 then invalid_arg "pmtiles: directories nest too deep"
          else
            expand (depth + 1)
              (Array.to_list
                 (leaf t ~offset:e.Directory.offset ~length:e.Directory.length))
        else [ e ])
      entry_list
  in
  expand 0 (Array.to_list t.root)
