(* The offline gazetteer: every name a downloaded region can draw, and where
   it is.

   Search is the one feature that cannot be an API call here. Handing "Gare de
   Lyon" to a hosted geocoder tells it exactly where the user is going, which
   is the thing this project exists not to leak -- worse than the tile
   requests it already refuses, because a query names the destination
   outright. So search reads what is already on disk: the vector tiles carry
   their own labels, and a region the user kept is a region whose names they
   already have.

   Built once per download rather than per query, because walking a country's
   tiles takes seconds and a keystroke cannot. Measured on France at zoom 12:
   33,767 tiles, 690,000 distinct names, 18 seconds.

   Queries scan the file instead of holding it in memory. A country's index is
   tens of megabytes and scanning that takes milliseconds from the page cache.
   The alternative is a resident table with its own invalidation rules against
   an archive that downloads, updates and removals rewrite -- a coherence
   problem in exchange for a saving nobody asked for. *)

type entry = {
  name : string;
  kind : string;  (** locality, street, lake ... as the basemap labels it *)
  layer : string;  (** places, roads, pois, water, earth *)
  weight : float;  (** population where the basemap knows one, else 0 *)
  lon : float;
  lat : float;
}

let filename = "search.idx"

(* Deeper than this and building the index takes minutes instead of seconds:
   zoom 13 quadruples the tile count for names mostly repeated from 12. Named
   roads start appearing at 12, which is what makes street search work at all.
   Residential streets are deeper still; reaching them is on the roadmap. *)
let index_zoom = 12

(* ------------------------------------------------------------ normalising *)

(* Folded once when the index is written and once per query, so "Orleans"
   finds "Orléans" and "MARSEILLE" finds "Marseille". Latin-1 and Latin
   Extended-A cover the languages this UI ships in; anything else keeps its
   own bytes and still matches itself exactly. *)
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
        | 0x92 | 0x93 | 0x94 | 0x95 | 0x96 | 0xb2 | 0xb3 | 0xb4 | 0xb5 | 0xb6 ->
            Some 'o'
        | 0x99 | 0x9a | 0x9b | 0x9c | 0xb9 | 0xba | 0xbb | 0xbc -> Some 'u'
        | 0x9d | 0xbd | 0xbf -> Some 'y'
        | _ -> None
      in
      (match plain with
      | Some p -> Buffer.add_char buf p
      | None ->
          (* Æ Ø Þ Ð and the like keep their letter but lose their case, so
             "ørsta" still finds "Ørsta". *)
          Buffer.add_char buf c;
          Buffer.add_char buf
            (if d >= 0x80 && d <= 0x9e then Char.chr (d + 0x20) else s.[!i + 1]));
      i := !i + 2
    end
    else if (Char.code c = 0xc4 || Char.code c = 0xc5) && !i + 1 < n then begin
      (* Latin Extended-A: Č, Ł, ő and the rest. Only the case bit is
         folded. Stripping these to ASCII needs a table this does not carry,
         and a Polish name still matches itself exactly. *)
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

(* Tab-separated, one entry per line, sorted: the file is diffable, its build
   is deterministic, and a corrupt line costs one name rather than the whole
   index. The folded name leads the line because that is what every query
   compares against; the display name follows. *)
(* Names come out of tiles this project did not write, so the separators must
   not be forgeable. A name carrying a newline would split its row, and one
   carrying a tab could form a whole valid row with coordinates of its own
   choosing. Both become spaces on the way in. *)
let sanitise s = String.map (function '\t' | '\n' | '\r' -> ' ' | c -> c) s

let to_line e =
  let name = sanitise e.name in
  Printf.sprintf "%s\t%s\t%s\t%s\t%.0f\t%.6f\t%.6f" (fold name) name
    (sanitise e.kind) (sanitise e.layer) e.weight e.lon e.lat

let of_line line =
  match String.split_on_char '\t' line with
  | [ _folded; name; kind; layer; weight; lon; lat ] -> (
      match
        ( float_of_string_opt weight,
          float_of_string_opt lon,
          float_of_string_opt lat )
      with
      | Some weight, Some lon, Some lat
        when Float.is_finite lon && Float.is_finite lat && name <> "" ->
          Some { name; kind; layer; weight; lon; lat }
      | _ -> None)
  | _ -> None

(* Some layers matter more: a town beats a road of the same name, and both
   beat a shop. Ordering only, never a filter. *)
let layer_rank = function
  | "places" -> 0
  | "roads" -> 1
  | "pois" -> 2
  | "water" -> 3
  | _ -> 4

(* Importance first, because a name is rarely unique: eleven French places
   are called Paris, and the one with two million people is the one meant.
   Population is the basemap's own answer where it has one; where it does
   not, the layer stands in. *)
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
   appears in every tile that draws it and at every zoom above it, so the walk
   dedups as it goes and keeps the deepest sighting, which places the label
   most precisely. *)
(* Position is part of a sighting's identity. Those repeats down the pyramid
   have to collapse, but two different towns sharing a name must not -- which
   keying on the name alone would do, silently keeping whichever was seen
   last. A twentieth of a degree is far wider than the difference between
   zooms and far narrower than the gap between distinct places.

   Keying on the square alone let one town split in two: two sightings twenty
   metres apart collapsed or survived depending on where the grid lines fell.
   Jasper, Alberta straddled one, so a list of eight Jaspers spent two rows on
   the same town. A sighting now checks the eight squares around its own too,
   and joins any cluster of the same name within the radius, wherever that
   cluster was first filed.

   The other direction is unchanged, and is not claimed. It is the grid, not
   the radius, that keeps two DIFFERENT towns of one name apart, so two that
   share a square are still one row however far apart inside it they sit.
   That is why the square is kilometres wide -- still far narrower than the
   gap between distinct places. *)
let cell v = int_of_float (Float.round (v *. 20.))
let merge_radius = 0.05

let cluster_key seen ~folded ~layer ~lon ~lat =
  let here = (folded, layer, cell lon, cell lat) in
  let near = ref None in
  for dx = -1 to 1 do
    for dy = -1 to 1 do
      if !near = None then begin
        let k = (folded, layer, cell lon + dx, cell lat + dy) in
        match Hashtbl.find_opt seen k with
        | Some (_, e)
          when Float.abs (e.lon -. lon) <= merge_radius
               && Float.abs (e.lat -. lat) <= merge_radius ->
            near := Some k
        | _ -> ()
      end
    done
  done;
  Option.value !near ~default:here

(* How many ids a walk over this archive will actually visit. Counting a whole
   run whenever its FIRST id is within max_zoom is not the same: an empty
   ocean tile is byte-identical at zoom 12 and 13, so one run can straddle the
   boundary. The total would then include ids the walk skips, and the progress
   bar would stop short and never arrive. *)
let count ~max_zoom (archive : Pmtiles.Archive.t) =
  let within (e : Pmtiles.Directory.entry) =
    let n = ref 0 in
    for k = 0 to e.Pmtiles.Directory.run_length - 1 do
      let z, _, _ = Pmtiles.Tile_id.to_zxy (e.Pmtiles.Directory.tile_id + k) in
      if z <= max_zoom then incr n
    done;
    !n
  in
  List.fold_left
    (fun acc e -> acc + within e)
    0
    (Pmtiles.Archive.entries archive)

(* One archive's names, folded into a table shared with the others.

   Shared rather than concatenated, which matters: the cluster logic keeps
   the shallowest zoom a name was seen at, so a label repeated down the
   pyramid is recorded once at the zoom that places it best. Two archives
   holding the same city -- a region and the world overview under it, or two
   overlapping regions -- have to resolve the same way. Concatenating two
   independent builds would give that city two rows and two map flights. *)
let build_one ~seen ~max_zoom ~on_tile ~offset ~grand
    (archive : Pmtiles.Archive.t) =
  let gz =
    archive.Pmtiles.Archive.header.Pmtiles.Header.tile_compression
    = Pmtiles.Header.Gzip
  in
  let entries = Pmtiles.Archive.entries archive in
  let done_ = ref 0 in
  List.iter
    (fun (e : Pmtiles.Directory.entry) ->
      (* A run is one blob shared by consecutive tile ids, so it is read once
         and re-projected per id. Walking the entry alone would skip every id
         after the first.

         Read HERE, not inside the loop. Fetching per id re-ran the directory
         search, the source read and the inflate for every id in the run: five
         thousand identical ocean tiles cost five thousand reads and five
         thousand inflations of the same bytes, when only Mvt.named below
         varies with the id. Lazy, so a run entirely past max_zoom is never
         read at all. *)
      let blob =
        lazy
          (match Pmtiles.Archive.tile archive e.Pmtiles.Directory.tile_id with
          | None -> None
          | Some raw -> (
              match if gz then Gzip.decompress raw else raw with
              | exception _ ->
                  None (* one unreadable tile is not a failed index *)
              | plain -> Some plain))
      in
      for k = 0 to e.Pmtiles.Directory.run_length - 1 do
        let id = e.Pmtiles.Directory.tile_id + k in
        let z, x, y = Pmtiles.Tile_id.to_zxy id in
        if z <= max_zoom then begin
          incr done_;
          on_tile (offset + !done_) grand;
          match Lazy.force blob with
          | None -> ()
          | Some plain -> (
              match Pmtiles.Mvt.named ~z ~x ~y plain with
              | exception _ -> ()
              | named ->
                  List.iter
                    (fun (layer, name, kind, weight, lon, lat) ->
                      let key =
                        cluster_key seen ~folded:(fold name) ~layer ~lon ~lat
                      in
                      match Hashtbl.find_opt seen key with
                      | Some (seen_z, _) when seen_z >= z -> ()
                      | _ ->
                          Hashtbl.replace seen key
                            (z, { name; kind; layer; weight; lon; lat }))
                    named)
        end
      done)
    entries;
  !done_

(* Every downloaded archive's names, as one index.

   A list rather than one archive, because there is one file per region: the
   names a search can offer are the union of what every file holds. Counted
   before the walk so the progress bar has a denominator spanning the whole
   job; a bar restarting at each file would read as several downloads. *)
let build_many ?(max_zoom = index_zoom) ~on_tile archives =
  let seen = Hashtbl.create 8192 in
  let grand =
    List.fold_left (fun acc a -> acc + count ~max_zoom a) 0 archives
  in
  let offset = ref 0 in
  List.iter
    (fun a ->
      offset :=
        !offset + build_one ~seen ~max_zoom ~on_tile ~offset:!offset ~grand a)
    archives;
  let out = Hashtbl.fold (fun _ (_, e) acc -> e :: acc) seen [] in
  List.sort compare_entry out

let save ~fs ~basemap_dir entries =
  let dir = Eio.Path.(fs / basemap_dir) in
  let part = Eio.Path.(dir / (filename ^ ".part")) in
  (* The directory is served over HTTP, so a half-written index left behind
     is fetchable, not just untidy. *)
  Fun.protect ~finally:(fun () ->
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

(* Ranked, best first. [score] is the whole ranking key built by [rank_key],
   not a single band, and lower is better. *)
type hit = {
  entry : entry;
  score : int;
}

(* How well the name answers the query decides first; importance only breaks
   ties. The other way round would bury an exact hit under a populous partial
   one, and "York" would answer with New York. *)
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

(* The BEST occurrence decides, not the first: "ork" in "yorkshire ork lane"
   starts a word later in the string, and stopping at the first hit would
   score it as buried. Compares bytes in place rather than cutting a substring
   per position, since this runs over every line of a file that can be tens of
   megabytes. *)
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
    if !best = max_int then
      None (* Shorter names win within a band: "York" over "Yorkshire Road". *)
    else Some ((!best * 100_000) + min 99_999 h)
  end

(* A query is a name, and sometimes the context someone gave it.

   People write both and separate them with a comma: "Atlanta, GA", "Paris,
   France". Everything before the first comma is the name being asked for and
   every word of it counts. Everything after is context that ranks but never
   decides, because it usually is not in the name at all -- no entry for
   Atlanta contains "GA" anywhere.

   Two earlier versions were wrong, both measured against a real
   country-sized index. Matching the whole query as one run of characters
   answered "Atlanta, GA" with nothing found, since that string is inside no
   name on Earth. Treating every word alike then answered "Los Angeles" with
   a hamlet of 100 people called Los: "Los" is an exact name and "Los
   Angeles" merely begins with the word, so exactness beat completeness.
   Completeness comes first now -- the entry carrying more of the name wins,
   and how exactly it carries the first word only breaks ties. *)

(* Enough words for the longest real place name, and enough context for a
   town, a region and a country. Past that, extra words are noise, and each
   one is another pass over every line. *)
let max_head = 6
let max_context = 2

(* Bytes at or above 0x80 are the middle of a UTF-8 character and stay in the
   term: folding leaves other scripts alone, and splitting on them would cut a
   character in half. Every ASCII byte that is not a letter or digit
   separates -- spaces, hyphens, apostrophes -- because "Saint-Etienne" and a
   query typed "saint etienne" are the same request. *)
let term_byte c =
  Char.code c >= 0x80 || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')

(* The punctuation people paste rather than type. A query copied off a web
   page arrives with a non-breaking space or a curly apostrophe, and a reader
   treats those as separators, so this does too. The fullwidth and ideographic
   commas mean what the ASCII comma means. Names are folded when the index is
   built, so this normalises the QUERY only; a name that itself contains a
   non-breaking space is on the roadmap. *)
let ascii_punctuation s =
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let i = ref 0 in
  while !i < n do
    let three = if !i + 3 <= n then String.sub s !i 3 else "" in
    let two = if !i + 2 <= n then String.sub s !i 2 else "" in
    match (two, three) with
    | "\xc2\xa0", _ ->
        Buffer.add_char b ' ';
        i := !i + 2
    | _, "\xe2\x80\xaf" (* narrow no-break space *)
    | _, "\xe2\x80\x98" (* left single quote *)
    | _, "\xe2\x80\x99" (* right single quote, the pasted apostrophe *)
    | _, "\xe2\x80\x93" (* en dash *)
    | _, "\xe2\x80\x94" (* em dash *) ->
        Buffer.add_char b ' ';
        i := !i + 3
    | _, "\xef\xbc\x8c" (* fullwidth comma *)
    | _, "\xe3\x80\x81" (* ideographic comma *) ->
        Buffer.add_char b ',';
        i := !i + 3
    | _ ->
        Buffer.add_char b s.[!i];
        incr i
  done;
  Buffer.contents b

let terms_of ~limit text =
  let out = ref [] and buf = Buffer.create 16 in
  let flush () =
    if Buffer.length buf > 0 then begin
      out := Buffer.contents buf :: !out;
      Buffer.clear buf
    end
  in
  String.iter
    (fun c -> if term_byte c then Buffer.add_char buf c else flush ())
    text;
  flush ();
  List.filteri (fun i _ -> i < limit) (List.rev !out)

type query = {
  head : string list;
  context : string list;
}

let parse_query q =
  let folded = ascii_punctuation (fold q) in
  let head = Buffer.create 16 and context = Buffer.create 16 in
  let past_comma = ref false in
  String.iter
    (fun c ->
      if c = ',' then past_comma := true
      else Buffer.add_char (if !past_comma then context else head) c)
    folded;
  {
    head = terms_of ~limit:max_head (Buffer.contents head);
    context = terms_of ~limit:max_context (Buffer.contents context);
  }

(* Presence, stopping at the first hit. [score_of] scans the whole name for
   its best occurrence, which is right for the word the ranking is built on
   and wasted work for every other word. *)
let contains ~needle folded =
  let n = String.length needle and h = String.length folded in
  n > 0 && n <= h
  &&
  let rec at i =
    i + n <= h
    &&
    let rec same k = k = n || (folded.[i + k] = needle.[k] && same (k + 1)) in
    same 0 || at (i + 1)
  in
  at 0

let carried terms folded =
  List.fold_left
    (fun n t -> if contains ~needle:t folded then n + 1 else n)
    0 terms

(* How this name answers the query: how many words of the NAME it carries,
   how exactly it carries the first of them, and how much of the CONTEXT it
   carries too. The first word is required -- a name with none of what was
   asked for is not a worse answer, it is not an answer. *)
type quality = {
  head_depth : int;
  band : int;
  context_depth : int;
  length : int;
}

let match_of ~(query : query) folded =
  match query.head with
  | [] -> None
  | first :: _ -> (
      match score_of ~needle:first folded with
      | None -> None
      | Some score ->
          Some
            {
              head_depth = carried query.head folded;
              band = score / 100_000;
              context_depth = carried query.context folded;
              length = score mod 100_000;
            })

(* One number to rank by, low is best, computed from the name alone so the
   scan can drop a line before parsing it.

   Every step of the ordering came from a wrong answer on a real index.
   Carrying more of the name beats a more exact match on its first word ("Los
   Angeles" over "Los"). A more exact match beats carrying the context
   ("Atlanta" over "Atlanta Gas Light Lake", where "ga" hides inside "Gas").
   Carrying the context beats nothing. A shorter name breaks what is left.
   Population and layer settle true ties, in [compare_entry]. *)
let rank_key q =
  let depth = max 0 (max_head - q.head_depth) in
  let context = max 0 (max_context - q.context_depth) in
  (((((depth * 4) + q.band) * (max_context + 1)) + context) * 100_000)
  + q.length

let search ~fs ~basemap_dir ~query ~limit =
  let q = parse_query query in
  let size = List.fold_left (fun n t -> n + String.length t) 0 q.head in
  (* Same floor the UI applies, counted over the query's own characters
     rather than what was typed: one character matches most of a country and
     is no use as an answer. Counted in bytes, so one character of a script
     that spends three of them clears it -- right for a language where one
     character is a word. *)
  if size < 2 then []
  else begin
    let path = Eio.Path.(fs / basemap_dir / filename) in
    (* Only the best [limit] are kept as the file is read. Collecting every
       match and sorting afterwards made a one-letter query allocate three
       hundred megabytes and run ten million comparisons without yielding
       once, on a single-domain server that can answer nothing else
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
      (* The scan is the only long-running part left, so it yields. A search
         must not hold the domain against every other request. *)
      incr seen;
      if !seen land 8191 = 0 then Eio.Fiber.yield ();
      match Text.cut '\t' line with
      | None -> ()
      | Some (folded, _) -> (
          match match_of ~query:q folded with
          | None -> ()
          | Some quality -> (
              let key = rank_key quality in
              if !held >= limit && key > !worst then ()
              else
                match of_line line with
                | None -> ()
                | Some entry -> insert { entry; score = key }))
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
    | () -> !best
    (* A missing or half-written index means "nothing found", not a 500: the
       archive it describes may have been removed a moment ago. *)
    | exception _ -> []
  end

(* [score] travels with the row because the caller cannot recompute it. It is
   how well the row answered the NAME (see [rank_key]), lower is better, and
   two rows with the same score are two answers this index rates equally.

   That set is what a caller may re-order using evidence the index does not
   have. The browser has some: it knows which country and state a point falls
   in, and the index never will. Publishing the number keeps that re-ordering
   from guessing at the ranking it is refining. *)
let to_json (hits : hit list) : Yojson.Safe.t =
  `Assoc
    [
      ( "results",
        `List
          (List.map
             (fun h ->
               let e = h.entry in
               `Assoc
                 [
                   ("name", `String e.name);
                   ("kind", `String e.kind);
                   ("layer", `String e.layer);
                   ("weight", `Float e.weight);
                   ("lon", `Float e.lon);
                   ("lat", `Float e.lat);
                   ("score", `Int h.score);
                 ])
             hits) );
    ]
