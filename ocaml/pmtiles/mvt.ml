(* Just enough Mapbox Vector Tile to read names off a tile.

   Not a general MVT library and not trying to be: nothing here draws, and
   geometry is decoded only far enough to place a label somewhere sensible.
   What this exists for is the offline place index -- a downloaded region
   already carries every place and street name it can display, and searching
   it must never mean asking a geocoder where the user is looking.

   The format is protobuf without a schema compiler, which is workable
   because the parts we need are shallow: a tile is layers, a layer is
   features plus two string tables, a feature is tag indices into those
   tables and a run of geometry commands. Unknown fields are skipped by wire
   type, so a tile carrying more than this understands still reads. *)

type value = Str of string | Num of float | Bool of bool

type feature = {
  name : string;  (** the [name] tag, empty when the feature has none *)
  kind : string;  (** the [kind] tag: locality, street, ... *)
  weight : float;
      (** the [population] tag where the basemap carries one. It is what
          separates Paris from the eleven other places called Paris, so a
          search can offer the one the user meant first. *)
  x : float;  (** tile-local, in extent units *)
  y : float;
}

(* ------------------------------------------------------------- protobuf *)

exception Malformed of string

let fail what = raise (Malformed what)

let varint s pos =
  if pos >= String.length s then fail "varint past the end"
  else try Varint.decode s pos with Invalid_argument m -> fail m

(* A length-delimited field: its bytes, and where the next field starts. *)
let bytes_of s pos =
  let len, pos = varint s pos in
  if len < 0 || pos + len > String.length s then fail "length past the end";
  (String.sub s pos len, pos + len)

let skip s pos wire =
  match wire with
  | 0 -> snd (varint s pos)
  | 1 -> if pos + 8 > String.length s then fail "fixed64 past the end" else pos + 8
  | 2 -> snd (bytes_of s pos)
  | 5 -> if pos + 4 > String.length s then fail "fixed32 past the end" else pos + 4
  | w -> fail (Printf.sprintf "wire type %d" w)

(* Walks the fields of a message, handing each to [f] as (field, wire, pos)
   and taking back the position after it. *)
let fields s f =
  let n = String.length s in
  let rec go pos =
    if pos >= n then ()
    else
      let k, pos' = varint s pos in
      let field = k lsr 3 and wire = k land 7 in
      go (f ~field ~wire ~pos:pos')
  in
  go 0

let float_of_bits32 s pos =
  Int32.float_of_bits (String.get_int32_le s pos)

let float_of_bits64 s pos =
  Int64.float_of_bits (String.get_int64_le s pos)

(* zigzag, as protobuf sint and MVT geometry both use *)
let zigzag n = (n lsr 1) lxor -(n land 1)

(* ---------------------------------------------------------------- value *)

let parse_value s =
  let out = ref None in
  fields s (fun ~field ~wire ~pos ->
      match (field, wire) with
      | 1, 2 ->
          let v, pos = bytes_of s pos in
          out := Some (Str v);
          pos
      | 2, 5 ->
          out := Some (Num (float_of_bits32 s pos));
          pos + 4
      | 3, 1 ->
          out := Some (Num (float_of_bits64 s pos));
          pos + 8
      | (4 | 5), 0 ->
          let v, pos = varint s pos in
          out := Some (Num (float_of_int v));
          pos
      | 6, 0 ->
          let v, pos = varint s pos in
          out := Some (Num (float_of_int (zigzag v)));
          pos
      | 7, 0 ->
          let v, pos = varint s pos in
          out := Some (Bool (v <> 0));
          pos
      | _ -> skip s pos wire);
  !out

(* -------------------------------------------------------------- geometry *)

(* One point standing for the whole feature: the first vertex of a point or
   line, and for a polygon the first vertex of its outer ring. Good enough to
   fly a map to, which is all a search result has to do -- a true centroid
   would mean carrying ring orientation and area, for a label that would move
   by a few pixels. *)
let first_point geometry =
  let n = String.length geometry in
  let rec go pos =
    if pos >= n then None
    else
      let cmd, pos = varint geometry pos in
      let op = cmd land 7 and count = cmd lsr 3 in
      if op = 1 && count >= 1 then
        (* MoveTo: the first pair is absolute, being relative to (0,0) *)
        let dx, pos = varint geometry pos in
        let dy, _ = varint geometry pos in
        Some (float_of_int (zigzag dx), float_of_int (zigzag dy))
      else if op = 7 then go pos
      else
        (* Skip this command's operands: two varints per point. *)
        let rec drop k pos =
          if k = 0 then pos else drop (k - 1) (snd (varint geometry pos))
        in
        go (drop (count * 2) pos)
  in
  go 0

(* --------------------------------------------------------------- layers *)

type layer = { layer_name : string; extent : int; features : feature list }

let parse_layer s =
  let name = ref "" and extent = ref 4096 in
  let keys = ref [] and values = ref [] and raw_features = ref [] in
  fields s (fun ~field ~wire ~pos ->
      match (field, wire) with
      | 1, 2 ->
          let v, pos = bytes_of s pos in
          name := v;
          pos
      | 2, 2 ->
          let v, pos = bytes_of s pos in
          raw_features := v :: !raw_features;
          pos
      | 3, 2 ->
          let v, pos = bytes_of s pos in
          keys := v :: !keys;
          pos
      | 4, 2 ->
          let v, pos = bytes_of s pos in
          values := parse_value v :: !values;
          pos
      | 5, 0 ->
          let v, pos = varint s pos in
          extent := (if v > 0 then v else 4096);
          pos
      | _ -> skip s pos wire);
  let keys = Array.of_list (List.rev !keys) in
  let values = Array.of_list (List.rev !values) in
  let number_tag tags want =
    let rec go = function
      | k :: v :: rest ->
          if k < Array.length keys && keys.(k) = want then
            match if v < Array.length values then values.(v) else None with
            | Some (Num n) -> n
            | _ -> go rest
          else go rest
      | _ -> 0.
    in
    go tags
  in
  let string_tag tags want =
    (* tags are (key index, value index) pairs *)
    let rec go = function
      | k :: v :: rest ->
          if k < Array.length keys && keys.(k) = want then
            match if v < Array.length values then values.(v) else None with
            | Some (Str s) -> s
            | _ -> go rest
          else go rest
      | _ -> ""
    in
    go tags
  in
  let parse_feature s =
    let tags = ref [] and geometry = ref "" in
    fields s (fun ~field ~wire ~pos ->
        match (field, wire) with
        | 2, 2 ->
            let packed, pos = bytes_of s pos in
            let rec unpack p acc =
              if p >= String.length packed then List.rev acc
              else
                let v, p = varint packed p in
                unpack p (v :: acc)
            in
            tags := unpack 0 [];
            pos
        | 2, 0 ->
            let v, pos = varint s pos in
            tags := !tags @ [ v ];
            pos
        | 4, 2 ->
            let v, pos = bytes_of s pos in
            geometry := v;
            pos
        | _ -> skip s pos wire);
    match first_point !geometry with
    | None -> None
    | Some (x, y) ->
        let name = string_tag !tags "name" in
        if name = "" then None
        else
          Some
            {
              name;
              kind = string_tag !tags "kind";
              weight = number_tag !tags "population";
              x;
              y;
            }
  in
  {
    layer_name = !name;
    extent = !extent;
    features = List.filter_map parse_feature (List.rev !raw_features);
  }

let layers tile =
  let out = ref [] in
  fields tile (fun ~field ~wire ~pos ->
      match (field, wire) with
      | 3, 2 ->
          let v, pos = bytes_of tile pos in
          out := parse_layer v :: !out;
          pos
      | _ -> skip tile pos wire);
  List.rev !out

(* ------------------------------------------------------------ geography *)

(* Tile-local coordinates to degrees. The inverse of the Web Mercator
   projection the tiles were cut with; [Tile_id] goes the other way and this
   has to agree with it or a search result lands in the wrong place. *)
let lon_lat ~z ~x ~y ~extent ~px ~py =
  let n = float_of_int (1 lsl z) in
  let fx = (float_of_int x +. (px /. float_of_int extent)) /. n in
  let fy = (float_of_int y +. (py /. float_of_int extent)) /. n in
  let lon = (fx *. 360.) -. 180. in
  let lat_rad = atan (sinh (Float.pi *. (1. -. (2. *. fy)))) in
  (lon, lat_rad *. 180. /. Float.pi)

(* Every named feature in a tile, placed on Earth. *)
let named ~z ~x ~y tile =
  List.concat_map
    (fun l ->
      List.map
        (fun f ->
          let lon, lat =
            lon_lat ~z ~x ~y ~extent:l.extent ~px:f.x ~py:f.y
          in
          (l.layer_name, f.name, f.kind, f.weight, lon, lat))
        l.features)
    (layers tile)
