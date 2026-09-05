(* A whole PMTiles archive assembled from tiles already held in memory.

   The one writer for the small archives this project builds by hand: the
   end-to-end fixture the downloader is driven against, and the synthetic
   archives the server's own suites plan, merge and remove. Each of those
   carried its own copy of this -- a twenty-five field header literal, a
   directory, a data section, and the degrees-to-e7 helper beside it -- so a
   change to the format meant four synchronised edits, and a copy that lagged
   went on compiling while testing a layout nothing writes any more.

   Not the download path. [Extract.write] is what writes an archive out of
   ANOTHER archive, copying blobs it never holds; this is for the case where
   the bytes are in hand and the point is to control exactly which tiles
   exist and what each of them says. *)

(* Answers with the header as well as the bytes: every caller writes the bytes
   somewhere and most of them then want to ask the header a question, and
   parsing back what was just serialized to find out is a round trip with a
   reader in the middle of it.

   Identical tile bodies share one blob, which is what a real writer does and
   what makes an archive of ten thousand identical ocean tiles one blob long.
   [stride] overrides that: every tile gets a slot of its own, that many bytes
   apart, so reading the archive costs one range request per tile instead of
   one for the lot -- the difference between a download that finishes
   instantly and one that can be watched being cancelled. *)
let archive ?(metadata = "{}") ?(compression = Header.None_) ?(stride = 0)
    ?center ~min_zoom ~max_zoom ~min_lon ~min_lat ~max_lon ~max_lat
    ~(tiles : (int * string) list) () =
  let data = Buffer.create 4096 in
  let slot_of = Hashtbl.create 64 in
  let blobs = ref 0 in
  let entries =
    Array.of_list
      (List.map
         (fun (tile_id, body) ->
           let offset =
             if stride > 0 then begin
               let at = !blobs * stride in
               incr blobs;
               Buffer.add_string data body;
               Buffer.add_string data
                 (String.make (max 0 (stride - String.length body)) '\000');
               at
             end
             else
               match Hashtbl.find_opt slot_of body with
               | Some at -> at
               | None ->
                   let at = Buffer.length data in
                   Hashtbl.replace slot_of body at;
                   incr blobs;
                   Buffer.add_string data body;
                   at
           in
           {
             Directory.tile_id;
             offset;
             length = String.length body;
             run_length = 1;
           })
         tiles)
  in
  let data = Buffer.contents data in
  let root = Directory.serialize entries in
  let root_offset = Header.size in
  let metadata_offset = root_offset + String.length root in
  let data_offset = metadata_offset + String.length metadata in
  let center_zoom, center_lon, center_lat =
    match center with Some c -> c | None -> (min_zoom, 0., 0.)
  in
  let header =
    {
      Header.root_offset;
      root_length = String.length root;
      metadata_offset;
      metadata_length = String.length metadata;
      (* No leaf directories: everything these archives hold fits in the
         root, which is what makes them readable with one range request and
         inspectable by eye. *)
      leaf_offset = data_offset;
      leaf_length = 0;
      data_offset;
      data_length = String.length data;
      addressed_tiles = Array.length entries;
      tile_entries = Array.length entries;
      tile_contents = !blobs;
      clustered = true;
      internal_compression = Header.None_;
      tile_compression = compression;
      tile_type = Header.Mvt;
      min_zoom;
      max_zoom;
      min_lon_e7 = Extract.e7 min_lon;
      min_lat_e7 = Extract.e7 min_lat;
      max_lon_e7 = Extract.e7 max_lon;
      max_lat_e7 = Extract.e7 max_lat;
      center_zoom;
      center_lon_e7 = Extract.e7 center_lon;
      center_lat_e7 = Extract.e7 center_lat;
    }
  in
  (header, Header.serialize header ^ root ^ metadata ^ data)

(* The common case: every tile of a box between two zooms, each body decided
   by the caller from the id it belongs to. *)
let of_box ?metadata ?compression ?stride ?center ~min_zoom ~max_zoom ~min_lon
    ~min_lat ~max_lon ~max_lat ~body () =
  archive ?metadata ?compression ?stride ?center ~min_zoom ~max_zoom ~min_lon
    ~min_lat ~max_lon ~max_lat
    ~tiles:
      (List.map
         (fun id -> (id, body id))
         (Tile_id.covering ~min_zoom ~max_zoom ~min_lon ~min_lat ~max_lon
            ~max_lat))
    ()
