(* Adding a region to an archive already on disk, without losing what the
   archive holds. This is what makes "world map first, then detail where you
   need it" possible: without it, every download replaced map.pmtiles
   wholesale and fetching Paris discarded London.

   Planned first, like an extract. Every tile in any input gets exactly one
   entry, and the base's copy wins when both have one -- so a merge never
   re-fetches bytes already on disk, and re-downloading a region you already
   have costs nothing. Fresh regions dedup among themselves the same way, so
   a request naming a country and also one of its cities pays for the overlap
   once. The trade: a merge never refreshes a stale tile either. That is
   recorded in the roadmap, not hidden here. *)

type origin = Base | Fresh

type plan = {
  blobs : (origin * int * int) array;
      (** absolute offset within its origin's archive, and length *)
  tiles : (int * int) array;  (** tile id -> index into [blobs] *)
  fetch_bytes : int;  (** distinct bytes still to pull from the fresh source *)
  total_bytes : int;  (** distinct bytes the merged archive will copy in *)
  fresh_tiles : int;  (** tiles the base did not already hold *)
}

(* [on_entry] is the same cooperative-yield hook [Extract.plan] takes: a
   base archive that has grown to a country is millions of entries, and
   expanding them must not freeze the scheduler that is doing it. *)
let plan ?(on_entry = fun () -> ()) ~(base : Archive.t option)
    (fresh : Extract.plan list) =
  let by_id = Hashtbl.create 4096 in
  (match base with
  | None -> ()
  | Some b ->
      let data = b.Archive.header.Header.data_offset in
      List.iter
        (fun (e : Directory.entry) ->
          on_entry ();
          (* A run covers consecutive tile ids sharing one blob. *)
          for k = 0 to e.Directory.run_length - 1 do
            Hashtbl.replace by_id (e.Directory.tile_id + k)
              (Base, data + e.Directory.offset, e.Directory.length)
          done)
        (Archive.entries b));
  let fresh_tiles = ref 0 in
  List.iter
    (fun (f : Extract.plan) ->
      Array.iter
        (fun (id, blob) ->
          on_entry ();
          if not (Hashtbl.mem by_id id) then begin
            incr fresh_tiles;
            let offset, length = f.Extract.blobs.(blob) in
            Hashtbl.replace by_id id (Fresh, offset, length)
          end)
        f.Extract.tiles)
    fresh;
  let ids =
    Hashtbl.fold (fun id _ acc -> id :: acc) by_id [] |> List.sort compare
  in
  let blob_index = Hashtbl.create 4096 in
  let blobs = ref [] in
  let blob_count = ref 0 in
  let tiles =
    List.map
      (fun id ->
        let location = Hashtbl.find by_id id in
        let index =
          match Hashtbl.find_opt blob_index location with
          | Some i -> i
          | None ->
              let i = !blob_count in
              Hashtbl.replace blob_index location i;
              blobs := location :: !blobs;
              incr blob_count;
              i
        in
        (id, index))
      ids
  in
  let blobs = Array.of_list (List.rev !blobs) in
  let bytes keep =
    Array.fold_left
      (fun acc (origin, _, length) -> if keep origin then acc + length else acc)
      0 blobs
  in
  {
    blobs;
    tiles = Array.of_list tiles;
    fetch_bytes = bytes (fun o -> o = Fresh);
    total_bytes = bytes (fun _ -> true);
    fresh_tiles = !fresh_tiles;
  }

let write (p : plan) (source : Header.t) ~min_zoom ~max_zoom ~min_lon ~min_lat
    ~max_lon ~max_lat ~append ~copy =
  Extract.write_tiles ~source ~min_zoom ~max_zoom ~min_lon ~min_lat ~max_lon
    ~max_lat ~tiles:p.tiles
    ~blob_lengths:(Array.map (fun (_, _, length) -> length) p.blobs)
    ~append
    ~copy_blob:(fun i ->
      let origin, offset, length = p.blobs.(i) in
      copy ~origin ~offset ~length)
