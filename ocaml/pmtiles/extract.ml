(* Building a small PMTiles archive out of a region of a large one.

   This is what makes the map work offline, and it is why the project does not
   depend on the Go `pmtiles` tool: the desktop build is meant to be one static
   binary, and a region downloader that shells out to another program is a
   runtime dependency in everything but name.

   The plan is made before any tile is fetched. That ordering is what lets
   identical tiles -- and a coastline archive has a great many identical ocean
   tiles -- be recognised as one blob and stored once, and it makes the byte
   count knowable in advance so progress can be reported honestly. *)

type plan = {
  (* Distinct blobs to copy, in the order they will be written.

     Offsets here are absolute within the source archive, not relative to its
     data section. Directory entries store the relative form, and mixing the
     two reads tile bytes out of the root directory -- which produces a file
     with a perfectly valid header whose every tile fails to decompress. *)
  blobs : (int * int) array;  (** (absolute source offset, length) *)
  (* One per addressed tile, referring to a blob by index. *)
  tiles : (int * int) array;  (** (tile id, blob index) *)
}

(* Directories are written uncompressed. The format permits it, tiles are
   copied with whatever compression they already had, and it means this module
   needs a gzip decoder but no encoder. *)
let internal_compression = Header.None_

(* The root directory must be fetchable in one request. The spec's guidance is
   16 KB; anything that does not fit goes into leaf directories. *)
let max_root_bytes = 16384

(* [on_tile] is called once per candidate tile. It exists for callers inside
   a cooperative scheduler: a country is a couple of million candidates, and
   a loop that long without a yield freezes every other task the server has.
   This module stays scheduler-agnostic; the caller injects the yield. *)
let plan ?(on_tile = fun () -> ()) ?clip archive ~min_zoom ~max_zoom ~min_lon
    ~min_lat ~max_lon ~max_lat =
  let ids =
    match clip with
    | None ->
        Tile_id.covering ~min_zoom ~max_zoom ~min_lon ~min_lat ~max_lon
          ~max_lat
    | Some clip ->
        Tile_id.covering_clipped ~on_node:on_tile ~min_zoom ~max_zoom
          ~min_lon ~min_lat ~max_lon ~max_lat ~clip ()
  in
  let blob_index = Hashtbl.create 1024 in
  let blobs = ref [] in
  let blob_count = ref 0 in
  let tiles = ref [] in
  let data_offset = archive.Archive.header.Header.data_offset in
  List.iter
    (fun id ->
      on_tile ();
      match Archive.locate archive id with
      | None -> () (* a tile the source does not have; the map draws nothing *)
      | Some (relative, length) ->
          let offset = data_offset + relative in
          let index =
            match Hashtbl.find_opt blob_index (offset, length) with
            | Some i -> i
            | None ->
                let i = !blob_count in
                Hashtbl.replace blob_index (offset, length) i;
                blobs := (offset, length) :: !blobs;
                incr blob_count;
                i
          in
          tiles := (id, index) :: !tiles)
    ids;
  {
    blobs = Array.of_list (List.rev !blobs);
    tiles = Array.of_list (List.rev !tiles);
  }

let planned_bytes p =
  Array.fold_left (fun acc (_, length) -> acc + length) 0 p.blobs

(* Consecutive tile IDs pointing at the same blob collapse into one entry with
   a run length. This is the format's compression for repeated tiles and it is
   the difference between a directory of thousands of entries and one of
   dozens over open water. *)
let entries_of_tiles tiles ~blob_offsets =
  let out = ref [] in
  let count = ref 0 in
  Array.iter
    (fun (tile_id, blob) ->
      let offset, length = blob_offsets.(blob) in
      match !out with
      | last :: rest
        when last.Directory.offset = offset
             && last.Directory.length = length
             && last.Directory.tile_id + last.Directory.run_length = tile_id ->
          out :=
            { last with Directory.run_length = last.Directory.run_length + 1 }
            :: rest
      | _ ->
          incr count;
          out := { Directory.tile_id; offset; length; run_length = 1 } :: !out)
    tiles;
  Array.of_list (List.rev !out)

(* Split entries into a root directory of leaf pointers plus the leaves
   themselves, once they no longer fit in one request.

   The leaf size is chosen by doubling until the root fits, rather than
   computed: entry sizes vary with how well the varints delta-encode, so the
   only reliable measure is to serialize and look. *)
let build_directories entries =
  let root_only = Directory.serialize entries in
  if String.length root_only <= max_root_bytes then (root_only, "", 0)
  else
    let rec attempt leaf_size =
      let n = Array.length entries in
      let leaf_count = (n + leaf_size - 1) / leaf_size in
      let leaves = Buffer.create (n * 8) in
      let pointers = Array.make leaf_count { Directory.tile_id = 0; offset = 0; length = 0; run_length = 0 } in
      for i = 0 to leaf_count - 1 do
        let from = i * leaf_size in
        let len = min leaf_size (n - from) in
        let chunk = Array.sub entries from len in
        let serialized = Directory.serialize chunk in
        pointers.(i) <-
          {
            Directory.tile_id = chunk.(0).Directory.tile_id;
            offset = Buffer.length leaves;
            length = String.length serialized;
            run_length = 0;
          };
        Buffer.add_string leaves serialized
      done;
      let root = Directory.serialize pointers in
      if String.length root <= max_root_bytes || leaf_size >= n then
        (root, Buffer.contents leaves, leaf_count)
      else attempt (leaf_size * 2)
    in
    attempt 256

let e7 v = int_of_float (Float.round (v *. 1e7))

(* The writer under [write] and [Merge.write]: tiles referencing abstract
   blob indices, blob lengths for the layout, and a callback that must append
   blob i's bytes when asked. Keeping the copy injected means this function
   does no IO and the caller decides whether bytes come from a file, a
   socket, or two different archives at once. *)
let write_tiles ?(metadata = "{}") ~(source : Header.t) ~min_zoom ~max_zoom
    ~min_lon ~min_lat ~max_lon ~max_lat ~(tiles : (int * int) array)
    ~(blob_lengths : int array) ~append ~copy_blob () =
  (* Blob offsets are relative to the start of the tile data section, so they
     can be computed before the header's size is known. *)
  let blob_offsets = Array.make (Array.length blob_lengths) (0, 0) in
  let running = ref 0 in
  Array.iteri
    (fun i length ->
      blob_offsets.(i) <- (!running, length);
      running := !running + length)
    blob_lengths;
  let data_length = !running in

  let entries = entries_of_tiles tiles ~blob_offsets in
  let root, leaves, _leaf_count = build_directories entries in

  (* Written archives use no internal compression, so the metadata string is
     stored verbatim -- what the caller passes is byte-for-byte what a reader
     gets back, which the download ledger depends on. *)
  let root_offset = Header.size in
  let metadata_offset = root_offset + String.length root in
  let leaf_offset = metadata_offset + String.length metadata in
  let data_offset = leaf_offset + String.length leaves in

  let addressed = Array.length tiles in
  let header =
    {
      source with
      Header.root_offset;
      root_length = String.length root;
      metadata_offset;
      metadata_length = String.length metadata;
      leaf_offset;
      leaf_length = String.length leaves;
      data_offset;
      data_length;
      addressed_tiles = addressed;
      tile_entries = Array.length entries;
      tile_contents = Array.length blob_lengths;
      (* Blobs are written in ascending tile-id order, which is what clustered
         means and what lets a reader coalesce adjacent requests. *)
      clustered = true;
      internal_compression;
      min_zoom;
      max_zoom;
      min_lon_e7 = e7 min_lon;
      min_lat_e7 = e7 min_lat;
      max_lon_e7 = e7 max_lon;
      max_lat_e7 = e7 max_lat;
      center_zoom = min max_zoom (min_zoom + 2);
      center_lon_e7 = e7 ((min_lon +. max_lon) /. 2.);
      center_lat_e7 = e7 ((min_lat +. max_lat) /. 2.);
    }
  in
  append (Header.serialize header);
  append root;
  append metadata;
  append leaves;
  Array.iteri (fun i _ -> copy_blob i) blob_lengths;
  header

let write ?metadata plan (source : Header.t) ~min_zoom ~max_zoom ~min_lon
    ~min_lat ~max_lon ~max_lat ~append ~copy =
  write_tiles ?metadata ~source ~min_zoom ~max_zoom ~min_lon ~min_lat ~max_lon
    ~max_lat ~tiles:plan.tiles
    ~blob_lengths:(Array.map snd plan.blobs)
    ~append
    ~copy_blob:(fun i ->
      let offset, length = plan.blobs.(i) in
      copy ~offset ~length)
    ()
