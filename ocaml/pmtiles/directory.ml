(* PMTiles directories: a sorted run of entries, varint-coded in four columns.

   Columns rather than records, because each column then delta-encodes well --
   tile IDs are ascending, and in a clustered archive offsets usually follow
   on from the previous entry's length, which the format spells as a literal
   zero.

   An entry with run_length = 0 is not a tile. It points at a leaf directory,
   which is how an archive with millions of tiles keeps a root directory small
   enough to fetch in one request. *)

type entry = {
  tile_id : int;
  offset : int;
  length : int;
  run_length : int;  (** 0 marks a pointer to a leaf directory *)
}

let is_leaf_pointer e = e.run_length = 0

(* Entries are stored sorted by tile_id, and every lookup and every merge
   below relies on that, so it is asserted at the boundary rather than hoped
   for. *)
let deserialize s =
  let n, pos = Varint.decode s 0 in
  let entries = Array.make n { tile_id = 0; offset = 0; length = 0; run_length = 0 } in
  let pos = ref pos in

  let last = ref 0 in
  for i = 0 to n - 1 do
    let delta, p = Varint.decode s !pos in
    pos := p;
    last := !last + delta;
    entries.(i) <- { (entries.(i)) with tile_id = !last }
  done;
  for i = 0 to n - 1 do
    let v, p = Varint.decode s !pos in
    pos := p;
    entries.(i) <- { (entries.(i)) with run_length = v }
  done;
  for i = 0 to n - 1 do
    let v, p = Varint.decode s !pos in
    pos := p;
    entries.(i) <- { (entries.(i)) with length = v }
  done;
  for i = 0 to n - 1 do
    let v, p = Varint.decode s !pos in
    pos := p;
    (* Zero is not offset zero: it means "immediately after the previous
       entry", which is how a clustered archive avoids storing an absolute
       offset per tile. *)
    let offset =
      if v = 0 && i > 0 then entries.(i - 1).offset + entries.(i - 1).length
      else v - 1
    in
    entries.(i) <- { (entries.(i)) with offset }
  done;
  entries

let serialize entries =
  let n = Array.length entries in
  let b = Buffer.create (n * 8) in
  Varint.encode b n;
  let last = ref 0 in
  Array.iter
    (fun e ->
      Varint.encode b (e.tile_id - !last);
      last := e.tile_id)
    entries;
  Array.iter (fun e -> Varint.encode b e.run_length) entries;
  Array.iter (fun e -> Varint.encode b e.length) entries;
  Array.iteri
    (fun i e ->
      if i > 0 && e.offset = entries.(i - 1).offset + entries.(i - 1).length then
        Varint.encode b 0
      else Varint.encode b (e.offset + 1))
    entries;
  Buffer.contents b

(* The entry covering [tile_id], if any.

   Binary search over a sorted array, then a run check: one entry can stand
   for a run of consecutive tile IDs that share identical content, which is
   how an archive stores a thousand identical ocean tiles once. *)
let find entries tile_id =
  let lo = ref 0 and hi = ref (Array.length entries - 1) in
  let exact = ref None in
  while !exact = None && !lo <= !hi do
    let mid = (!lo + !hi) / 2 in
    let cmp = tile_id - entries.(mid).tile_id in
    if cmp > 0 then lo := mid + 1
    else if cmp < 0 then hi := mid - 1
    else exact := Some entries.(mid)
  done;
  match !exact with
  | Some e -> Some e
  | None when !hi >= 0 ->
      (* hi now indexes the largest entry below the target. It answers for the
         target if it is a leaf pointer, or if its run reaches that far. *)
      let e = entries.(!hi) in
      if e.run_length = 0 then Some e
      else if tile_id - e.tile_id < e.run_length then Some e
      else None
  | None -> None
