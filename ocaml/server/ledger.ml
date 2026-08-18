(* The download ledger: which regions this archive was asked to hold, so
   each can be listed, brought up to date, or removed later.

   It lives inside map.pmtiles itself, in the archive's metadata section, so
   the one atomic rename that publishes tiles publishes their record in the
   same instant -- there is no sidecar file to drift, and no crash window in
   which the ledger describes tiles that are not on disk.

   Everything here is pure and deterministic, deliberately: serialization
   uses a fixed key order and compact form so the same ledger is the same
   bytes; an entry's identity is derived from its regions alone, so the same
   request is the same entry no matter when or in what order it was made;
   and there is no clock -- callers pass time in. Corruption is loud: a
   metadata blob this module cannot read exactly is an error, never an
   empty ledger, because silently forgetting what a gigabyte archive holds
   is worse than refusing to touch it. *)

type entry = {
  name : string;  (** what the picker called it; display only *)
  regions : Basemap_job.request list;
      (** canonically sorted, never empty. Depths are as GRANTED, not as
          asked: a clamped giant records the zoom it actually fetched, so
          Remove and Update speak of tiles that exist. *)
  completed : int;
      (** when the download that made or refreshed this entry finished, in
          epoch seconds; zero when the tiles predate the ledger and their
          age is unknown. Tiles already held were deliberately not
          re-fetched then -- their age belongs to the entries that fetched
          them -- and a resumed download records the resuming run. *)
  source : string;  (** the resolved archive it was fetched from *)
  bytes : int;
      (** bytes actually fetched from the source by the download that made
          this entry -- the number the estimate quoted, not the archive
          bytes copied while merging *)
}

type t = entry list

let metadata_key = "tessarium_ledger"
let version = 1

(* ------------------------------------------------------------- identity *)

(* Regions are kept sorted so that picking the same places in a different
   order produces the same entry, not a twin. Polymorphic compare is safe
   here: requests are floats, ints and arrays, all validated finite. *)
let region_key (r : Basemap_job.request) =
  (r.min_lon, r.min_lat, r.max_lon, r.max_lat, r.max_zoom, r.polygon)

(* Stable, so regions that compare equal keep their arrival order and the
   serialized bytes cannot depend on the sort's whims. *)
let sort_regions =
  List.stable_sort (fun a b -> compare (region_key a) (region_key b))

(* Negative zero prints as "-0.0000000" but compares equal to zero, which
   would give one region two identities. It is the same bound; normalise. *)
let pos v = v +. 0.

(* The identity text is built with a fixed float format rather than from the
   JSON, so the id survives any serialization change. 1e-7 degrees is about
   a centimetre -- regions closer than that are the same region. *)
let canonical_text regions =
  let b = Buffer.create 256 in
  List.iter
    (fun (r : Basemap_job.request) ->
      Buffer.add_string b
        (Printf.sprintf "%.7f,%.7f,%.7f,%.7f,%d" (pos r.min_lon)
           (pos r.min_lat) (pos r.max_lon) (pos r.max_lat) r.max_zoom);
      (match r.polygon with
      | None -> ()
      | Some rings ->
          Array.iter
            (fun ring ->
              Buffer.add_char b '|';
              Array.iter
                (fun (x, y) ->
                  Buffer.add_string b
                    (Printf.sprintf "%.7f,%.7f;" (pos x) (pos y)))
                ring)
            rings);
      Buffer.add_char b '\n')
    regions;
  Buffer.contents b

let id e =
  String.sub
    Digestif.SHA256.(to_hex (digest_string (canonical_text e.regions)))
    0 12

(* The only constructor: sorting here is what makes [id] order-blind. *)
let make ~name ~regions ~completed ~source ~bytes =
  { name; regions = sort_regions regions; completed; source; bytes }

(* --------------------------------------------------------------- names *)

(* Client-supplied and stored, so bounded and printable. Multi-byte UTF-8 is
   welcome -- the picker speaks six locales -- but a name that is not UTF-8
   would come back out of Yojson as invalid JSON, and invisible characters
   (C0/C1 controls, zero-width, bidi overrides) exist mostly to make one
   string display as another, so both die here. *)
let max_name_bytes = 120

let visible_uchar u =
  not
    (u < 0x20
    || (u >= 0x7f && u <= 0x9f)
    || (u >= 0x200b && u <= 0x200f)
    || (u >= 0x202a && u <= 0x202e)
    || (u >= 0x2066 && u <= 0x2069)
    || u = 0xfeff)

let valid_name s =
  String.length s > 0
  && String.length s <= max_name_bytes
  && String.is_valid_utf_8 s
  &&
  let ok = ref true in
  let i = ref 0 in
  while !ok && !i < String.length s do
    let d = String.get_utf_8_uchar s !i in
    if not (visible_uchar (Uchar.to_int (Uchar.utf_decode_uchar d))) then
      ok := false;
    i := !i + Uchar.utf_decode_length d
  done;
  !ok

(* ---------------------------------------------------------------- edits *)

let find t ~id:wanted = List.find_opt (fun e -> id e = wanted) t

(* Same regions replace their entry in place -- a re-download or update is
   the same map, newer -- and a new region appends, so the list reads in
   the order things were first downloaded. *)
let record t e =
  let eid = id e in
  if List.exists (fun e' -> id e' = eid) t then
    List.map (fun e' -> if id e' = eid then e else e') t
  else t @ [ e ]

let remove t ~id:wanted =
  match find t ~id:wanted with
  | None -> None
  | Some e -> Some (e, List.filter (fun e' -> id e' <> wanted) t)

(* ------------------------------------------------------------ coverage *)

(* Geometry for Remove, precomputed once because it runs per tile over
   millions. The rule is that Remove undoes the download: a tile is dropped
   exactly when the removed entry's download would have fetched it -- every
   tile its region touches, down to the zoom it asked for, which is
   precisely the covering the planner walks -- and no kept entry's download
   would fetch it too. Symmetric on both sides, so removing one region can
   never punch a hole in another recorded download, and removing the last
   entry takes with it exactly what its download brought. *)

type prepared = {
  max_zoom : int;
  box : float * float * float * float;
  clip : Pmtiles.Clip.t option;
}

let prepare (r : Basemap_job.request) =
  {
    max_zoom = r.max_zoom;
    box = (r.min_lon, r.min_lat, r.max_lon, r.max_lat);
    clip = Option.map Pmtiles.Clip.of_rings r.polygon;
  }

(* Whether this region's download fetches the tile: exactly the planner's
   covering, restated as a membership test. The x/y range uses the same
   floor arithmetic [Tile_id.covering] does -- a geometric edge-touch test
   would claim the west and north neighbours of a tile-aligned box, which
   the covering never fetches -- and a clipped region is that grid
   intersected with its polygon, border tiles included, as [clip_walk]
   walks it. *)
let fetches p ~z ~x ~y =
  z <= p.max_zoom
  &&
  let bl, bb, br, bt = p.box in
  let last = (1 lsl z) - 1 in
  let grid v = max 0 (min last v) in
  x >= grid (Pmtiles.Tile_id.tile_x ~z ~lon:bl)
  && x <= grid (Pmtiles.Tile_id.tile_x ~z ~lon:br)
  && y >= grid (Pmtiles.Tile_id.tile_y ~z ~lat:bt)
  && y <= grid (Pmtiles.Tile_id.tile_y ~z ~lat:bb)
  &&
  match p.clip with
  | None -> true
  | Some clip ->
      let l, b, r, t = Pmtiles.Tile_id.tile_box ~z ~x ~y in
      Pmtiles.Clip.classify clip ~min_x:l ~min_y:b ~max_x:r ~max_y:t
      <> Pmtiles.Clip.Outside

(* [drops ~removed ~kept] decides one tile's fate during a Remove rewrite. *)
let drops ~(removed : entry) ~(kept : t) =
  let gone = List.map prepare removed.regions in
  let stays = List.concat_map (fun e -> List.map prepare e.regions) kept in
  fun ~z ~x ~y ->
    List.exists (fun p -> fetches p ~z ~x ~y) gone
    && not (List.exists (fun p -> fetches p ~z ~x ~y) stays)

(* -------------------------------------------------------------- to JSON *)

let json_of_region (r : Basemap_job.request) : Yojson.Safe.t =
  let box =
    [
      ("min_lon", `Float r.min_lon);
      ("min_lat", `Float r.min_lat);
      ("max_lon", `Float r.max_lon);
      ("max_lat", `Float r.max_lat);
      ("max_zoom", `Int r.max_zoom);
    ]
  in
  match r.polygon with
  | None -> `Assoc box
  | Some rings ->
      let ring_json ring =
        `List
          (Array.to_list ring
          |> List.map (fun (x, y) -> `List [ `Float x; `Float y ]))
      in
      `Assoc
        (box
        @ [ ("polygon", `List (Array.to_list rings |> List.map ring_json)) ])

let json_of_entry e : Yojson.Safe.t =
  `Assoc
    [
      ("name", `String e.name);
      ("completed", `Int e.completed);
      ("source", `String e.source);
      ("bytes", `Int e.bytes);
      ("regions", `List (List.map json_of_region e.regions));
    ]

let to_json (t : t) : Yojson.Safe.t =
  `Assoc [ ("v", `Int version); ("entries", `List (List.map json_of_entry t)) ]

(* ------------------------------------------------------------ from JSON *)

let ( let* ) = Result.bind

let number = function
  | `Int i -> Ok (float_of_int i)
  | `Float f -> Ok f
  | _ -> Error "expected a number"

let field name fields =
  match List.assoc_opt name fields with
  | Some v -> Ok v
  | None -> Error (Printf.sprintf "missing %S" name)

let point = function
  | `List [ x; y ] ->
      let* x = number x in
      let* y = number y in
      Ok (x, y)
  | _ -> Error "a polygon point must be [lon, lat]"

let all f l =
  List.fold_left
    (fun acc v ->
      let* acc = acc in
      let* v = f v in
      Ok (v :: acc))
    (Ok []) l
  |> Result.map List.rev

let region_of_json = function
  | `Assoc fields ->
      let* min_lon = Result.bind (field "min_lon" fields) number in
      let* min_lat = Result.bind (field "min_lat" fields) number in
      let* max_lon = Result.bind (field "max_lon" fields) number in
      let* max_lat = Result.bind (field "max_lat" fields) number in
      let* max_zoom =
        match field "max_zoom" fields with
        | Ok (`Int z) -> Ok z
        | Ok _ -> Error "max_zoom must be an integer"
        | Error _ as e -> e
      in
      let* polygon =
        match List.assoc_opt "polygon" fields with
        | None -> Ok None
        | Some (`List rings) ->
            let* rings =
              all
                (function
                  | `List pts ->
                      let* pts = all point pts in
                      Ok (Array.of_list pts)
                  | _ -> Error "a polygon ring must be a list of points")
                rings
            in
            Ok (Some (Array.of_list rings))
        | Some _ -> Error "polygon must be a list of rings"
      in
      (* Stored regions were validated when they arrived; validating again on
         the way back in is how ledger corruption gets caught instead of
         planned against. *)
      Basemap_job.validate ?polygon ~min_lon ~min_lat ~max_lon ~max_lat
        ~max_zoom ()
  | _ -> Error "a region must be an object"

let entry_of_json = function
  | `Assoc fields ->
      let* name =
        match field "name" fields with
        | Ok (`String s) when valid_name s -> Ok s
        | Ok _ -> Error "entry name is invalid"
        | Error _ as e -> e
      in
      let* completed =
        match field "completed" fields with
        | Ok (`Int s) when s >= 0 -> Ok s
        | Ok _ -> Error "completed must be a non-negative integer"
        | Error _ as e -> e
      in
      let* source =
        match field "source" fields with
        | Ok (`String s) -> Ok s
        | Ok _ -> Error "source must be a string"
        | Error _ as e -> e
      in
      let* bytes =
        match field "bytes" fields with
        | Ok (`Int b) when b >= 0 -> Ok b
        | Ok _ -> Error "bytes must be a non-negative integer"
        | Error _ as e -> e
      in
      let* regions =
        match field "regions" fields with
        | Ok (`List (_ :: _ as l)) -> all region_of_json l
        | Ok _ -> Error "regions must be a non-empty list"
        | Error _ as e -> e
      in
      Ok (make ~name ~regions ~completed ~source ~bytes)
  | _ -> Error "an entry must be an object"

let of_json = function
  | `Assoc fields -> (
      match List.assoc_opt "v" fields with
      | Some (`Int v) when v = version -> (
          match List.assoc_opt "entries" fields with
          | Some (`List l) -> all entry_of_json l
          | _ -> Error "ledger has no entries list"
      )
      | Some (`Int v) ->
          Error
            (Printf.sprintf
               "ledger version %d is newer than this server understands" v)
      | _ -> Error "ledger has no version")
  | _ -> Error "ledger must be an object"

(* ------------------------------------------------- archive metadata I/O *)

let wrap e = Printf.sprintf "the archive's download ledger is unreadable: %s" e

let duplicated fields =
  List.length (List.filter (fun (k, _) -> String.equal k metadata_key) fields)
  > 1

(* An archive with no ledger key has an empty ledger -- that is every
   archive written before this feature, and every fresh extract. Anything
   else that fails to parse is corruption and says so -- including a ledger
   key that appears twice, which reads and writes would otherwise resolve
   differently from each other. *)
let of_metadata s =
  match Yojson.Safe.from_string s with
  | exception _ -> Error (wrap "archive metadata is not JSON")
  | `Assoc fields when duplicated fields ->
      Error (wrap "the ledger key appears more than once")
  | `Assoc fields -> (
      match List.assoc_opt metadata_key fields with
      | None -> Ok []
      | Some j -> Result.map_error wrap (of_json j))
  | _ -> Error (wrap "archive metadata is not an object")

(* Writes preserve every other metadata key in its original position. An
   empty ledger removes the key entirely, so an archive whose last entry
   was removed is byte-identical to one that never had any. *)
let to_metadata (t : t) ~previous =
  match Yojson.Safe.from_string previous with
  | exception _ -> Error (wrap "archive metadata is not JSON")
  | `Assoc fields when duplicated fields ->
      Error (wrap "the ledger key appears more than once")
  | `Assoc fields ->
      let without = List.remove_assoc metadata_key fields in
      let fields' =
        if t = [] then without
        else if List.mem_assoc metadata_key fields then
          List.map
            (fun (k, v) ->
              if String.equal k metadata_key then (k, to_json t) else (k, v))
            fields
        else fields @ [ (metadata_key, to_json t) ]
      in
      Ok (Yojson.Safe.to_string (`Assoc fields'))
  | _ -> Error (wrap "archive metadata is not an object")
