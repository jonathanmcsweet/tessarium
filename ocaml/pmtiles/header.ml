(* The PMTiles v3 header: 127 fixed bytes, little-endian, at offset 0.

   Spec: https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md *)

type compression = Unknown | None_ | Gzip | Brotli | Zstd
type tile_type = Type_unknown | Mvt | Png | Jpeg | Webp | Avif

type t = {
  root_offset : int;
  root_length : int;
  metadata_offset : int;
  metadata_length : int;
  leaf_offset : int;
  leaf_length : int;
  data_offset : int;
  data_length : int;
  addressed_tiles : int;
  tile_entries : int;
  tile_contents : int;
  clustered : bool;
  internal_compression : compression;
  tile_compression : compression;
  tile_type : tile_type;
  min_zoom : int;
  max_zoom : int;
  (* Degrees x 10^7, as the format stores them. *)
  min_lon_e7 : int;
  min_lat_e7 : int;
  max_lon_e7 : int;
  max_lat_e7 : int;
  center_zoom : int;
  center_lon_e7 : int;
  center_lat_e7 : int;
}

let size = 127
let magic = "PMTiles"

let compression_of_int = function
  | 0 -> Unknown
  | 1 -> None_
  | 2 -> Gzip
  | 3 -> Brotli
  | 4 -> Zstd
  | n -> invalid_arg (Printf.sprintf "pmtiles: unknown compression %d" n)

let int_of_compression = function
  | Unknown -> 0
  | None_ -> 1
  | Gzip -> 2
  | Brotli -> 3
  | Zstd -> 4

let tile_type_of_int = function
  | 0 -> Type_unknown
  | 1 -> Mvt
  | 2 -> Png
  | 3 -> Jpeg
  | 4 -> Webp
  | 5 -> Avif
  | n -> invalid_arg (Printf.sprintf "pmtiles: unknown tile type %d" n)

let int_of_tile_type = function
  | Type_unknown -> 0
  | Mvt -> 1
  | Png -> 2
  | Jpeg -> 3
  | Webp -> 4
  | Avif -> 5

(* uint64 read into a native int. Every field that uses this is an offset or a
   count within one archive; the largest real value is around 10^11 against a
   63-bit int, so the cast is safe and the check makes that explicit rather
   than assumed. *)
let u64 s pos =
  let v = String.get_int64_le s pos in
  if Int64.compare v 0L < 0 || Int64.compare v (Int64.of_int max_int) > 0 then
    invalid_arg "pmtiles: field exceeds native int"
  else Int64.to_int v

let i32 s pos = Int32.to_int (String.get_int32_le s pos)
let u8 s pos = Char.code s.[pos]

let parse s =
  if String.length s < size then invalid_arg "pmtiles: header truncated";
  if String.sub s 0 7 <> magic then invalid_arg "pmtiles: bad magic";
  let version = u8 s 7 in
  if version <> 3 then
    invalid_arg (Printf.sprintf "pmtiles: version %d, expected 3" version);
  {
    root_offset = u64 s 8;
    root_length = u64 s 16;
    metadata_offset = u64 s 24;
    metadata_length = u64 s 32;
    leaf_offset = u64 s 40;
    leaf_length = u64 s 48;
    data_offset = u64 s 56;
    data_length = u64 s 64;
    addressed_tiles = u64 s 72;
    tile_entries = u64 s 80;
    tile_contents = u64 s 88;
    clustered = u8 s 96 = 1;
    internal_compression = compression_of_int (u8 s 97);
    tile_compression = compression_of_int (u8 s 98);
    tile_type = tile_type_of_int (u8 s 99);
    min_zoom = u8 s 100;
    max_zoom = u8 s 101;
    min_lon_e7 = i32 s 102;
    min_lat_e7 = i32 s 106;
    max_lon_e7 = i32 s 110;
    max_lat_e7 = i32 s 114;
    center_zoom = u8 s 118;
    center_lon_e7 = i32 s 119;
    center_lat_e7 = i32 s 123;
  }

let serialize h =
  let b = Bytes.make size '\000' in
  Bytes.blit_string magic 0 b 0 7;
  Bytes.set b 7 '\003';
  let put64 pos v = Bytes.set_int64_le b pos (Int64.of_int v) in
  let put32 pos v = Bytes.set_int32_le b pos (Int32.of_int v) in
  let put8 pos v = Bytes.set b pos (Char.chr (v land 0xff)) in
  put64 8 h.root_offset;
  put64 16 h.root_length;
  put64 24 h.metadata_offset;
  put64 32 h.metadata_length;
  put64 40 h.leaf_offset;
  put64 48 h.leaf_length;
  put64 56 h.data_offset;
  put64 64 h.data_length;
  put64 72 h.addressed_tiles;
  put64 80 h.tile_entries;
  put64 88 h.tile_contents;
  put8 96 (if h.clustered then 1 else 0);
  put8 97 (int_of_compression h.internal_compression);
  put8 98 (int_of_compression h.tile_compression);
  put8 99 (int_of_tile_type h.tile_type);
  put8 100 h.min_zoom;
  put8 101 h.max_zoom;
  put32 102 h.min_lon_e7;
  put32 106 h.min_lat_e7;
  put32 110 h.max_lon_e7;
  put32 114 h.max_lat_e7;
  put8 118 h.center_zoom;
  put32 119 h.center_lon_e7;
  put32 123 h.center_lat_e7;
  Bytes.to_string b
