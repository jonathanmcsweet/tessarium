(* Adds a region to an archive already on disk without losing what the archive
   holds. Before this, every download replaced map.pmtiles wholesale, so
   fetching Paris discarded London.

   Planned first, like an extract. Every tile gets exactly one entry, and the
   base's copy wins when both have one, so re-downloading a region already on
   disk fetches nothing. Fresh regions dedup among themselves the same way: a
   request naming a country and one of its cities pays for the overlap once.
   The trade-off is that a merge never refreshes a stale tile on its own.
   [refresh] flips the tie so a region can be updated on purpose. *)

type origin =
  | Base
  | Fresh

type plan = {
  blobs : (origin * int * int) array;
      (** absolute offset within its origin's archive, and length *)
  tiles : (int * int) array;  (** tile id -> index into [blobs] *)
  fetch_bytes : int;  (** distinct bytes still to pull from the fresh source *)
  total_bytes : int;  (** distinct bytes the merged archive will copy in *)
  fresh_tiles : int;  (** tiles the base did not already hold *)
  refreshed_tiles : int;
      (** tiles both held where the fresh copy won -- always 0 unless the plan
          was made with [refresh:true] *)
}

(* [on_entry] is the cooperative-yield hook [Extract.plan] also takes: a base
   archive grown to a whole country is millions of entries, and expanding them
   must not freeze the scheduler.

   Arrays and a merge-join instead of a hashtable: tens of millions of entries
   cost several times the memory in a hashtable. A valid archive's directories
   are sorted by tile id, but sortedness is checked rather than assumed -- an
   unsorted merge would corrupt silently. *)
let compare_id (a, _, _) (b, _, _) = compare a b

let sorted arr =
  let ok = ref true in
  for i = 1 to Array.length arr - 1 do
    let a, _, _ = arr.(i - 1) and b, _, _ = arr.(i) in
    if a >= b then ok := false
  done;
  !ok

(* Every (tile id, absolute offset, length) a base archive holds, sorted. *)
let expand_base ~on_entry (b : Archive.t) =
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

let plan ?(on_entry = fun () -> ()) ?(refresh = false)
    ~(base : Archive.t option) (fresh : Extract.plan list) =
  let base_arr =
    match base with None -> [||] | Some b -> expand_base ~on_entry b
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
    (* Separate region plans can overlap. Duplicates point at the same id in
       the same remote archive, so whichever copy survives the dedup below is
       the right one. *)
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
  let refreshed_tiles = ref 0 in
  let id_at arr i =
    let id, _, _ = arr.(i) in
    id
  in
  while !bi < n_base || !fi < n_fresh do
    on_entry ();
    (* Ties go to the base, so re-downloading held tiles costs nothing. Under
       [refresh] the fresh copy wins instead. *)
    let take_base =
      !fi >= n_fresh
      || !bi < n_base
         &&
         if refresh then id_at base_arr !bi < id_at fresh_arr !fi
         else id_at base_arr !bi <= id_at fresh_arr !fi
    in
    if take_base then begin
      let id, offset, length = base_arr.(!bi) in
      emit id (Base, offset, length);
      incr bi;
      (* Each id is emitted once. *)
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
      if !bi < n_base && id_at base_arr !bi = id then begin
        (* The base held this id too. Under [refresh] the fresh copy just
            replaced it, so skip the base's copies. *)
        incr refreshed_tiles;
        while !bi < n_base && id_at base_arr !bi = id do
          incr bi
        done
      end
      else incr fresh_tiles;
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
    refreshed_tiles = !refreshed_tiles;
  }

(* The inverse of adding a region: every base tile survives except the ones
   [drop] names by coordinate. Returns the same [plan] shape [write] takes,
   with every blob a Base blob -- removal never touches the network. A shared
   blob loses its bytes only when every tile using it is dropped, so a
   deduplicated ocean tile survives while anything still points at it. *)
let prune ?(on_entry = fun () -> ()) ~(base : Archive.t) ~drop () =
  let base_arr = expand_base ~on_entry base in
  let blob_index = Hashtbl.create 4096 in
  let blobs = ref [] in
  let blob_count = ref 0 in
  let tiles = Array.make (max 1 (Array.length base_arr)) (0, 0) in
  let out = ref 0 in
  let dropped_tiles = ref 0 in
  Array.iter
    (fun (id, offset, length) ->
      on_entry ();
      let z, x, y = Tile_id.to_zxy id in
      if drop ~z ~x ~y then incr dropped_tiles
      else begin
        let location = (Base, offset, length) in
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
      end)
    base_arr;
  let tiles = Array.sub tiles 0 !out in
  let blobs = Array.of_list (List.rev !blobs) in
  let total_bytes =
    Array.fold_left (fun acc (_, _, length) -> acc + length) 0 blobs
  in
  ( {
      blobs;
      tiles;
      fetch_bytes = 0;
      total_bytes;
      fresh_tiles = 0;
      refreshed_tiles = 0;
    },
    !dropped_tiles )

(* [copy] gets [index], the blob's position in [p.blobs], along with where to
   read it. The index lets a caller attribute bytes to a region -- the download
   uses it that way -- which the offset alone cannot do once the merge has
   deduplicated across regions. Blobs happen to be copied in ascending index
   order, but take the index from here rather than counting calls: the order is
   [write_tiles]'s business, not a promise. *)
let write ?metadata (p : plan) (source : Header.t) ~min_zoom ~max_zoom ~min_lon
    ~min_lat ~max_lon ~max_lat ~append ~copy =
  Extract.write_tiles ?metadata ~source ~min_zoom ~max_zoom ~min_lon ~min_lat
    ~max_lon ~max_lat ~tiles:p.tiles
    ~blob_lengths:(Array.map (fun (_, _, length) -> length) p.blobs)
    ~append
    ~copy_blob:(fun i ->
      let origin, offset, length = p.blobs.(i) in
      copy ~index:i ~origin ~offset ~length)
    ()
