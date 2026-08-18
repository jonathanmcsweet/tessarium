(* The offline gazetteer: every name a downloaded region can draw, and where
   it is.

   A search box is the one feature that cannot be bolted on with an API call
   here. Handing "Gare de Lyon" to a hosted geocoder tells that geocoder
   exactly where the user is going, which is the single thing this project
   exists not to leak -- worse than the tile requests it already refuses,
   because a query names the destination outright. So search reads what is
   already on disk: the vector tiles carry their own labels, and a region the
   user chose to keep is a region whose names they already have.

   Built once per download rather than per query, because walking a country's
   tiles takes seconds and a keystroke may not. Measured on France at zoom 12:
   33,767 tiles, 690,000 distinct names, 18 seconds.

   Queries scan the file instead of holding it in memory. A country's index is
   tens of megabytes, a scan of that is milliseconds from the page cache, and
   the alternative -- a resident table with its own invalidation rules against
   an archive that downloads, updates and removals rewrite -- is a coherence
   problem for a saving no one asked for. *)

type entry = {
  name : string;
  kind : string;  (** locality, street, lake ... as the basemap labels it *)
  layer : string;  (** places, roads, pois, water, earth *)
  weight : float;  (** population where the basemap knows one, else 0 *)
  lon : float;
  lat : float;
}

let filename = "search.idx"

(* Deeper than this and building the index costs minutes rather than seconds:
   zoom 13 quadruples the tile count for names that are mostly repeats of
   what 12 already holds. Named roads start appearing at 12, which is what
   makes street search work at all -- residential streets live deeper still,
   and reaching them is recorded on the roadmap rather than paid for here. *)
let index_zoom = 12

(* ------------------------------------------------------------ normalising *)

(* Folded once at write time and once per query, so "Orleans" finds
   "Orléans" and "MARSEILLE" finds "Marseille". Latin-1 and Latin Extended-A
   cover the languages this UI ships in; anything else keeps its own bytes
   and still matches itself exactly. *)
let fold_char buf c =
  Buffer.add_char buf
    (if c >= 'A' && c <= 'Z' then Char.chr (Char.code c + 32) else c)

let fold s =
  let buf = Buffer.create (String.length s) in
  let n = String.length s in
  let i = ref 0 in
  while !i < n do
    let c = s.[!i] in
    if Char.code c < 0x80 then begin
      fold_char buf c;
      incr i
    end
    else if Char.code c = 0xc3 && !i + 1 < n then begin
      (* U+00C0..U+00FF *)
      let d = Char.code s.[!i + 1] in
      let plain =
        match d with
        | 0x80 | 0x81 | 0x82 | 0x83 | 0x84 | 0x85 | 0xa0 | 0xa1 | 0xa2 | 0xa3
        | 0xa4 | 0xa5 ->
            Some 'a'
        | 0x87 | 0xa7 -> Some 'c'
        | 0x88 | 0x89 | 0x8a | 0x8b | 0xa8 | 0xa9 | 0xaa | 0xab -> Some 'e'
        | 0x8c | 0x8d | 0x8e | 0x8f | 0xac | 0xad | 0xae | 0xaf -> Some 'i'
        | 0x91 | 0xb1 -> Some 'n'
        | 0x92 | 0x93 | 0x94 | 0x95 | 0x96 | 0xb2 | 0xb3 | 0xb4 | 0xb5 | 0xb6
          ->
            Some 'o'
        | 0x99 | 0x9a | 0x9b | 0x9c | 0xb9 | 0xba | 0xbb | 0xbc -> Some 'u'
        | 0x9d | 0xbd | 0xbf -> Some 'y'
        | _ -> None
      in
      (match plain with
      | Some p -> Buffer.add_char buf p
      | None ->
          (* Æ Ø Þ Ð and friends keep their letter but not their case, so
             "ørsta" still finds "Ørsta". *)
          Buffer.add_char buf c;
          Buffer.add_char buf
            (if d >= 0x80 && d <= 0x9e then Char.chr (d + 0x20)
             else s.[!i + 1]));
      i := !i + 2
    end
    else if (Char.code c = 0xc4 || Char.code c = 0xc5) && !i + 1 < n then begin
      (* Latin Extended-A: Č, Ł, ő and the rest. Only the case bit is
         folded -- stripping these to ASCII needs a table this does not
         carry, and a Polish name still matches itself exactly. *)
      let d = Char.code s.[!i + 1] in
      Buffer.add_char buf c;
      Buffer.add_char buf
        (if d land 1 = 0 && d >= 0x80 && d <= 0xbe then Char.chr (d + 1)
         else s.[!i + 1]);
      i := !i + 2
    end
    else begin
      Buffer.add_char buf c;
      incr i
    end
  done;
  Buffer.contents buf

(* ------------------------------------------------------------- the file *)

(* Tab-separated, one entry per line, sorted -- so the file is diffable, its
   build is deterministic, and a corrupt line costs one name rather than the
   index. The folded name leads the line because it is what every query
   compares against; the display name follows it. *)
(* Names come out of tiles this project did not write, and the record
   separator must not be forgeable: a name carrying a newline would split
   its row, and one carrying a tab could re-form a whole valid row with
   attacker-chosen coordinates. Both become spaces on the way in. *)
let sanitise s =
  String.map (function '\t' | '\n' | '\r' -> ' ' | c -> c) s

let to_line e =
  let name = sanitise e.name in
  Printf.sprintf "%s\t%s\t%s\t%s\t%.0f\t%.6f\t%.6f" (fold name) name
    (sanitise e.kind) (sanitise e.layer) e.weight e.lon e.lat

let of_line line =
  match String.split_on_char '\t' line with
  | [ _folded; name; kind; layer; weight; lon; lat ] -> (
      match
        (float_of_string_opt weight, float_of_string_opt lon,
         float_of_string_opt lat)
      with
      | Some weight, Some lon, Some lat
        when Float.is_finite lon && Float.is_finite lat && name <> "" ->
          Some { name; kind; layer; weight; lon; lat }
      | _ -> None)
  | _ -> None

(* A name is worth more from some layers than others: a town beats a road of
   the same name, and both beat a shop. Ordering only, never a filter. *)
let layer_rank = function
  | "places" -> 0
  | "roads" -> 1
  | "pois" -> 2
  | "water" -> 3
  | _ -> 4

(* Importance first, because a name is rarely unique: eleven French places
   are called Paris, and the one with two million people is the one meant.
   Population is the basemap's own answer where it has one; where it does
   not, the layer stands in -- a town beats a road beats a shop. *)
let compare_entry a b =
  match compare b.weight a.weight with
  | 0 -> (
      match compare (layer_rank a.layer) (layer_rank b.layer) with
      | 0 -> (
          match compare (fold a.name) (fold b.name) with
          | 0 -> compare (a.lon, a.lat) (b.lon, b.lat)
          | c -> c)
      | c -> c)
  | c -> c

(* ------------------------------------------------------------- building *)

(* One pass over the tiles shallow enough to be worth reading. The same name
   appears in every tile that draws it and at every zoom above it, so the
   walk dedups as it goes and keeps the deepest sighting -- the deeper tile
   places the label more precisely. *)
let build ?(max_zoom = index_zoom) ~on_tile (archive : Pmtiles.Archive.t) =
  let gz =
    archive.Pmtiles.Archive.header.Pmtiles.Header.tile_compression
    = Pmtiles.Header.Gzip
  in
  let seen = Hashtbl.create 8192 in
  let entries = Pmtiles.Archive.entries archive in
  let total =
    List.fold_left
      (fun acc (e : Pmtiles.Directory.entry) ->
        let z, _, _ = Pmtiles.Tile_id.to_zxy e.Pmtiles.Directory.tile_id in
        if z <= max_zoom then acc + e.Pmtiles.Directory.run_length else acc)
      0 entries
  in
  let done_ = ref 0 in
  List.iter
    (fun (e : Pmtiles.Directory.entry) ->
      (* A run is one blob shared by consecutive tile ids, so it is read once
         and re-projected per id. Walking the entry alone would skip every
         id after the first -- and leave the progress total, which counts
         ids, permanently unreachable. *)
      for k = 0 to e.Pmtiles.Directory.run_length - 1 do
        let id = e.Pmtiles.Directory.tile_id + k in
        let z, x, y = Pmtiles.Tile_id.to_zxy id in
        if z <= max_zoom then begin
          incr done_;
          on_tile !done_ total;
          match Pmtiles.Archive.tile archive id with
          | None -> ()
          | Some raw -> (
            match if gz then Gzip.decompress raw else raw with
            | exception _ -> ()  (* one unreadable tile is not a failed index *)
            | plain -> (
                match Pmtiles.Mvt.named ~z ~x ~y plain with
                | exception _ -> ()
                | named ->
                    List.iter
                      (fun (layer, name, kind, weight, lon, lat) ->
                        (* Position is part of the identity. The same label
                           is drawn in every tile that touches it and at
                           every zoom above it, and those repeats must
                           collapse -- but two different towns sharing a
                           name must not, which keying on the name alone
                           would do, silently keeping whichever was seen
                           last. A twentieth of a degree is far wider than
                           the quantisation between zooms and far narrower
                           than the gap between distinct places. *)
                        let cell v = Float.round (v *. 20.) in
                        let key = (fold name, layer, cell lon, cell lat) in
                        match Hashtbl.find_opt seen key with
                        | Some (seen_z, _) when seen_z >= z -> ()
                        | _ ->
                            Hashtbl.replace seen key
                              (z, { name; kind; layer; weight; lon; lat }))
                      named))
        end
      done)
    entries;
  let out = Hashtbl.fold (fun _ (_, e) acc -> e :: acc) seen [] in
  List.sort compare_entry out

let save ~fs ~basemap_dir entries =
  let dir = Eio.Path.(fs / basemap_dir) in
  let part = Eio.Path.(dir / (filename ^ ".part")) in
  (* The directory is served over HTTP, so a half-written index left behind
     is fetchable, not merely untidy. *)
  Fun.protect
    ~finally:(fun () ->
      match Eio.Path.kind ~follow:true part with
      | `Regular_file -> ( try Eio.Path.unlink part with _ -> ())
      | _ | (exception _) -> ())
  @@ fun () ->
  Eio.Path.with_open_out ~create:(`Or_truncate 0o644) part (fun out ->
      let buf = Buffer.create 65536 in
      List.iter
        (fun e ->
          Buffer.add_string buf (to_line e);
          Buffer.add_char buf '\n';
          if Buffer.length buf > 262144 then begin
            Eio.Flow.copy_string (Buffer.contents buf) out;
            Buffer.clear buf
          end)
        entries;
      if Buffer.length buf > 0 then
        Eio.Flow.copy_string (Buffer.contents buf) out);
  Eio.Path.rename part Eio.Path.(dir / filename)

let remove ~fs ~basemap_dir =
  List.iter
    (fun name ->
      try Eio.Path.unlink Eio.Path.(fs / basemap_dir / name) with _ -> ())
    [ filename; filename ^ ".part" ]

(* -------------------------------------------------------------- querying *)

(* Ranked, best first. Exact beats prefix beats a match at a word boundary
   beats one in the middle of a word, because "york" should offer York before
   every street with "york" buried in it. *)
type hit = { entry : entry; score : int }

(* Match quality decides the band; importance decides within it. Ordering
   the other way round would bury an exact hit under a populous partial
   one -- "York" would answer with New York. *)
let compare_hit a b =
  match compare a.score b.score with
  | 0 -> compare_entry a.entry b.entry
  | c -> c

let word_start folded at =
  at = 0
  ||
  match folded.[at - 1] with
  | ' ' | '-' | '\'' | '(' | '/' | ',' | '.' -> true
  | _ -> false

(* The BEST occurrence decides, not the first: "ork" inside "yorkshire ork
   lane" starts a word later in the string, and stopping at the first hit
   would score it as buried. Compares bytes in place rather than cutting a
   substring per position -- this runs over every line of a file that can be
   tens of megabytes. *)
let score_of ~needle folded =
  let n = String.length needle and h = String.length folded in
  if n = 0 || n > h then None
  else begin
    let matches_at i =
      let rec go k = k = n || (folded.[i + k] = needle.[k] && go (k + 1)) in
      go 0
    in
    let best = ref max_int in
    let i = ref 0 in
    while !i + n <= h && !best > 0 do
      (if matches_at !i then
         let band =
           if n = h then 0
           else if !i = 0 then 1
           else if word_start folded !i then 2
           else 3
         in
         if band < !best then best := band);
      incr i
    done;
    if !best = max_int then None
      (* Shorter names win within a band: "York" over "Yorkshire Road". *)
    else Some ((!best * 100_000) + min 99_999 h)
  end

let search ~fs ~basemap_dir ~query ~limit =
  let needle = fold (String.trim query) in
  (* Same floor the UI applies. One character matches most of a country, and
     the answer is not useful at that length in any case. *)
  if String.length needle < 2 then []
  else begin
    let path = Eio.Path.(fs / basemap_dir / filename) in
    (* Only the best [limit] are kept as the file is read. Collecting every
       match and sorting afterwards is what made a one-letter query allocate
       three hundred megabytes and sort ten million comparisons without ever
       yielding -- on a single-domain server that answers nothing else
       meanwhile. *)
    let best = ref [] and held = ref 0 and worst = ref max_int in
    let insert hit =
      let rec place = function
        | [] -> [ hit ]
        | h :: rest when compare_hit hit h < 0 -> hit :: h :: rest
        | h :: rest -> h :: place rest
      in
      best := place !best;
      if !held < limit then incr held
      else best := List.filteri (fun i _ -> i < limit) !best;
      match List.rev !best with
      | last :: _ when !held >= limit -> worst := last.score
      | _ -> ()
    in
    let seen = ref 0 in
    let consider line =
      (* The scan is the only long-running part left, so it yields: a search
         must not hold the domain against every other request. *)
      incr seen;
      if !seen land 8191 = 0 then Eio.Fiber.yield ();
      match String.index_opt line '\t' with
      | None -> ()
      | Some tab -> (
          let folded = String.sub line 0 tab in
          match score_of ~needle folded with
          | None -> ()
          | Some score when !held >= limit && score > !worst -> ()
          | Some score -> (
              match of_line line with
              | None -> ()
              | Some entry -> insert { entry; score }))
    in
    match
      Eio.Path.with_open_in path (fun flow ->
          let buf = Eio.Buf_read.of_flow ~max_size:(1 lsl 24) flow in
          try
            while true do
              consider (Eio.Buf_read.line buf)
            done
          with End_of_file -> ())
    with
    | () -> List.map (fun h -> h.entry) !best
    (* A missing or half-written index is "nothing found", not a 500: the
       archive it describes may have been removed a moment ago. *)
    | exception _ -> []
  end

let to_json (entries : entry list) : Yojson.Safe.t =
  `Assoc
    [
      ( "results",
        `List
          (List.map
             (fun e ->
               `Assoc
                 [
                   ("name", `String e.name);
                   ("kind", `String e.kind);
                   ("layer", `String e.layer);
                   ("weight", `Float e.weight);
                   ("lon", `Float e.lon);
                   ("lat", `Float e.lat);
                 ])
             entries) );
    ]
