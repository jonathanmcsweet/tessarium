(* Adding a region to an archive already on disk, without losing what the
   archive holds. This is what makes "world map first, then detail where you
   need it" possible: without it, every download replaced map.pmtiles
   wholesale and fetching Paris discarded London.

   Planned first, like an extract. Every tile in any input gets exactly one
   entry, and the base's copy wins when both have one -- so a merge never
   re-fetches bytes already on disk, and re-downloading a region you already
   have costs nothing. Fresh regions dedup among themselves the same way, so
   a request naming a country and also one of its cities pays for the overlap
   once. The trade: a merge never refreshes a stale tile on its own --
   [refresh] inverts the tie exactly so a recorded region can be brought up
   to date deliberately, and nothing refreshes by accident. *)

type origin = Base | Fresh

type plan = {
  blobs : (origin * int * int) array;
      (** absolute offset within its origin's archive, and length *)
  tiles : (int * int) array;  (** tile id -> index into [blobs] *)
  fetch_bytes : int;  (** distinct bytes still to pull from the fresh source *)
  total_bytes : int;  (** distinct bytes the merged archive will copy in *)
  fresh_tiles : int;  (** tiles the base did not already hold *)
  refreshed_tiles : int;
      (** tiles both held where the fresh copy won -- always 0 unless the
          plan was made with [refresh:true] *)
}

(* [on_entry] is the same cooperative-yield hook [Extract.plan] takes: a
   base archive that has grown to a country is millions of entries, and
   expanding them must not freeze the scheduler that is doing it.

   Arrays and a merge-join rather than a hashtable, deliberately: a giant
   archive expands to tens of millions of entries, and a hashtable over
   them costs several times the memory of the flat arrays. Directories in a
   valid archive arrive sorted by tile id; that is verified rather than
   assumed, because an unsorted merge would corrupt silently. *)
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
          (e.Directory.tile_id + k, data + e.Directory.offset, e.Directory.length);
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
  let refreshed_tiles = ref 0 in
  let id_at arr i =
    let id, _, _ = arr.(i) in
    id
  in
  while !bi < n_base || !fi < n_fresh do
    on_entry ();
    (* Ties go to the base -- re-downloading held tiles must cost nothing --
       except under [refresh], where the whole point is the fresh copy. *)
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
      (if !bi < n_base && id_at base_arr !bi = id then begin
         (* The base held this id too; under [refresh] the fresh copy just
            replaced it, and the base's duplicates are consumed here. *)
         incr refreshed_tiles;
         while !bi < n_base && id_at base_arr !bi = id do
           incr bi
         done
       end
       else incr fresh_tiles);
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
   [drop] names by coordinate. The result is the same [plan] shape [write]
   takes, with every blob a Base blob -- a removal never touches the
   network. Blob sharing is honoured exactly as in [plan]: a blob loses its
   bytes only when every tile referencing it is dropped, so deduplicated
   ocean tiles survive as long as anyone needs them. *)
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

(* The same plan, narrowed to the tiles [keep] names.

   This is what lets ONE pass over the network write two archives. The
   download writes the whole merged archive; a caller that also wants the
   downloaded region as a file of its own selects it out of the same plan,
   and every blob the smaller archive needs goes past exactly once while the
   big one is being written. Without this the region has to be extracted
   afterwards, which reads the whole archive back to write a fraction of it.

   Returns the narrowed plan and a map from the parent's blob index to the
   child's, or -1 where the child does not want that blob. The caller uses it
   to answer "does this blob belong to the small archive, and where" while
   the bytes are in its hand.

   Blob sharing is honoured as in [plan] and [prune]: a blob survives while
   any kept tile still references it. Child blob indices follow first
   reference in kept-tile order, which is what keeps the child `clustered` --
   its data section is ordered by tile id, exactly as the parent's is. That
   order is NOT the parent's, and deliberately so: deduplication lets a later
   tile reference an earlier blob, so the child's sequence is not a
   subsequence of the parent's. A caller writing both at once must place
   blobs by offset rather than by appending in arrival order. *)
let select ?(on_entry = fun () -> ()) ~keep (p : plan) =
  let parent_blobs = Array.length p.blobs in
  let mapping = Array.make (max 1 parent_blobs) (-1) in
  let blobs = ref [] in
  let blob_count = ref 0 in
  let tiles = Array.make (max 1 (Array.length p.tiles)) (0, 0) in
  let out = ref 0 in
  Array.iter
    (fun (id, parent_index) ->
      on_entry ();
      let z, x, y = Tile_id.to_zxy id in
      if keep ~z ~x ~y then begin
        let index =
          if mapping.(parent_index) >= 0 then mapping.(parent_index)
          else begin
            let i = !blob_count in
            mapping.(parent_index) <- i;
            blobs := p.blobs.(parent_index) :: !blobs;
            incr blob_count;
            i
          end
        in
        tiles.(!out) <- (id, index);
        incr out
      end)
    p.tiles;
  let tiles = Array.sub tiles 0 !out in
  let blobs = Array.of_list (List.rev !blobs) in
  let total_bytes =
    Array.fold_left (fun acc (_, _, length) -> acc + length) 0 blobs
  in
  let fetch_bytes =
    Array.fold_left
      (fun acc (origin, _, length) ->
        match origin with Fresh -> acc + length | Base -> acc)
      0 blobs
  in
  let fresh_tiles =
    Array.fold_left
      (fun acc (_, index) ->
        let origin, _, _ = blobs.(index) in
        match origin with Fresh -> acc + 1 | Base -> acc)
      0 tiles
  in
  ( { blobs; tiles; fetch_bytes; total_bytes; fresh_tiles; refreshed_tiles = 0 },
    mapping )

(* [copy] is handed [index], the blob's position in [p.blobs], as well as
   where to read it from. The index is what lets a caller attribute bytes to
   whatever it decided that blob belongs to -- the download uses it to say
   which REGION each blob was fetched for, which cannot be recovered from the
   offset alone once the merge has deduplicated across regions. Blobs are
   copied in ascending index order, but a caller that needs the index should
   take it from here rather than counting calls: the order is [write_tiles]'s
   business, not part of this contract. *)
let write ?metadata (p : plan) (source : Header.t) ~min_zoom ~max_zoom
    ~min_lon ~min_lat ~max_lon ~max_lat ~append ~copy =
  Extract.write_tiles ?metadata ~source ~min_zoom ~max_zoom ~min_lon ~min_lat
    ~max_lon ~max_lat ~tiles:p.tiles
    ~blob_lengths:(Array.map (fun (_, _, length) -> length) p.blobs)
    ~append
    ~copy_blob:(fun i ->
      let origin, offset, length = p.blobs.(i) in
      copy ~index:i ~origin ~offset ~length)
    ()
