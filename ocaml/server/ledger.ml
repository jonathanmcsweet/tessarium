(* The download ledger: which regions this archive was asked to hold, so each
   can be listed, updated or removed later.

   It lives inside the archive's own metadata, so the single rename that
   publishes tiles publishes their record at the same instant. There is no
   sidecar file to drift, and no crash window where the ledger describes
   tiles that are not on disk.

   A region's archive is its own file, so its ledger is one entry long and
   travels with it: a machine handed nothing but the file can say what it
   was handed. What the user sees is the union of every such file. Only the
   old merged map.pmtiles holds several entries at once, which is why this is
   a list and not a record.

   Everything here is pure and deterministic on purpose. Serialization uses a
   fixed key order and compact form, so the same ledger is the same bytes. An
   entry's identity comes from its regions alone, so the same request is the
   same entry whenever and in whatever order it was made. There is no clock;
   callers pass time in. And corruption is loud: metadata this module cannot
   read exactly is an error, never an empty ledger, because silently
   forgetting what a gigabyte archive holds is worse than refusing to touch
   it. *)

type entry = {
  name : string;  (** what the picker called it; display only *)
  regions : Basemap_job.request list;
      (** canonically sorted, never empty. Depths are as GRANTED, not as
          asked: a clamped giant records the zoom it actually fetched, so
          Remove and Update speak of tiles that exist. *)
  completed : int;
      (** when the download that made or refreshed this entry finished, in
          epoch seconds. Zero when the tiles predate the ledger and their
          age is unknown, which the UI draws as "needs updating".

          Every download dates itself, interrupted ones included. What an
          interrupted region is missing is a question the map's coverage
          shading already answers, and dating by the last part to write
          would have called finished downloads unfinished: the parts overlap
          at their seams, so the last one routinely writes nothing. Tiles
          already held were not re-fetched, so their age belongs to the
          entries that fetched them, and a resumed download records the
          resuming run. *)
  source : string;  (** the resolved archive it was fetched from *)
  bytes : int;
      (** bytes actually fetched from the source by the download that made
          this entry -- the number the estimate quoted, not the archive
          bytes copied while merging *)
}

type t = entry list

(* Names a blob inside the PMTiles archive. It was renamed with the project,
   so an archive downloaded before that uses the old name. Such an archive is
   REFUSED rather than read as empty -- see [foreign] below -- because
   silently forgetting what a gigabyte archive holds is the one failure this
   feature must never have. Re-download if you have one. *)
let metadata_key = "tessarium_ledger"
let version = 1

(* ------------------------------------------------------------- identity *)

(* Regions are sorted so picking the same places in a different order gives
   the same entry, not a twin. Polymorphic compare is safe here: a request is
   floats, ints and arrays, all validated finite. *)
let region_key (r : Basemap_job.request) =
  (r.min_lon, r.min_lat, r.max_lon, r.max_lat, r.max_zoom, r.polygon)

(* Stable, so equal regions keep their arrival order and the serialized bytes
   do not depend on how the sort happens to break ties. *)
let sort_regions =
  List.stable_sort (fun a b -> compare (region_key a) (region_key b))

(* Negative zero prints as "-0.0000000" but compares equal to zero, so one
   bound would give a region two identities. Normalise it away. *)
let pos v = v +. 0.

(* Built with a fixed float format rather than from the JSON, so the id
   survives a serialization change. 1e-7 degrees is about a centimetre;
   regions closer than that are the same region. *)
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

(* The only constructor. Sorting here is what makes [id] order-blind. *)
let make ~name ~regions ~completed ~source ~bytes =
  { name; regions = sort_regions regions; completed; source; bytes }

(* --------------------------------------------------------------- names *)

(* An entry's name follows the same rule a region's label does, from the same
   function: see [Basemap_job.valid_name] for what it refuses and why.
   Aliased rather than copied, and it lives there because a region carries a
   label of its own and regions are defined there. *)
let max_name_bytes = Basemap_job.max_name_bytes
let valid_name = Basemap_job.valid_name

(* ---------------------------------------------------------------- edits *)

(* Finding an entry by id, which is all that is left of editing a ledger.

   [record] and [remove] used to sit here, adding an entry to a list and
   taking one out. A region is its own file now: a download writes a
   one-entry ledger inside the archive it just wrote, and removing a region
   unlinks the file, ledger and all. Nothing adds to or subtracts from a list
   any more, and the code that did sat behind a guard that refuses to rewrite
   the base archive, so it could never run. *)
let find t ~id:wanted = List.find_opt (fun e -> id e = wanted) t

(* ------------------------------------------------------------ coverage *)

(* Geometry for Remove, precomputed once because it runs per tile over
   millions of them.

   Remove undoes the download. A tile is dropped when the removed entry's
   download would have fetched it -- every tile its region touches, down to
   the zoom it asked for, which is the covering the planner walks -- and no
   kept entry's download would fetch it too. The same test on both sides, so
   removing one region cannot punch a hole in another recorded download, and
   removing the last entry takes exactly what its download brought. *)

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

(* Whether this region's download fetches the tile: the planner's covering,
   restated as a membership test. The x/y range uses the same floor
   arithmetic [Tile_id.covering] does, because a geometric edge-touch test
   would claim the west and north neighbours of a tile-aligned box, which the
   covering never fetches. A clipped region is that grid intersected with its
   polygon, border tiles included, the way [clip_walk] walks it. *)
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

(* Do these regions span the planet?

   One predicate, with the slack as an argument, because two locks ask this
   and they have to answer alike. The lenient reading below decides whether
   an entry in the old merged archive is the map everything else stands on
   and so cannot be removed. The exact reading, margin zero, decides whether
   a download claiming to be a world overview may be written to
   world.pmtiles. They used to be two functions with two thresholds, so a box
   starting at -179.5 longitude was the world to one and not to the other.

   Judged by what the regions say they cover, never by a name: names are
   display only, and the row the user is looking at may read "Map view". It
   takes one region, no clipping polygon, and a box reaching the ends of the
   usable projection.

   [margin] is how far short of those ends still counts. A whole degree is
   far wider than any rounding and far narrower than any real pick -- the
   picker's own world box stops at +/-85 latitude, where Mercator does. Zero
   means the box must really reach them. *)
let world_margin = 1.0

let spans_regions ?(margin = 0.0) (regions : Basemap_job.request list) =
  match regions with
  | [ r ] ->
      r.Basemap_job.polygon = None
      && r.Basemap_job.min_lon <= -180.0 +. margin
      && r.Basemap_job.max_lon >= 180.0 -. margin
      && r.Basemap_job.min_lat <= -85.0 +. margin
      && r.Basemap_job.max_lat >= 85.0 -. margin
  | _ -> false

(* Spanning the planet does not by itself make an entry unremovable. A user
   may ask for the whole world AS DETAIL; that lands in a file of its own,
   sits beside the overview rather than being it, and is theirs to remove.
   The end-to-end suite does exactly that, which is how this was caught.

   What cannot be removed is a world-spanning entry inside the old merged
   map.pmtiles, since pruning that takes the tiles the whole map falls back
   to everywhere. So the caller pairs this with the archive the entry lives
   in. *)
let spans_world (e : entry) = spans_regions ~margin:world_margin e.regions

(* The mirror of [drops], for export rather than removal. [drops] asks "is
   this tile leaving with the entry being removed"; this asks "is this tile
   none of the exported entry's business". Both are drop predicates because
   that is what [Merge.prune] takes, so exporting one region runs the same
   machinery as removing every other one -- without touching the archive the
   user is actually using. *)
let outside ~(entry : entry) =
  let mine = List.map prepare entry.regions in
  fun ~z ~x ~y -> not (List.exists (fun p -> fetches p ~z ~x ~y) mine)

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
    (* Written only when there is one, so an entry recorded before regions
       carried labels still serialises to the bytes it always did, as does
       one whose picker sent no name. Optional on the way back in too. *)
    @ (match r.label with None -> [] | Some l -> [ ("label", `String l) ])
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

let number_field name fields =
  let* v = field name fields in
  number v

(* Map, first error wins. A fold would rebind the accumulator's result at
   every element; this walks once and stops at the first Error. *)
let traverse f l =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | x :: rest -> (
        match f x with Ok v -> go (v :: acc) rest | Error _ as e -> e)
  in
  go [] l

let region_of_json = function
  | `Assoc fields ->
      let* min_lon = number_field "min_lon" fields in
      let* min_lat = number_field "min_lat" fields in
      let* max_lon = number_field "max_lon" fields in
      let* max_lat = number_field "max_lat" fields in
      let* max_zoom =
        let* z = field "max_zoom" fields in
        match z with `Int z -> Ok z | _ -> Error "max_zoom must be an integer"
      in
      let* polygon =
        match List.assoc_opt "polygon" fields with
        | None -> Ok None
        | Some (`List rings) ->
            let* rings =
              traverse
                (function
                  | `List pts ->
                      let* pts = traverse point pts in
                      Ok (Array.of_list pts)
                  | _ -> Error "a polygon ring must be a list of points")
                rings
            in
            Ok (Some (Array.of_list rings))
        | Some _ -> Error "polygon must be a list of rings"
      in
      let* label =
        match List.assoc_opt "label" fields with
        | None | Some `Null -> Ok None
        | Some (`String s) -> Ok (Some s)
        | Some _ -> Error "a region's label must be a string"
      in
      (* Stored regions were validated when they arrived. Validating again on
         the way back in is what catches a corrupted ledger. *)
      Basemap_job.validate ?polygon ?label ~min_lon ~min_lat ~max_lon ~max_lat
        ~max_zoom ()
  | _ -> Error "a region must be an object"

let entry_of_json = function
  | `Assoc fields ->
      let* name =
        let* v = field "name" fields in
        match v with
        | `String s when valid_name s -> Ok s
        | _ -> Error "entry name is invalid"
      in
      let* completed =
        let* v = field "completed" fields in
        match v with
        | `Int s when s >= 0 -> Ok s
        | _ -> Error "completed must be a non-negative integer"
      in
      let* source =
        let* v = field "source" fields in
        match v with `String s -> Ok s | _ -> Error "source must be a string"
      in
      let* bytes =
        let* v = field "bytes" fields in
        match v with
        | `Int b when b >= 0 -> Ok b
        | _ -> Error "bytes must be a non-negative integer"
      in
      let* regions =
        let* v = field "regions" fields in
        match v with
        | `List (_ :: _ as l) -> traverse region_of_json l
        | _ -> Error "regions must be a non-empty list"
      in
      Ok (make ~name ~regions ~completed ~source ~bytes)
  | _ -> Error "an entry must be an object"

let of_json = function
  | `Assoc fields -> (
      match List.assoc_opt "v" fields with
      | Some (`Int v) when v = version -> (
          match List.assoc_opt "entries" fields with
          | Some (`List l) -> traverse entry_of_json l
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

(* A ledger written under a name we no longer use. Not the same as an archive
   with no downloads, and the difference destroys data: read as empty, the
   next download rewrites the file with a ledger naming only itself, and the
   removal after that prunes every tile the forgotten regions held, because
   [drops] keeps a tile only when some entry still in the ledger asks for it.
   So an unreadable record is an error, not an empty one. Matching on the
   suffix spots it without this file having to list the old spellings. *)
let suffix = "_ledger"

let foreign fields =
  let ends_in_suffix k =
    String.length k > String.length suffix
    && String.equal
         (String.sub k (String.length k - String.length suffix)
            (String.length suffix))
         suffix
  in
  List.exists
    (fun (k, _) -> (not (String.equal k metadata_key)) && ends_in_suffix k)
    fields

(* No ledger key at all means an empty ledger: that is every archive written
   before this feature and every fresh extract. Anything else that fails to
   parse is corruption and says so, including a ledger key that appears
   twice, which reads and writes would otherwise resolve differently. *)
let of_metadata s =
  match Yojson.Safe.from_string s with
  | exception _ -> Error (wrap "archive metadata is not JSON")
  | `Assoc fields when duplicated fields ->
      Error (wrap "the ledger key appears more than once")
  | `Assoc fields when foreign fields ->
      Error
        (wrap
           "it was written under a name this version does not use; re-download \
            this map")
  | `Assoc fields -> (
      match List.assoc_opt metadata_key fields with
      | None -> Ok []
      | Some j -> Result.map_error wrap (of_json j))
  | _ -> Error (wrap "archive metadata is not an object")

(* Every other metadata key keeps its original position. An empty ledger
   removes the key entirely, so an archive whose last entry was removed is
   byte-identical to one that never had any. *)
let to_metadata (t : t) ~previous =
  match Yojson.Safe.from_string previous with
  | exception _ -> Error (wrap "archive metadata is not JSON")
  | `Assoc fields when duplicated fields ->
      Error (wrap "the ledger key appears more than once")
  (* Same refusal on the way out. Keeping the old key would leave the archive
     carrying two records, and the next read could not tell which one the
     tiles belong to. *)
  | `Assoc fields when foreign fields ->
      Error
        (wrap
           "it was written under a name this version does not use; re-download \
            this map")
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
