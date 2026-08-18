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
   expanding them must not freeze the scheduler that is doing it.

   Arrays and a merge-join rather than a hashtable, deliberately: a giant
   archive expands to tens of millions of entries, and a hashtable over
   them costs several times the memory of the flat arrays. Directories in a
   valid archive arrive sorted by tile id; that is verified rather than
   assumed, because an unsorted merge would corrupt silently. *)
let plan ?(on_entry = fun () -> ()) ~(base : Archive.t option)
    (fresh : Extract.plan list) =
  let compare_id (a, _, _) (b, _, _) = compare a b in
  let sorted arr =
    let ok = ref true in
    for i = 1 to Array.length arr - 1 do
      let a, _, _ = arr.(i - 1) and b, _, _ = arr.(i) in
      if a >= b then ok := false
    done;
    !ok
  in
  let base_arr =
    match base with
    | None -> [||]
    | Some b ->
        let data = b.Archive.header.Header.data_offset in
        let entries = Archive.entries b in
        let total =
          List.fold_left
            (fun acc (e : Directory.entry) -> acc + e.Directory.run_length)
            0 entries
        in
        let arr = Array.make total (0, 0, 0) in
        let i = ref 0 in
        List.iter
          (fun (e : Directory.entry) ->
            on_entry ();
            (* A run covers consecutive tile ids sharing one blob. *)
            for k = 0 to e.Directory.run_length - 1 do
              arr.(!i) <-
                ( e.Directory.tile_id + k,
                  data + e.Directory.offset,
                  e.Directory.length );
              incr i
            done)
          entries;
        if not (sorted arr) then Array.sort compare_id arr;
        arr
  in
  let fresh_arr =
    let total =
      List.fold_left
        (fun acc (f : Extract.plan) -> acc + Array.length f.Extract.tiles)
        0 fresh
    in
    let arr = Array.make total (0, 0, 0) in
    let i = ref 0 in
    List.iter
      (fun (f : Extract.plan) ->
        Array.iter
          (fun (id, blob) ->
            on_entry ();
            let offset, length = f.Extract.blobs.(blob) in
            arr.(!i) <- (id, offset, length);
            incr i)
          f.Extract.tiles)
      fresh;
    (* Regions arrive as separate plans and may overlap; duplicates carry
       identical locations (same id in the same remote archive), so any
       survivor of the dedup below is the right one. *)
    if not (sorted arr) then Array.sort compare_id arr;
    arr
  in
  let n_base = Array.length base_arr and n_fresh = Array.length fresh_arr in
  let blob_index = Hashtbl.create 4096 in
  let blobs = ref [] in
  let blob_count = ref 0 in
  let tiles = Array.make (max 1 (n_base + n_fresh)) (0, 0) in
  let out = ref 0 in
  let fresh_tiles = ref 0 in
  let emit id location =
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
    tiles.(!out) <- (id, index);
    incr out
  in
  let bi = ref 0 and fi = ref 0 in
  let id_at arr i =
    let id, _, _ = arr.(i) in
    id
  in
  while !bi < n_base || !fi < n_fresh do
    on_entry ();
    let take_base =
      !fi >= n_fresh
      || (!bi < n_base && id_at base_arr !bi <= id_at fresh_arr !fi)
    in
    if take_base then begin
      let id, offset, length = base_arr.(!bi) in
      emit id (Base, offset, length);
      incr bi;
      (* The base wins ties, and each id is emitted once. *)
      while !bi < n_base && id_at base_arr !bi = id do
        incr bi
      done;
      while !fi < n_fresh && id_at fresh_arr !fi = id do
        incr fi
      done
    end
    else begin
      let id, offset, length = fresh_arr.(!fi) in
      emit id (Fresh, offset, length);
      incr fresh_tiles;
      incr fi;
      while !fi < n_fresh && id_at fresh_arr !fi = id do
        incr fi
      done
    end
  done;
  let tiles = Array.sub tiles 0 !out in
  let blobs = Array.of_list (List.rev !blobs) in
  let bytes keep =
    Array.fold_left
      (fun acc (origin, _, length) -> if keep origin then acc + length else acc)
      0 blobs
  in
  {
    blobs;
    tiles;
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
