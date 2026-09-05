(* The effectful side of the in-app basemap download.

   Every decision -- may a download start, is this box valid, what does
   progress look like -- is [Basemap_job]'s and is tested there; the merge
   arithmetic is [Pmtiles.Merge]'s, tested in the pmtiles suite. This module
   owns what cannot be pure: the fiber, the socket, the .part file, and the
   mutex around the one shared job cell.

   Each download writes its OWN archive: one file per region, named after
   the region and the day it was fetched, dropped in beside the others and
   never stitched into them. See [Tile_set] for why, and for what a tile
   lookup does with a directory full of them. What it buys here is that
   every operation after the download is an operation on one file --
   handing it over is handing over the file, taking it away is unlinking it
   -- and neither has to rewrite a gigabyte to do it.

   The world overview is the exception and still merges into its own file,
   because deepening it from zoom 4 to zoom 6 should cost the levels in
   between rather than the whole planet again.

   The tile source and assets URL are the server's configuration, never the
   client's. A request body names a region of the world; it does not name a
   place on the internet to fetch from. *)

type t = {
  mutex : Eio.Mutex.t;
  mutable job : Basemap_job.t;
  (* Counts starts. In the status JSON so a poller can tell "this download
     finished" from "some earlier download had finished": a fast job can run
     idle-to-done entirely between two polls, and without an identity the
     second poll is indistinguishable from stale news. *)
  mutable generation : int;
  mutable cancel_requested : bool;
  (* One browse fetch at a time, separately from the job: browsing writes
     cache.pmtiles, never map.pmtiles, so it may run beside a download --
     but not beside itself. *)
  mutable browsing : bool;
  (* Broadcast when [browsing] clears, so a download waiting to prune the
     cache sleeps instead of spinning through the browse's network time. *)
  browse_done : Eio.Condition.t;
  (* "Erase the browse cache when you let go of it." Set when the user turns
     browsing off while a writer holds the file, and honoured by that writer
     on its way out -- so the request answers at once and the erasing still
     happens, rather than the request waiting on someone else's network. *)
  mutable clear_requested : bool;
  (* One upload at a time, and none while a job holds the writer's seat.
     Separate from the job because receiving bytes is not a job: it writes
     only into the import directory, reports no progress, and must not take a
     state a poller would read as a download.

     Without it two uploads open the same staged .part with [Or_truncate] and
     write from byte zero at once, each counting only its own bytes against
     its own Content-Length -- so a file made of two archives interleaved
     passes the length check, is renamed to staged.pmtiles, and is merged as
     garbage tiles. And an upload landing while an import merge is reading the
     staged file replaces it underneath the merge. *)
  mutable staging : bool;
}

(* The tile archives, in the order a lookup tries them -- [Tile_set]'s
   answer, restated here because three readers have to agree: the tile
   endpoint serves from them, the coverage query answers questions ABOUT
   them, and the downloader writes them. A list that drifted apart here
   would have the map drawing tiles a coverage query had just called
   missing.

   It is a directory listing now rather than three names, because a region
   is its own file: see [Tile_set] for why. *)
let cache_file = Tile_set.cache_file
let base_file = Tile_set.base_file
let world_file = Tile_set.world_file
let tile_files ~fs ~basemap_dir = Tile_set.names ~dir:Eio.Path.(fs / basemap_dir)

(* The name the world overview answers to in the list, and nowhere else.

   The overview writes no ledger record -- every package ships one and the
   extraction tool makes one, neither of which goes through a download --
   so it has no id of its own to be listed under. This is that id, made up
   here rather than read from a file.

   It is a word, and every real id is twelve hex digits of a hash, so no
   download can collide with it however many are made. That matters because
   the whole point of putting the overview in the list is that a user can
   SEE it, and the moment a thing is visible its id is sayable: every verb
   that takes an id off that list has to refuse this one by name. It was
   safe before only because it was invisible, which is a defence that also
   hid the forty-five megabytes the map is standing on. *)
let overview_id = "world"

(* What "downloaded" means. The world overview is not a download and must
   not be counted as one: it is nobody's region, and the detail source's
   bounds come from these so that the map does not ask about a planet nobody
   fetched. *)
let detail_files ~fs ~basemap_dir =
  List.filter (fun n -> n <> world_file) (tile_files ~fs ~basemap_dir)

(* Which archive a download writes, and the only thing that differs between
   the two kinds of download this server runs.

   A region goes to a file of its own and carries its own record, so it can
   be named, listed, updated and removed as one thing. The world overview is
   not a region: it belongs to no place, it is what the map falls back to
   everywhere, and every package ships one. Giving it a region's treatment
   made it removable by accident -- take away the region whose entry
   happened to carry it and the floor goes with it -- and gave the list a
   row for something the user cannot meaningfully remove.

   So it has one fixed file and writes no record. It is also the one
   download that still MERGES, into whatever overview is already there,
   which is what makes deepening the shipped zoom 4 to zoom 6 cost only the
   levels in between rather than the planet again. *)
type target = Detail | World

(* How deep the floor is ever allowed to go. The scan below is one lookup
   per tile of a whole zoom level, so the work quadruples with every step:
   zoom 6 is 4096 lookups and zoom 10 would be a million. Six is also as
   deep as a world overview is worth shipping -- past it the file is
   measured in hundreds of megabytes. *)
let max_floor_zoom = 6

(* Whether an archive's data section is actually on disk.

   A truncated file -- a fetch interrupted after the header and directories
   were written -- answers every directory lookup and fails half the reads,
   which is the one shape that can fool the scan below into certifying a
   floor full of holes. Cheap to rule out: the header says where the data
   ends, and the file either reaches that far or it does not.

   Only the floor asks. A truncated archive still serves every tile it
   really has, and taking it away entirely would turn a partial download
   into no map at all; what it may not do is be counted towards a
   completeness claim. *)
let data_is_whole ~size (a : Pmtiles.Archive.t) =
  a.Pmtiles.Archive.header.Pmtiles.Header.data_offset
  + a.Pmtiles.Archive.header.Pmtiles.Header.data_length
  <= size

(* The deepest zoom the archives cover the ENTIRE planet at.

   This is the floor's depth, and it is measured rather than declared
   because the floor's one job is to have no holes. A hole draws as an empty
   tile, an empty tile counts as data, and data replaces the coarse tile
   already on screen -- which is the bug the floor exists to fix, so a floor
   that guessed its own depth wrong would reintroduce it.

   Counted across every archive together: one may hold the world at zoom 4
   and another a country at zoom 12, and the floor stands on the union.
   Stops at the first missing tile of the first incomplete zoom, so the
   usual answers are cheap -- an archive holding one city runs out inside
   zoom 1, two or three lookups in. The full 5461 are only paid by an
   archive that really does hold the whole world, which is the case worth
   being sure about; measured at 3 ms against a 6.4 GB archive, because the
   zoom 0-6 ids sit at the front of the file in one root directory and four
   leaves.

   -1 means not even the single zoom-0 tile is there: no floor at all. *)
let floor_depth archives =
  let held ~z ~x ~y =
    let id = Pmtiles.Tile_id.of_zxy ~z ~x ~y in
    List.exists (fun a -> Pmtiles.Archive.locate a id <> None) archives
  in
  let complete z =
    let n = 1 lsl z in
    let rec scan i = i >= n * n || (held ~z ~x:(i / n) ~y:(i mod n) && scan (i + 1)) in
    scan 0
  in
  let rec deepest z =
    if z > max_floor_zoom || not (complete z) then z - 1 else deepest (z + 1)
  in
  deepest 0

(* Why a coverage query failed, kept apart because the two answers are
   different HTTP statuses: a viewport larger than the cap is the caller
   asking for more than a viewport, and an archive this server cannot read
   is this server's own data gone wrong. Reporting both as one string once
   meant a corrupt archive was blamed on the page that asked. *)
type coverage_error = Too_large of string | Unreadable of string

(* Why an upload was refused, kept apart for the same reason: a seat that is
   taken is a conflict the client can retry in a moment, and a body that is
   not a map archive is the client's own doing and will not improve. *)
type upload_error = Busy of string | Rejected of string

(* What the request handler sees: closures, so the handler can be tested
   with pure fakes and never needs the switch, the network or the clock. *)
type ops = {
  estimate :
    world:bool -> Basemap_job.request list -> (Yojson.Safe.t, string) result;
  (* Each region carries its own display label, so there is nothing to line
     up here: what the picker called a pick travels on the pick. *)
  start :
    name:string option ->
    world:bool ->
    Basemap_job.request list ->
    (unit, string) result;
  cancel : unit -> bool;
  status : unit -> Yojson.Safe.t;
  ledger : unit -> (Yojson.Safe.t, string) result;
  update : id:string -> (unit, string) result;
  remove : id:string -> (unit, string) result;
  (* Writing one recorded region out as a file to carry elsewhere, and
     managing the files that produces. Reads the archive and writes beside
     it, so nothing here can damage the map the user is looking at. *)
  export : id:string -> (unit, string) result;
  exports : unit -> Yojson.Safe.t;
  delete_export : file:string -> (unit, string) result;
  (* The far side of the same trip: what is staged for import, committing
     it, and throwing it away.

     [receive] takes the upload itself, as a [read] that fills a buffer rather
     than as a socket -- so this record is still callable from a test with no
     network, and the seat that keeps two uploads from interleaving stays with
     the job cell that owns every other seat. *)
  receive :
    expected:int -> read:(Cstruct.t -> int) -> (unit, upload_error) result;
  staged : unit -> Yojson.Safe.t;
  import : unit -> (unit, string) result;
  discard_import : unit -> (unit, string) result;
  (* Answers with the tiles fetched AND the zoom actually written: the
     source's depth may be shallower than the view asked for, and a client
     that cannot tell the difference will keep asking for a depth that can
     never arrive. *)
  browse : Basemap_job.request -> (int * int, string) result;
  (* Names from the downloaded region, ranked. Reads the index built when
     the region landed; never the network. *)
  search : query:string -> limit:int -> (Yojson.Safe.t, string) result;
  (* Erases the browse cache. Never blocks and never fails: if a writer
     holds the file, the erasing is handed to it and happens when it lets
     go. Browsing is already off by the time this is called, so nothing new
     can arrive in the meantime. *)
  clear_cache : unit -> unit;
  (* Which of a viewport's tiles this server can actually serve. The
     request's [max_zoom] is the zoom the map is displaying, not a depth to
     download. *)
  coverage : Basemap_job.request -> (Yojson.Safe.t, coverage_error) result;
}

let create () =
  {
    mutex = Eio.Mutex.create ();
    job = Basemap_job.Idle;
    generation = 0;
    cancel_requested = false;
    browsing = false;
    browse_done = Eio.Condition.create ();
    clear_requested = false;
    staging = false;
  }

let set t job = Eio.Mutex.use_rw ~protect:true t.mutex (fun () -> t.job <- job)

let status t =
  let generation, job =
    Eio.Mutex.use_ro t.mutex (fun () -> (t.generation, t.job))
  in
  `Assoc
    [ ("generation", `Int generation); ("job", Basemap_job.to_json job) ]

(* Cancellation is a flag the download polls, not a fiber kill. Killing the
   fiber mid-write leaves a half-written .part with nothing responsible for
   it; polling means the download itself walks to its own exit. *)
exception Cancelled_by_user

(* Every tile asked for was already in the file this run would have joined.
   A failure to the caller and a sentence to the user, but a NAMED one,
   because an import of an archive holding several records has to tell it
   apart from a real failure: one region already held must not abandon the
   four beside it, while a disk filling up must stop the lot. *)
exception Already_held

let check_cancel t =
  if Eio.Mutex.use_ro t.mutex (fun () -> t.cancel_requested) then
    raise Cancelled_by_user

let cancel t =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      if Basemap_job.is_running t.job then begin
        t.cancel_requested <- true;
        true
      end
      else false)

(* Clearing the browse seat, deliberately WITHOUT the mutex -- as the wait
   in [prune_cache] reads it without one.

   Nothing is bought by taking it. Every critical section on [t.mutex] is a
   read or an assignment with no suspension point in it, so a fiber never
   finds the mutex held, and a bool write plus a broadcast cannot raise or
   suspend either. The pairing that matters is with the waiter: it observes
   [browsing] and suspends on the condition with nothing in between, which
   is exactly what [await_no_mutex] requires.

   Both halves of that argument assume ONE domain, which is what this
   server runs. Introduce a second and this field -- and the job cell the
   waiter reads beside it -- need real synchronisation again. *)
let release_browsing t =
  t.browsing <- false;
  Eio.Condition.broadcast t.browse_done

let unlink_cache ~fs ~basemap_dir =
  List.iter
    (fun name ->
      try Eio.Path.unlink Eio.Path.(fs / basemap_dir / name) with _ -> ())
    [ cache_file; cache_file ^ ".part" ]

(* Every writer of cache.pmtiles calls this as it finishes. *)
let honor_clear t ~fs ~basemap_dir =
  if t.clear_requested then begin
    t.clear_requested <- false;
    unlink_cache ~fs ~basemap_dir
  end

let claim t =
  (* Claiming the job and checking it are one critical section; two requests
     arriving together must not both see a resting state. *)
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      if Basemap_job.can_start t.job then begin
        t.job <- Basemap_job.Planning;
        t.generation <- t.generation + 1;
        t.cancel_requested <- false;
        true
      end
      else false)

(* Exceptions out of Eio and cohttp arrive as their printed form; Failure
   carries the messages this codebase writes for humans. *)
let friendly = function
  | Failure m -> m
  | Already_held -> "you already have the maps for that area"
  | e -> Printexc.to_string e

(* How every job ends, in one place.

   Five of them write the archive directory -- download, remove, export,
   compact, import -- and each one owes the same three things on the way out:
   the half-written .part goes, a cache clear asked for while this job held
   the writer's seat is carried out (nothing else is coming to do it, because
   browsing is off while a job runs), and exactly one terminal state is set.

   Five hand-maintained copies of that is four chances to forget one, and two
   of them had: a cancelled export stranded its .part in the export directory
   where [exports_json] cannot list it and [delete_export] cannot remove it,
   leaking gigabytes invisibly, and both the export and the fast-path import
   dropped a clear on the floor. There is one copy now and every path goes
   through it.

   [discard] removes whatever partial file this job was writing; [on_stop]
   is the extra tidying only a download has. Neither runs on success -- a
   successful job renamed its own .part away, and it has already done its own
   pruning. *)
let terminate t ~fs ~basemap_dir ?(discard = fun () -> ())
    ?(on_stop = fun () -> ()) ~ok body =
  let stop state =
    discard ();
    on_stop ();
    honor_clear t ~fs ~basemap_dir;
    set t state
  in
  match body () with
  | v ->
      honor_clear t ~fs ~basemap_dir;
      set t (ok v)
  | exception Cancelled_by_user -> stop Basemap_job.Cancelled
  | exception e -> stop (Basemap_job.Failed (friendly e))

(* Taking the writer's seat and running the job on a fiber of its own, in one
   place: five verbs did this and each carried its own copy of the refusal,
   all of them saying "a download is already running" whatever was actually
   running -- press Remove while an export is going and the server explained
   that a download was. One seat, one sentence, and it names neither. *)
let start_job t ~sw run =
  if not (claim t) then Error "the map is busy with another job; try again shortly"
  else begin
    Eio.Fiber.fork ~sw (fun () -> run ());
    Ok ()
  end

(* ------------------------------------------------------------------ plan *)

(* How much planning one request may cost. An explicit ask that plans within
   [full] tile ids gets its full depth in one piece -- whole-France street
   level is ~2.3 million ids and qualifies, as does every US state. A box
   beyond that is SPLIT into at most [max_parts] pieces that each fit --
   Brazil (~18M ids) becomes three or four, downloaded one at a time -- and
   only a box too big even for that (Canada's box, Russia's) falls back to a
   quick [quick]-id regional plan with the UI saying to pick a province.
   Splitting is also what makes giants resumable: each piece merges and
   renames atomically, so an interruption keeps every finished piece and a
   re-request skips them. *)
type budget = { full : int; quick : int; max_parts : int; compact : int }

let default_budget =
  {
    full = 6_000_000;
    quick = 131_072;
    max_parts = 8;
    (* When the browse cache outgrows this many bytes of tile data it is
       folded into the main archive: past ~48 MB the per-browse rewrite of
       the cache costs more than one fold of the big file amortises. *)
    compact = 48_000_000;
  }

(* How many blobs a copy may get through before it rebuilds the progress rows
   and takes the mutex again. The only reader polls once a second, so the bar
   moves at a human rate either way; the same number and the same reasoning
   are in [reindex]. *)
let progress_every = 256

(* Million-id loops must share the scheduler: yield every so often, and a
   download also polls its cancel flag, so even the planning phase of a
   country-sized job stops when asked. *)
let breathe ?cancel () =
  let n = ref 0 in
  fun () ->
    incr n;
    if !n land 4095 = 0 then begin
      Eio.Fiber.yield ();
      match cancel with Some t -> check_cancel t | None -> ()
    end

(* The resolved URL is part of the return: the ledger records which archive
   a region was actually fetched from, and "latest" is not an answer. *)
let open_source ~sw ~fs ~net ~source =
  let source = Pmtiles_source.resolve ~sw ~net source in
  let src = Pmtiles_source.open_url ~sw ~fs ~net source in
  let archive = Pmtiles.Archive.open_ src in
  (source, src, archive)

(* One box a download will actually plan and fetch, with the region it came
   from: a small region is one segment, a giant is several. *)
type segment = {
  req : Basemap_job.request;
  idx : int;
      (** which request this came from, as a position in the list the client
          sent. Carried rather than recovered by comparing requests: a batch
          may hold two picks with identical boxes -- a country and a city
          inside it clamped to the same depth -- and progress attributed by
          value would credit both to whichever matched first. *)
  depth : int;
  box : float * float * float * float;
  clip : Pmtiles.Clip.t option;
      (** the region's polygon; planning stops at the border, not the box *)
}

(* The units of work, in fetch order, plus the granted depth per region in
   request order. Single-box regions ride together in one merge -- that is
   what lets overlapping picks dedup against each other -- and every giant
   part is its own unit, planned and written alone so memory stays at the
   single-part envelope however large the region. Seams between parts may
   share an edge row of tiles; the second part's merge sees them on disk
   and skips them, so an estimate double-counts at most a sliver. *)
let units_of ?cancel ~budget ~header reqs =
  let min_zoom = header.Pmtiles.Header.min_zoom in
  let split =
    List.mapi
      (fun idx (req : Basemap_job.request) ->
        let requested = min req.max_zoom header.Pmtiles.Header.max_zoom in
        let clip = Option.map Pmtiles.Clip.of_rings req.polygon in
        let parts, depth, _clamped =
          Pmtiles.Tile_id.download_parts ?clip
            ~on_count:(breathe ?cancel ())
            ~min_zoom ~requested
            ~min_lon:req.min_lon ~min_lat:req.min_lat ~max_lon:req.max_lon
            ~max_lat:req.max_lat ~full_limit:budget.full
            ~quick_limit:budget.quick ~max_parts:budget.max_parts ()
        in
        (req, idx, depth, clip, parts))
      reqs
  in
  let singles, giants =
    List.partition (fun (_, _, _, _, parts) -> List.length parts = 1) split
  in
  let batch =
    match singles with
    | [] -> []
    | l ->
        [
          `Batch
            (List.map
               (fun ((req : Basemap_job.request), idx, depth, clip, parts) ->
                 { req; idx; depth; clip; box = List.hd parts })
               l);
        ]
  in
  let parts =
    List.concat_map
      (fun (req, idx, depth, clip, boxes) ->
        List.map (fun box -> `Part { req; idx; depth; clip; box }) boxes)
      giants
  in
  (batch @ parts, List.map (fun (_, _, depth, _, _) -> depth) split)

let plan_box ?cancel ~archive ~min_zoom (seg : segment) =
  let a, b, c, d = seg.box in
  Pmtiles.Extract.plan
    ~on_tile:(breathe ?cancel ())
    ?clip:seg.clip archive ~min_zoom ~max_zoom:seg.depth ~min_lon:a ~min_lat:b
    ~max_lon:c ~max_lat:d

let segments_of = function `Batch segs -> segs | `Part seg -> [ seg ]

(* The archive already on disk, if any -- the merge's base. *)
let open_archive ~sw ~fs ~basemap_dir name =
  let path = Eio.Path.(fs / basemap_dir / name) in
  match Eio.Path.kind ~follow:true path with
  | `Regular_file ->
      Some
        (Pmtiles.Archive.open_
           (Pmtiles_source.file_source (Eio.Path.open_in ~sw path)))
  | _ -> None

let open_base ~sw ~fs ~basemap_dir = open_archive ~sw ~fs ~basemap_dir base_file

(* For readers that must survive a bad file rather than fail the request:
   an archive that will not open is skipped with a warning, exactly as the
   tile endpoint skips it. A half-written map.pmtiles must not take the
   browse cache's answers down with it, and a query about tiles has to
   describe the same archives the tile endpoint will actually serve
   from. *)
let open_readable ~sw ~fs ~basemap_dir name =
  match open_archive ~sw ~fs ~basemap_dir name with
  | a -> a
  | exception e ->
      Logs.warn (fun m ->
          m "coverage: %s is unreadable: %s" name (Printexc.to_string e));
      None

let whole_archives ~sw ~fs ~basemap_dir names =
  List.filter_map
    (fun name ->
      let path = Eio.Path.(fs / basemap_dir / name) in
      match open_readable ~sw ~fs ~basemap_dir name with
      | None -> None
      | Some a ->
          let size =
            Optint.Int63.to_int
              (Eio.Path.stat ~follow:true path).Eio.File.Stat.size
          in
          if data_is_whole ~size a then Some a
          else begin
            Logs.warn (fun m ->
                m "%s is shorter than its own header says: not counted \
                   towards the floor" name);
            None
          end)
    names

(* The browse cache: anonymous tiles picked up while panning online. Its own
   file so a browse never rewrites the big archive; folded into it when it
   outgrows the budget's compaction threshold. *)
let open_cache ~sw ~fs ~basemap_dir =
  open_archive ~sw ~fs ~basemap_dir cache_file

(* The archive's ledger, read before anything rewrites the archive. An
   unreadable ledger stops the operation cold rather than being overwritten:
   silently forgetting what a gigabyte archive holds is the one failure this
   feature must never have. *)
let base_ledger = function
  | None -> ("{}", [])
  | Some b -> (
      let meta = Pmtiles.Archive.metadata b in
      match Ledger.of_metadata meta with
      | Ok l -> (meta, l)
      | Error m -> failwith m)

(* ------------------------------------------------- where entries live *)

(* Every downloaded archive on disk: one file per region, plus the old
   merged one if this install has it.

   The browse cache is not here -- it is nobody's download -- and neither is
   the world overview. That second exclusion is load-bearing: everything
   that lists, exports, updates or removes a region finds it through here,
   so an overview that never appears is an overview with no id to name, no
   row to press Remove on, and nothing to delete. The refusals at those
   sites are the second lock on the same door. *)
let downloaded_files ~fs ~basemap_dir =
  List.filter
    (fun n -> n <> cache_file && n <> world_file)
    (tile_files ~fs ~basemap_dir)

(* One file's ledger.

   [base_file] keeps the old contract: a metadata blob it cannot read stops
   whatever asked, because that file can hold every region a user ever
   downloaded and quietly reading it as empty would forget all of them.

   A region file is different, and deliberately. It arrives on a USB stick
   as often as it arrives from a download, so it is far likelier to be
   truncated or half-copied -- and one bad file must not take the list of
   everything else down with it, least of all because that list is where
   the user would go to delete it. It is skipped with a warning, and its
   tiles keep being served either way: [Tile_set] reads headers, not
   ledgers, so a file with an unreadable record still draws. What is lost is
   the ability to name it in the UI, not the map. *)
(* Parsed ledgers, keyed on the file's identity exactly as [Tile_set] keys
   its headers.

   Reading one is an open, a range read, a gunzip and a JSON parse. That is
   cheap once and expensive forty times a request, which is what this was:
   every basemap-ledger poll and every estimate walked every archive on disk
   and parsed all of them, and both are re-asked constantly -- the ledger
   after every job transition, the estimate on every change in the region
   picker. Twenty kept regions cost twenty parses per call, and the answer had
   not changed between any two of them.

   A stat says whether it can be reused, and a stat is what tells the truth
   here: the downloader publishes by renaming a .part over the name, so the
   name can stay put while the bytes underneath it become a different region.
   Device, inode, size and mtime catch all of it.

   A file that would not parse is remembered as such, so its warning is
   logged once per change rather than once per poll. *)
let ledger_cache : (string, Tile_set.stamp * Ledger.t) Hashtbl.t =
  Hashtbl.create 16

let ledger_of ~sw ~fs ~basemap_dir name =
  let path = Eio.Path.(fs / basemap_dir / name) in
  let stamp =
    match Eio.Path.stat ~follow:true path with
    | st -> Some (Tile_set.stamp_of st)
    | exception Eio.Io _ -> None
  in
  let cached =
    match stamp with
    | None -> None
    | Some s -> (
        match Hashtbl.find_opt ledger_cache name with
        | Some (s', l) when s' = s -> Some l
        | _ -> None)
  in
  match cached with
  | Some l -> l
  | None ->
      let parsed =
        match open_readable ~sw ~fs ~basemap_dir name with
        | None -> []
        | Some a -> (
            match Ledger.of_metadata (Pmtiles.Archive.metadata a) with
            | Ok l -> l
            | Error m | (exception Failure m) ->
                if name = base_file then failwith m
                else begin
                  Logs.warn (fun m' ->
                      m' "%s: unreadable download record, not listed: %s" name m);
                  []
                end)
      in
      (match stamp with
      | Some s -> Hashtbl.replace ledger_cache name (s, parsed)
      | None -> ());
      parsed

(* Every recorded region and the file holding it, in the order a lookup
   would find them.

   One id appears once. An install upgraded from the merged layout can hold
   the same regions twice -- inside map.pmtiles and in a file of their own,
   because a re-download deliberately refuses to write into the base archive
   -- and both copies hash to the same id, since identity is the geometry and
   nothing else. Listed twice, that id is a duplicate React key and a pair of
   rows that reconcile into each other, and removing the file-backed one
   leaves the base copy behind still claiming the same ground.

   The file-backed home wins, which is what the order already says: regions
   come before the merged archive in the listing, so the first sighting of an
   id is the one that can actually be removed, updated and carried away. *)
let homes ~sw ~fs ~basemap_dir =
  let files = downloaded_files ~fs ~basemap_dir in
  (* A ledger for a file that has left the directory is one nothing will ask
     for again. *)
  (let present = Hashtbl.create (List.length files) in
   List.iter (fun n -> Hashtbl.replace present n ()) files;
   Hashtbl.filter_map_inplace
     (fun name v -> if Hashtbl.mem present name then Some v else None)
     ledger_cache);
  let seen = Hashtbl.create 16 in
  List.concat_map
    (fun name ->
      List.filter_map
        (fun e ->
          let id = Ledger.id e in
          if Hashtbl.mem seen id then None
          else begin
            Hashtbl.replace seen id ();
            Some (name, e)
          end)
        (ledger_of ~sw ~fs ~basemap_dir name))
    files

let home_of ~sw ~fs ~basemap_dir ~id =
  List.find_opt
    (fun (_, e) -> Ledger.id e = id)
    (homes ~sw ~fs ~basemap_dir)

(* Reading the archives' own labels into the search index. Runs when they
   change -- a download, an update, a removal -- because that is exactly when
   the names they can offer change, and because a keystroke cannot wait the
   seconds this takes on a country.

   Every downloaded file, not one: the names a search can offer are the
   union of what is on disk, and with a file per region that is a list. The
   world overview is left out on purpose -- its labels are the handful of
   country names a zoom-6 pyramid carries, and they would answer ahead of
   the real ones. Nothing downloaded means no names, so the index goes
   rather than lingering. *)
let reindex t ~fs ~basemap_dir =
  Eio.Switch.run @@ fun sw ->
  match
    List.filter_map (open_readable ~sw ~fs ~basemap_dir)
      (downloaded_files ~fs ~basemap_dir)
  with
  | [] -> Place_index.remove ~fs ~basemap_dir
  | archives ->
      let last = ref 0 in
      let entries =
        Place_index.build_many archives ~on_tile:(fun done_ total ->
            (* Progress, but not thirty thousand mutex takes: the bar moves
               at a human rate either way. *)
            if done_ - !last >= 256 || done_ = total then begin
              last := done_;
              check_cancel t;
              set t
                (Basemap_job.Indexing
                   { done_tiles = done_; total_tiles = total })
            end)
      in
      Place_index.save ~fs ~basemap_dir entries

(* The id a set of granted regions hashes to. [Ledger.id] reads the regions
   and nothing else, so the name, the source and the byte count can all be
   left blank here -- which is what lets the estimate work out which file a
   download would join before it knows anything else about it. *)
let id_of_regions regions =
  Ledger.id (Ledger.make ~name:"" ~regions ~completed:0 ~source:"" ~bytes:0)

(* The depths a request was actually GRANTED, folded back into it. A clamped
   giant records the zoom it really fetched, so its identity, its ledger row
   and what Remove undoes all describe the same tiles. *)
let as_granted (reqs : Basemap_job.request list) depths =
  List.map2
    (fun (r : Basemap_job.request) depth ->
      { r with Basemap_job.max_zoom = min r.Basemap_job.max_zoom depth })
    reqs depths

(* A scripted request without a name still gets a legible ledger row. *)
let default_name (reqs : Basemap_job.request list) =
  match reqs with
  | [] -> "?"
  | r :: _ ->
      Printf.sprintf "%.2f, %.2f - %.2f, %.2f" r.min_lon r.min_lat r.max_lon
        r.max_lat

(* ------------------------------------------------------- region files *)

(* Where a download lands, and therefore what a person carries away.

   These used to be the export path's, computed when someone asked for a
   copy of a region already merged into map.pmtiles. They are the
   DOWNLOAD's now: a region is written straight to a file of its own with
   this name, and exporting it is handing over a file that already exists.
   That is the whole reason the naming moved up here, above [run_download]
   -- there is no second name to reconcile, because there is no second
   file. *)

let export_dir_name = "export"

(* A file name from what the user called the region.

   Everything outside a conservative ASCII set becomes a dash. The string
   lands in a filesystem, in a URL path and in a save dialog, and the set
   that is safe and predictable in all three is small -- so a Japanese or
   Arabic region name slugs down to its id rather than travelling as bytes
   that one of those three will mangle. The real name is not lost by this:
   it rides inside the file, in the ledger, and is what the importing
   machine displays. *)
(* Epoch seconds to YYYY-MM-DD, UTC, in integer arithmetic.

   Written out rather than taken from a library because there is no calendar
   dependency here and this is the only date the server ever formats: `unix`
   is not in (depends), and adding it for one conversion would be a whole
   package to keep declared and installed for eleven lines. Hinnant's
   civil-from-days, which is exact for every day this can be handed -- the
   leap rule is arithmetic, not a table, so 2000 and 2100 come out right
   without either being a special case.

   UTC, not local: the name travels with the file to another machine in
   another timezone, and a date that changes depending on who is reading it
   is worse than one that is merely not local. *)
let iso_date_of_epoch (secs : int) : string =
  let days = if secs >= 0 then secs / 86_400 else ((secs + 1) / 86_400) - 1 in
  let z = days + 719_468 in
  let era = (if z >= 0 then z else z - 146_096) / 146_097 in
  let doe = z - (era * 146_097) in
  let yoe = (doe - (doe / 1_460) + (doe / 36_524) - (doe / 146_096)) / 365 in
  let y = yoe + (era * 400) in
  let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
  let mp = ((5 * doy) + 2) / 153 in
  let d = doy - (((153 * mp) + 2) / 5) + 1 in
  let m = mp + if mp < 10 then 3 else -9 in
  let y = if m <= 2 then y + 1 else y in
  Printf.sprintf "%04d-%02d-%02d" y m d

let region_filename ~(entry : Ledger.entry) ~id =
  let buf = Buffer.create 32 in
  let last_dash = ref false in
  String.iter
    (fun c ->
      let keep =
        (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9')
        || c = '_'
      in
      if keep then begin
        Buffer.add_char buf c;
        last_dash := false
      end
      else if not !last_dash then begin
        Buffer.add_char buf '-';
        last_dash := true
      end)
    entry.Ledger.name;
  let slug =
    let raw = Buffer.contents buf in
    let trimmed =
      let n = String.length raw in
      let i = ref 0 and j = ref n in
      while !i < n && raw.[!i] = '-' do incr i done;
      while !j > !i && raw.[!j - 1] = '-' do decr j done;
      String.sub raw !i (!j - !i)
    in
    if trimmed = "" then "map" else trimmed
  in
  (* The id keeps two exports of similarly-named regions apart, and makes an
     export idempotent: the same entry written twice is the same file, not a
     second copy filling the disk. *)
  let short = if String.length id <= 8 then id else String.sub id 0 8 in
  (* The date the TILES were fetched, not the date they were exported: it is
     what someone holding the file wants to know, and taking it from the
     entry rather than from the clock is what keeps a re-export idempotent --
     exporting the same map twice is still the same file. ISO order so a
     directory of these sorts chronologically. *)
  let date = iso_date_of_epoch entry.Ledger.completed in
  Printf.sprintf "%s-%s-%s.pmtiles" slug date short

let guard_compression ~h base =
  match base with
  | Some b
    when b.Pmtiles.Archive.header.Pmtiles.Header.tile_compression
         <> h.Pmtiles.Header.tile_compression ->
      failwith
        "the basemap on disk and the tile source disagree on compression; \
         delete the basemap directory and download again"
  | _ -> ()

(* The estimate is what the user will actually pay for over the network:
   tiles the base already holds are excluded, so re-asking for an area you
   have says zero rather than re-quoting the full price. [covered] separates
   "you have all of this" from "the source has nothing here". Units are
   planned one at a time and discarded, so a giant estimate costs the time
   of its planning but only one part's memory. *)
(* Quoted against the archive the download would JOIN, which is why this
   needs to know which kind it is. Diffing a world overview against the
   detail archive would quote the whole planet to someone whose packaged
   zoom 4 already holds most of it, and would then report it uncovered
   forever -- an offer that never goes away however many times it is
   accepted. *)
let estimate ~fs ~net ~source ~basemap_dir ~budget ~world
    (reqs : Basemap_job.request list) =
  match
    Eio.Switch.run @@ fun sw ->
    let _resolved, _src, archive = open_source ~sw ~fs ~net ~source in
    let h = archive.Pmtiles.Archive.header in
    let units, depths = units_of ~budget ~header:h reqs in
    (* The archive this download would JOIN. For the overview that is the
       overview; for a region it is the region's OWN file, found by the id
       its granted boxes hash to -- which is why the units have to be
       planned first. It used to be map.pmtiles for every region, and
       quoting against that now would promise a download most of which is
       already held and then fetch all of it: a region does not merge into
       the merged archive any more. *)
    let base =
      if world then open_archive ~sw ~fs ~basemap_dir world_file
      else
        match
          home_of ~sw ~fs ~basemap_dir ~id:(id_of_regions (as_granted reqs depths))
        with
        | Some (file, _) when file <> base_file ->
            open_archive ~sw ~fs ~basemap_dir file
        | _ -> None
    in
    guard_compression ~h base;
    let fetch = ref 0 and fresh = ref 0 and any_tiles = ref false in
    List.iter
      (fun unit ->
        let plans =
          List.map
            (plan_box ~archive ~min_zoom:h.Pmtiles.Header.min_zoom)
            (segments_of unit)
        in
        if
          List.exists
            (fun (f : Pmtiles.Extract.plan) ->
              Array.length f.Pmtiles.Extract.tiles > 0)
            plans
        then any_tiles := true;
        let mp = Pmtiles.Merge.plan ~on_entry:(breathe ()) ~base plans in
        fetch := !fetch + mp.Pmtiles.Merge.fetch_bytes;
        fresh := !fresh + mp.Pmtiles.Merge.fresh_tiles)
      units;
    (!fetch, !fresh, !any_tiles && !fresh = 0, depths)
  with
  | fetch_bytes, tiles, covered, depths ->
      Ok
        (`Assoc
           [
             ("total_bytes", `Int fetch_bytes);
             ("tiles", `Int tiles);
             ("covered", `Bool covered);
             (* Depth granted per region, in request order. Less than the
                region asked for means "too big, stopping at regional
                detail" -- the UI names which ones. *)
             ("max_zooms", `List (List.map (fun z -> `Int z) depths));
           ])
  | exception e -> Error (friendly e)

(* ----------------------------------------------------------------- assets *)

let dir_exists path =
  match Eio.Path.kind ~follow:true path with `Directory -> true | _ -> false

let ensure_dir path = if not (dir_exists path) then Eio.Path.mkdir ~perm:0o755 path

let write_entry dir segments contents =
  let rec go parent = function
    | [] -> ()
    | [ name ] ->
        Eio.Path.save ~create:(`Or_truncate 0o644) Eio.Path.(parent / name)
          contents
    | seg :: rest ->
        let child = Eio.Path.(parent / seg) in
        ensure_dir child;
        go child rest
  in
  go dir segments

(* The tarball's top-level directory is the repository name plus a commit-ish
   ("basemaps-assets-main/..."); only the fonts and sprites under it matter,
   and they land under the basemap dir without that wrapper. *)
let fetch_assets t ~sw ~net ~assets ~dir =
  (* An empty URL means "do not". The import path passes one: a file carried
     here on a stick holds tiles and nothing else, and the machine it lands
     on either already has its glyphs -- every package ships them -- or is
     offline and has no way to get them. Reaching for the network there would
     turn a working import into a failure reported after the tiles were
     already merged, which is the worst of both. *)
  if assets = "" then ()
  else if
    not (dir_exists Eio.Path.(dir / "fonts") && dir_exists Eio.Path.(dir / "sprites"))
  then begin
    set t Basemap_job.Assets;
    let body = Pmtiles_source.get_body ~sw ~net assets in
    check_cancel t;
    let entries = Untar.list (Gzip.decompress body) in
    List.iter
      (fun (path, contents) ->
        match String.split_on_char '/' path with
        | _wrapper :: (("fonts" | "sprites") :: _ as rest) ->
            write_entry dir rest contents
        | _ -> ())
      entries
  end

(* ---------------------------------------------------------------- download *)

let union_boxes boxes =
  List.fold_left
    (fun (a, b, c, d) (a', b', c', d') ->
      (Float.min a a', Float.min b b', Float.max c c', Float.max d d'))
    (180., 90., -180., -90.)
    boxes

(* A completed download owns its region: any browse-cache tiles it covers
   are dropped, because the tile endpoint consults the cache FIRST and a
   stale browsed copy must never shadow bytes an explicit download or
   update just fetched. Waits out an in-flight browse -- none can start
   while the job runs, so the wait is bounded by the one already going. *)
let prune_cache t ~fs ~basemap_dir ~regions =
  (* Reading [browsing] without the mutex is deliberate: all fibers share
     one domain, and there is no yield point between observing true and
     registering with the condition, so the clearing broadcast cannot slip
     through the gap. The mutex-guarded read had the opposite problem --
     it can suspend, and a wakeup lost there would sleep forever. *)
  while t.browsing do
    Eio.Condition.await_no_mutex t.browse_done
  done;
  Eio.Switch.run @@ fun sw ->
  match open_cache ~sw ~fs ~basemap_dir with
  | None -> ()
  | Some cache ->
      let owner =
        Ledger.make ~name:"-" ~regions ~completed:0 ~source:"-" ~bytes:0
      in
      let drop = Ledger.drops ~removed:owner ~kept:[] in
      (* Deliberately not cancellable: the prune is what keeps a stale
         browsed tile from shadowing bytes a rename already published, and
         it runs on the cancel path itself -- a cancel that aborted it
         would leave the exact incoherence it exists to prevent. Local
         disk work, bounded by the cache size. *)
      let pruned, dropped =
        Pmtiles.Merge.prune ~on_entry:(breathe ()) ~base:cache ~drop ()
      in
      if dropped = 0 then ()
      else if Array.length pruned.Pmtiles.Merge.tiles = 0 then
        Eio.Path.unlink Eio.Path.(fs / basemap_dir / "cache.pmtiles")
      else begin
        let part = Eio.Path.(fs / basemap_dir / "cache.pmtiles.part") in
        let ch = cache.Pmtiles.Archive.header in
        Eio.Path.with_open_out ~create:(`Or_truncate 0o644) part (fun out ->
            let append str = Eio.Flow.copy_string str out in
            let copy ~index:_ ~origin:_ ~offset ~length =
              Eio.Flow.copy_string
                (cache.Pmtiles.Archive.src.Pmtiles.Archive.read ~offset
                   ~length)
                out
            in
            ignore
              (Pmtiles.Merge.write pruned ch
                 ~min_zoom:ch.Pmtiles.Header.min_zoom
                 ~max_zoom:ch.Pmtiles.Header.max_zoom
                 ~min_lon:(Degrees.of_e7 ch.Pmtiles.Header.min_lon_e7)
                 ~min_lat:(Degrees.of_e7 ch.Pmtiles.Header.min_lat_e7)
                 ~max_lon:(Degrees.of_e7 ch.Pmtiles.Header.max_lon_e7)
                 ~max_lat:(Degrees.of_e7 ch.Pmtiles.Header.max_lat_e7)
                 ~append ~copy));
        Eio.Path.rename part Eio.Path.(fs / basemap_dir / "cache.pmtiles")
      end

(* An archive's whole contents restated as an extract plan, blobs at their
   absolute offsets -- what compaction feeds the merge as "fresh", and what an
   import of an archive with no ledger merges instead of a planned box. *)
let plan_of_archive (a : Pmtiles.Archive.t) : Pmtiles.Extract.plan =
  let arr = Pmtiles.Merge.expand_base ~on_entry:(fun () -> ()) a in
  {
    Pmtiles.Extract.blobs =
      Array.map (fun (_, offset, length) -> (offset, length)) arr;
    tiles = Array.mapi (fun i (id, _, _) -> (id, i)) arr;
  }

(* Units run in order, each merged into the archive and renamed atomically
   before the next begins. That sequencing IS the resume story: cancel or a
   crash mid-unit loses only the current .part, every finished unit is
   already the archive on disk, and a re-request finds its tiles held and
   skips it after the planning cost alone. The price is that each unit
   rewrites the archive it grows -- recorded on the roadmap, not hidden. *)
(* [origin] overrides what the ledger records as the archive these tiles came
   from. Only an import passes one, and it must: the source it is READING is a
   temporary file in the import directory that is deleted the moment the merge
   ends, so recording that would leave every imported region citing a path
   that does not exist. What belongs in the record is what the exporting
   machine cited -- the planet build the tiles were originally cut from -- and
   the imported file carries it in its own ledger. *)
(* [whole_source] takes everything the source archive actually holds instead
   of planning a box under the budget, and only a local import passes it.

   The budget is a NETWORK budget: it exists so that asking for Canada does
   not spend hours planning a request nobody can afford to fetch, and it
   clamps a box that plans past [full] down to a quick regional depth. An
   import pays no network at all, so clamping it is not thrift, it is loss --
   a foreign zoom-15 archive re-planned under the download budget comes out at
   roughly zoom 8, only those zooms merge, the ledger records the clamped
   depth as though that were what the file held, and the staged file with its
   zoom 9-and-deeper tiles is then unlinked. The summary shown a moment
   earlier said "detail to zoom 15".

   Reading the source's own directory instead answers exactly what it holds,
   costs no planning, and cannot be clamped by a number that has nothing to do
   with it. The depth recorded is the source's own.

   Only ever passed with the single region derived from the source's own
   header, which is what makes reading the whole directory once the right
   amount of work: several regions would each read all of it.

   This raises the exception the terminal handler reads; [run_download] wraps
   it. Kept separate because an import of an archive holding several records
   runs one of these per record and must land ONE terminal state at the end --
   a poller that saw "done" between two halves of the same import would stop
   watching. *)
let merge_source t ~fs ~net ~source ?origin ~assets ~basemap_dir ~budget ~name
    ~now ~refresh ~replaces ~target ?(whole_source = false)
    (reqs : Basemap_job.request list) =
  let dir = Eio.Path.(fs / basemap_dir) in
  (* Which file this run writes.

     The overview has one name and always did. A region no longer has one:
     it goes to a file of its own, named after itself, and that name is
     derived from the region's ledger id -- which is not known until the
     source header says how deep the request was actually GRANTED. So it is
     settled inside the switch below and the .part name follows it. The
     empty string until then means there is no file yet to discard. *)
  let archive_file =
    ref (match target with World -> world_file | Detail -> "")
  in
  let part_path () = Eio.Path.(dir / (!archive_file ^ ".part")) in
  let discard_part () =
    if !archive_file <> "" then
      try Eio.Path.unlink (part_path ()) with _ -> ()
  in
  (* Every unit renamed into the archive owns its region from that moment,
     even when the run then stops early: cancel and failure must prune the
     browse cache exactly as success does, or the stale browsed copy of a
     tile a rename just published shadows it forever. The whole granted
     region is pruned rather than the finished parts' share -- over-pruning
     costs a re-fetchable cache tile, under-pruning costs correctness. *)
  let published = ref false in
  let prune_regions = ref [] in
  (* Once, whichever exit runs it: the success path prunes inside the switch
     and a later failure -- the assets fetch is the usual one -- must not
     walk the whole cache a second time to drop nothing. *)
  let pruned = ref false in
  let prune_published () =
    if !published && not !pruned then begin
      pruned := true;
      try prune_cache t ~fs ~basemap_dir ~regions:!prune_regions with
      | Eio.Cancel.Cancelled _ as e ->
          (* Eio requires this one to keep travelling; swallowing it leaves
             the fiber running inside a cancelled context. *)
          raise e
      | e ->
          Logs.warn (fun m ->
              m "browse cache prune failed: %s" (Printexc.to_string e))
    end
  in
  match
    Eio.Switch.run @@ fun sw ->
    let resolved, src, archive = open_source ~sw ~fs ~net ~source in
    let h = archive.Pmtiles.Archive.header in
    let min_zoom = h.Pmtiles.Header.min_zoom in
    let units, depths =
      if whole_source then
        (* One unit covering the source's own box at the source's own depth,
           and no budget anywhere near it. The plan for it is read from the
           archive rather than walked over a covering; see [plan_for]. *)
        ( List.mapi
            (fun idx (req : Basemap_job.request) ->
              `Batch
                [
                  {
                    req;
                    idx;
                    depth = h.Pmtiles.Header.max_zoom;
                    box = (req.min_lon, req.min_lat, req.max_lon, req.max_lat);
                    clip = None;
                  };
                ])
            reqs,
          List.map (fun _ -> h.Pmtiles.Header.max_zoom) reqs )
      else units_of ~cancel:t ~budget ~header:h reqs
    in
    let plan_for (seg : segment) =
      if whole_source then plan_of_archive archive
      else plan_box ~cancel:t ~archive ~min_zoom seg
    in
    let parts_total = List.length units in
    ensure_dir dir;
    let name = match name with Some n -> n | None -> default_name reqs in
    (* The ledger records what was GRANTED, not what was asked: a clamped
       giant never fetched below its granted depth, and Remove undoes only
       what actually happened. Identity is fixed here, before anything
       runs; the completion time and byte count are filled in when they
       are true. *)
    let recorded = as_granted reqs depths in
    prune_regions := recorded;
    let recorded_source = Option.value origin ~default:resolved in
    let entry ~completed ~bytes =
      Ledger.make ~name ~regions:recorded ~completed ~source:recorded_source
        ~bytes
    in
    let entry_id = Ledger.id (entry ~completed:0 ~bytes:0) in
    (* One clock reading for the whole run, because two things have to agree
       on it: the ledger row inside the file and the date in the file's own
       name. A download that crosses midnight would otherwise be filed under
       one day and named after another. *)
    let stamp = now () in
    (* Which file this run writes, now that the run has an identity.

       A file already holding this id is written into rather than duplicated,
       and that is what buys three things at once: a cancelled download
       resumes into it, an update rewrites it, and asking twice for the same
       region does not fill the disk with a second copy of a country.

       An entry sitting in the old merged map.pmtiles is deliberately NOT
       reused. That file is still read but never written, so a region it
       holds is re-downloaded to a file of its own beside it; the merged
       copy stays until the user removes it, which is the only behaviour
       that does not rewrite a gigabyte archive nobody asked us to touch.

       A fresh name carries the region, the date and the id. It is the name
       an export used to invent at export time, because this file IS the
       export now. *)
    (if target = Detail then
       let existing =
         Eio.Switch.run (fun psw ->
             match home_of ~sw:psw ~fs ~basemap_dir ~id:entry_id with
             | Some (f, _) when f <> base_file -> Some f
             | _ -> None)
       in
       archive_file :=
         match existing with
         | Some f -> f
         | None ->
             region_filename ~entry:(entry ~completed:stamp ~bytes:0)
               ~id:entry_id);
    let written_total = ref 0 in
    let fetched_total = ref 0 in
    let wrote_any = ref false in
    let found_tiles = ref false in

    (* ------------------------------------------- per-region progress *)

    (* What each picked region has cost, so a download of six countries reads
       as six bars rather than one anonymous total. Indexed by the region's
       position in the request, which is the order the client listed them and
       the order it will draw them in.

       Kept out here rather than per part: a region large enough to be split
       is spread across several units, and its bar must accumulate across
       them rather than restart at each one. *)
    let region_count = List.length reqs in
    (* Off the region itself, so there is nothing to keep aligned. The labels
       used to arrive as a separate array that had to be the same length as
       the requests, checked with a 400 at the door and silently replaced by
       blanks here if it ever was not -- two policies for one invariant,
       disagreeing. A label attached to the region it names cannot be off by
       one. *)
    let region_labels =
      Array.of_list
        (List.map
           (fun (r : Basemap_job.request) -> Option.value r.label ~default:"")
           reqs)
    in
    let region_done = Array.make region_count 0 in
    let region_total = Array.make region_count 0 in
    (* How many units still have to be planned before a region's total is
       final. Counted up front from the units themselves, so a bar can say
       whether its denominator is settled or still growing. *)
    let region_pending = Array.make region_count 0 in
    List.iter
      (fun unit ->
        List.iter
          (fun (s : segment) ->
            region_pending.(s.idx) <- region_pending.(s.idx) + 1)
          (segments_of unit))
      units;
    let region_rows () =
      List.init region_count (fun k ->
          {
            Basemap_job.label = region_labels.(k);
            done_bytes = region_done.(k);
            total_bytes = region_total.(k);
            planned = region_pending.(k) = 0;
          })
    in
    List.iteri
      (fun i unit ->
        check_cancel t;
        (* Honest between parts: the next piece really is being planned. *)
        set t Basemap_job.Planning;
        let part = i + 1 in
        (* A switch per unit so each part's base handle closes when its
           part ends. The rename happens while it is open -- POSIX keeps
           the old inode alive for the open reader, and every base read of
           this part completes before the rename. *)
        Eio.Switch.run @@ fun usw ->
        let base = open_archive ~sw:usw ~fs ~basemap_dir !archive_file in
        guard_compression ~h base;
        let base_meta, _base_led = base_ledger base in
        let plans = List.map plan_for (segments_of unit) in
        if
          List.exists
            (fun (f : Pmtiles.Extract.plan) ->
              Array.length f.Pmtiles.Extract.tiles > 0)
            plans
        then found_tiles := true;
        let mp =
          Pmtiles.Merge.plan ~on_entry:(breathe ~cancel:t ()) ~refresh ~base
            plans
        in
        (* Which region each fresh blob is being fetched for.

           A blob the merge kept from the base archive is nobody's download --
           it is already on disk and no network pays for it -- so it stays
           unowned and is credited to no row. Where several picks in one
           batch wanted a tile the merge stores once, the earliest in request
           order is credited: those bytes cross the wire once and must be
           counted once, or three overlapping picks would each claim the
           whole overlap and the rows would sum past what was fetched.

           Tile ids first, because a blob can back several tiles -- identical
           content deduplicates -- and it is the tile that belongs to a
           region, not the blob. *)
        let blob_region = Array.make (max 1 (Array.length mp.Pmtiles.Merge.blobs)) (-1) in
        let tile_region = Hashtbl.create 4096 in
        List.iter2
          (fun (seg : segment) (pl : Pmtiles.Extract.plan) ->
            Array.iter
              (fun (id, _) ->
                match Hashtbl.find_opt tile_region id with
                | Some prev when prev <= seg.idx -> ()
                | _ -> Hashtbl.replace tile_region id seg.idx)
              pl.Pmtiles.Extract.tiles)
          (segments_of unit) plans;
        Array.iter
          (fun (id, blob) ->
            if blob_region.(blob) < 0 then
              match (Hashtbl.find_opt tile_region id, mp.Pmtiles.Merge.blobs.(blob)) with
              | Some k, (Pmtiles.Merge.Fresh, _, _) -> blob_region.(blob) <- k
              | _ -> ())
          mp.Pmtiles.Merge.tiles;
        Array.iteri
          (fun blob k ->
            if k >= 0 then begin
              let _, _, length = mp.Pmtiles.Merge.blobs.(blob) in
              region_total.(k) <- region_total.(k) + length
            end)
          blob_region;
        (* Planned, whether or not this unit goes on to write anything: a
           unit that found every tile already on disk still settles the
           totals of the regions it covered. *)
        List.iter
          (fun (s : segment) ->
            region_pending.(s.idx) <- max 0 (region_pending.(s.idx) - 1))
          (segments_of unit);
        (* Nothing new in this unit -- the resume case -- writes nothing. *)
        if mp.Pmtiles.Merge.fresh_tiles > 0 || mp.Pmtiles.Merge.refreshed_tiles > 0
        then begin
          check_cancel t;
          let total = mp.Pmtiles.Merge.total_bytes in
          (* The merged header describes the union: the base's box and zooms
             grown by this unit's, so mid-sequence archives stay honest
             about what they hold. *)
          let u_min_lon, u_min_lat, u_max_lon, u_max_lat =
            union_boxes (List.map (fun (s : segment) -> s.box) (segments_of unit))
          in
          let u_depth =
            List.fold_left
              (fun acc (s : segment) -> max acc s.depth)
              min_zoom (segments_of unit)
          in
          let min_zoom', max_zoom', min_lon, min_lat, max_lon, max_lat =
            match base with
            | None ->
                (min_zoom, u_depth, u_min_lon, u_min_lat, u_max_lon, u_max_lat)
            | Some b ->
                let bh = b.Pmtiles.Archive.header in
                ( min min_zoom bh.Pmtiles.Header.min_zoom,
                  max u_depth bh.Pmtiles.Header.max_zoom,
                  Float.min u_min_lon (Degrees.of_e7 bh.Pmtiles.Header.min_lon_e7),
                  Float.min u_min_lat (Degrees.of_e7 bh.Pmtiles.Header.min_lat_e7),
                  Float.max u_max_lon (Degrees.of_e7 bh.Pmtiles.Header.max_lon_e7),
                  Float.max u_max_lat (Degrees.of_e7 bh.Pmtiles.Header.max_lat_e7) )
          in
          (* Written under a .part name and renamed only once complete, so
             the file the map reads is never mid-write and a failure leaves
             the previous archive untouched. *)
          let written = ref 0 in
          (* Publishing progress is not free: it rebuilds one row per picked
             region and takes the mutex around the job cell. Doing that per
             blob means millions of takes across a country-scale part, all so
             that a poll arriving once a second can read one of them. The
             counters below stay exact -- they are two array writes -- and the
             rows are rebuilt every so often and at the end of the part, which
             is the same trade [reindex] makes for the same reason. *)
          let since_publish = ref 0 in
          let publish () =
            since_publish := 0;
            set t
              (Basemap_job.progress ~done_bytes:!written ~total_bytes:total
                 ~part ~parts:parts_total ~regions:(region_rows ()) ())
          in
          publish ();
          Eio.Path.with_open_out ~create:(`Or_truncate 0o644) (part_path ())
            (fun out ->
              let append str = Eio.Flow.copy_string str out in
              let copy ~index ~origin ~offset ~length =
                check_cancel t;
                let bytes =
                  match origin with
                  | Pmtiles.Merge.Base -> (
                      match base with
                      | Some b ->
                          b.Pmtiles.Archive.src.Pmtiles.Archive.read ~offset
                            ~length
                      | None -> assert false (* no Base blobs without a base *))
                  | Pmtiles.Merge.Fresh ->
                      src.Pmtiles.Archive.read ~offset ~length
                in
                Eio.Flow.copy_string bytes out;
                written := !written + length;
                (* The blob's own index, not a count of calls: which blob is
                   being copied is [Merge.write]'s to say, and a counter here
                   would be a second copy of that answer to keep in step. *)
                let owner = blob_region.(index) in
                if owner >= 0 then
                  region_done.(owner) <- region_done.(owner) + length;
                incr since_publish;
                if !since_publish >= progress_every then publish ()
              in
              (* Every part publishes the ledger entry, in the same rename
                 that publishes its tiles -- so the record and the tiles it
                 describes are still never separated by a crash window.

                 EVERY part, where it used to be only the last. A download
                 cut short after part three now leaves a file that says what
                 it holds, which is what makes it resumable: the next run
                 finds this file by its id and carries on into it rather than
                 starting a second copy of the same country. It is also what
                 makes it removable, which tiles stranded in map.pmtiles by a
                 cancelled download never were.

                 Every part also DATES it, which is not the same choice.
                 Leaving the date off until the last part looked better --
                 an unfinished download would say "age unknown" and the UI
                 already draws that as "needs updating" -- but the last part
                 of a finished download routinely writes nothing at all: the
                 parts overlap at their seams, and by the time the last one
                 is planned its tiles are already on disk. It would have
                 dated finished downloads as unfinished, which is the wrong
                 lie of the two. What is missing from an interrupted region
                 is a question the map already answers, in the coverage
                 shading over the ground it does not have.

                 One entry, because one file is one region -- there is no
                 other record in here to merge with. [bytes] is what the
                 network delivered, the number the estimate quoted, not the
                 archive bytes copied while merging. *)
              let metadata =
                if target = World then base_meta
                else
                  let e =
                    entry ~completed:stamp
                      ~bytes:(!fetched_total + mp.Pmtiles.Merge.fetch_bytes)
                  in
                  match Ledger.to_metadata [ e ] ~previous:base_meta with
                  | Ok m -> m
                  | Error m -> failwith m
              in
              ignore
                (Pmtiles.Merge.write ~metadata mp h ~min_zoom:min_zoom'
                   ~max_zoom:max_zoom' ~min_lon ~min_lat ~max_lon ~max_lat
                   ~append ~copy));
          (* The last blob almost never lands on the throttle's boundary, so
             the part's final numbers are published here rather than left at
             whatever the last multiple of [progress_every] happened to
             say. *)
          publish ();
          Eio.Path.rename (part_path ()) Eio.Path.(dir / !archive_file);
          wrote_any := true;
          published := true;
          written_total := !written_total + total;
          fetched_total := !fetched_total + mp.Pmtiles.Merge.fetch_bytes
        end)
      units;
    if not !found_tiles then failwith "the source has no tiles in that area";
    (* Nothing written means every tile asked for was already in the file
       this run would have joined, which is the honest "you already have
       this" -- and the same sentence for a region as for the overview.

       This used to be a whole second path. The record could outlive the
       tiles by a part, or an archive from before the ledger existed had to
       be adopted, and both were settled by rewriting a gigabyte file to
       change its metadata. The record rides with the tiles in every part
       now, so there is nothing left to catch up with. *)
    if not !wrote_any then raise Already_held;
    (* An update normally rewrites the file it came from: the same regions
       hash to the same id, so [archive_file] above found it. It only
       differs when the granted depth changed -- a budget raised or lowered
       between the two runs -- and then the old file is a duplicate of what
       was just written, under a name that no longer describes it. *)
    (match replaces with
    | Some old_id when old_id <> entry_id ->
        Eio.Switch.run (fun psw ->
            match home_of ~sw:psw ~fs ~basemap_dir ~id:old_id with
            | Some (f, _) when Tile_set.is_region f -> (
                try Eio.Path.unlink Eio.Path.(dir / f)
                with e ->
                  Logs.warn (fun m ->
                      m "could not remove the updated region's old file %s: %s"
                        f (Printexc.to_string e)))
            (* In the merged archive, where nothing removes anything: taking
               one entry out of map.pmtiles means rewriting the file the whole
               map stands on, which is exactly what [run_remove] refuses to
               do. The old row stays listed beside the new one, and only a
               file manager can take it away. *)
            | _ -> ())
    | _ -> ());
    prune_cache t ~fs ~basemap_dir ~regions:recorded;
    (* Marked only once it has actually happened: a prune that raised left
       the cache untouched (it publishes by rename), so the terminal handler
       should still get its attempt. *)
    pruned := true;
    fetch_assets t ~sw ~net ~assets ~dir;
    (* Last, because it reads the finished archive: the names a region can
       offer are only knowable once its tiles are on disk.

       Its failure -- including a cancel arriving while it runs -- must not
       reach the terminal handlers below. By this point every tile is on
       disk and the ledger entry is published: the download DID happen, and
       reporting it as cancelled because the index was interrupted would be
       a lie the ledger immediately contradicts. A missing index costs
       search, not the map. *)
    (try reindex t ~fs ~basemap_dir with
    | Cancelled_by_user ->
        Logs.info (fun m -> m "search index skipped: cancelled")
    | e ->
        Logs.warn (fun m ->
            m "search index build failed: %s" (Printexc.to_string e)));
    (!written_total, parts_total)
  with
  | answer -> answer
  | exception e ->
      (* This run's own tidying, whoever is going to set the terminal state:
         the .part is dead weight and the browse cache still has to be pruned
         of whatever earlier parts already published. *)
      discard_part ();
      prune_published ();
      raise e

(* One region download, start to finish, with its terminal state. *)
let run_download t ~fs ~net ~source ?origin ~assets ~basemap_dir ~budget ~name
    ~now ~refresh ~replaces ~target ?whole_source reqs =
  terminate t ~fs ~basemap_dir
    ~ok:(fun (total_bytes, parts) -> Basemap_job.Done { total_bytes; parts })
    (fun () ->
      merge_source t ~fs ~net ~source ?origin ~assets ~basemap_dir ~budget
        ~name ~now ~refresh ~replaces ~target ?whole_source reqs)

(* ----------------------------------------------------------------- remove *)

(* Taking one downloaded region away. Never touches the network.

   An unlink, and nothing else. The record lives inside the file it
   describes, so the two leave together: there is nothing to rewrite, nothing
   to interrupt and no progress to report. That is the point of one file per
   region.

   An entry that lives in the old merged map.pmtiles is refused instead of
   removed, and there is no second path for it. Taking one entry out of that
   file means rewriting the whole archive without its tiles -- or unlinking
   the archive when the last entry goes -- and that archive is the map the
   rest of the application is standing on: what tools/fetch-basemap.sh
   writes, what installs from before the per-region split grew, and the file
   every merged entry shares tiles with. Destroying it to satisfy a Remove
   button on a row called "Map view" is the bug the refusal exists for. The
   machinery that used to do it sat below an earlier guard that could never
   let anything reach it, so it was eighty-five lines that could not run.

   The line is therefore where an entry LIVES, not what it covers. A download
   made today wrote its own file and is removable by unlinking that file,
   which touches nothing else. *)
let run_remove t ~fs ~basemap_dir ~id =
  let dir = Eio.Path.(fs / basemap_dir) in
  terminate t ~fs ~basemap_dir
    ~ok:(fun freed_bytes -> Basemap_job.Removed { freed_bytes })
  @@ fun () ->
  let freed_bytes =
    Eio.Switch.run @@ fun sw ->
    (* First, and by name, because the overview is now IN the list the id
       came from. It has no record, so [home_of] would answer None and this
       would come back as "no such downloaded map" -- true of the record and
       false of the map, on a row the user can see. *)
    if id = overview_id then
      failwith
        "the world overview is the map underneath every region and cannot \
         be removed";
    match home_of ~sw ~fs ~basemap_dir ~id with
    | None -> failwith "no such downloaded map"
    | Some (file, _) when file = base_file ->
        failwith
          "that map is part of the base map this server is drawing from and \
           cannot be removed here"
    (* Not [file <> base_file]. The difference is the world overview: a
       negative test would send it down whichever branch it was not.
       [Tile_set.is_region] is the one place that says what may be deleted,
       and anything that is neither a region nor the merged archive is
       refused below rather than guessed at. *)
    | Some (file, _) when Tile_set.is_region file ->
        let freed =
          match Eio.Path.stat ~follow:true Eio.Path.(dir / file) with
          | st -> Optint.Int63.to_int st.Eio.File.Stat.size
          | exception Eio.Io _ -> 0
        in
        Eio.Path.unlink Eio.Path.(dir / file);
        freed
    | Some (file, _) ->
        (* Unreachable while [homes] reads only the downloaded archives, and
           written anyway: this is the sentence that has to stay true if that
           ever changes. A file the map stands on is not a download, and a
           request to remove one is refused rather than obeyed. *)
        failwith
          (Printf.sprintf "%s is part of the basemap and cannot be removed"
             file)
  in
  (* The removed region's names must stop being findable, and a search hit
     flying the map to tiles that are gone is worse than no hit. *)
  (try reindex t ~fs ~basemap_dir
   with e ->
     (* Keeping the old index would leave the removed region's names
        findable. Better nothing than stale. *)
     Logs.warn (fun m ->
         m "search index rebuild failed, dropping it: %s"
           (Printexc.to_string e));
     Place_index.remove ~fs ~basemap_dir);
  freed_bytes

(* ----------------------------------------------------------------- export *)

(* Writing one recorded region out as a file to carry to another machine.

   This is the removal machinery pointed somewhere harmless. Removal prunes
   the archive down to the tiles an entry does NOT cover and renames the
   result over map.pmtiles; an export prunes down to the tiles it DOES cover
   and writes that beside it. The live archive is opened read-only and never
   renamed, so an export that dies halfway costs a partial file in the export
   directory and nothing the user was using.

   The exported archive carries a ledger of its own holding just that entry.
   That is what makes the trip survivable: the machine importing it reads the
   region, the granted depth, the name and the build it came from out of the
   file itself. Nothing has to be typed in on the far side, and a region
   cannot arrive as an anonymous box that the importer has to guess at. *)


let export_path ~fs ~basemap_dir name =
  Eio.Path.(fs / basemap_dir / export_dir_name / name)

let run_export t ~fs ~basemap_dir ~id =
  let dir = Eio.Path.(fs / basemap_dir / export_dir_name) in
  (* The .part this run is writing, once it knows what it is called -- the
     name comes out of the entry, so it is not known until the entry is
     found. Discarded on every exit that is not a completed export.

     Left behind, it is invisible and permanent: [exports_json] lists only
     names ending in .pmtiles, so the UI never shows it, and [delete_export]
     checks the name against that same listing, so nothing can remove it
     either. A cancelled export of a country therefore leaked a gigabyte that
     only a file manager could find -- on the machine least likely to have the
     disk to spare. *)
  let part = ref None in
  let discard () =
    match !part with
    | Some p -> ( try Eio.Path.unlink p with _ -> ())
    | None -> ()
  in
  terminate t ~fs ~basemap_dir ~discard
    ~ok:(fun (file, bytes) -> Basemap_job.Exported { file; bytes })
  @@ fun () ->
  Eio.Switch.run @@ fun sw ->
    (* Nothing to hand over. Every package ships an overview, so the machine
       this file would be carried to already has one, and copying tens of
       megabytes onto a stick to deliver what came in the installer is not a
       favour. Refused here as well as hidden in the UI: the id is visible
       now, so the button not being there is no longer the whole answer. *)
    if id = overview_id then
      failwith
        "the world overview ships with every install and does not need \
         carrying";
    match home_of ~sw ~fs ~basemap_dir ~id with
    | None -> failwith "no such downloaded map"
    | Some (file, _) when Tile_set.is_region file ->
        (* Nothing to do. The download wrote this file and nothing has
           merged it into anything since, so the file to carry to the other
           machine is already sitting there, already named after the region
           and the day it was fetched, and already reachable at
           /basemap/<file>. This is the whole point of one file per region:
           the wait that used to sit between "downloaded" and "can I have
           it" was the cost of undoing a merge that no longer happens. *)
        let bytes =
          match Eio.Path.stat ~follow:true Eio.Path.(fs / basemap_dir / file) with
          | st -> Optint.Int63.to_int st.Eio.File.Stat.size
          | exception Eio.Io _ -> 0
        in
        (file, bytes)
    | Some (file, _) when file <> base_file ->
        (* Same refusal as removal's, for the same reason: whatever the map
           stands on is not somebody's download to be handed out under a
           region's name. *)
        failwith
          (Printf.sprintf "%s is part of the basemap, not a downloaded region"
             file)
    | Some _ -> (
    match open_base ~sw ~fs ~basemap_dir with
    | None -> failwith "there is no downloaded map to export"
    | Some b -> (
        let _base_meta, led = base_ledger (Some b) in
        match Ledger.find led ~id with
        | None -> failwith "no such downloaded map"
        | Some entry ->
            let file = region_filename ~entry ~id in
            let out_path = Eio.Path.(dir / file) in
            let part_path = Eio.Path.(dir / (file ^ ".part")) in
            part := Some part_path;
            (* Everything this entry does not cover is dropped, which is the
               whole archive minus one region. *)
            let drop = Ledger.outside ~entry in
            let pruned, _dropped =
              Pmtiles.Merge.prune ~on_entry:(breathe ~cancel:t ()) ~base:b
                ~drop ()
            in
            if Array.length pruned.Pmtiles.Merge.tiles = 0 then
              failwith
                "that map has no tiles of its own to export -- every tile it \
                 covers belongs to another region too";
            (* A ledger of one. The importing machine reads this and knows
               what it was handed; [previous] is "{}" rather than the live
               archive's metadata because none of the OTHER entries' records
               may travel in a file that holds none of their tiles. *)
            let metadata =
              match Ledger.to_metadata [ entry ] ~previous:"{}" with
              | Ok m -> m
              | Error m -> failwith m
            in
            Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 dir;
            let total = pruned.Pmtiles.Merge.total_bytes in
            set t (Basemap_job.Exporting { done_bytes = 0; total_bytes = total });
            let bh = b.Pmtiles.Archive.header in
            (* The exported header describes the REGION, not the archive it
               came out of: an importer reads these bounds to decide what it
               is being offered, and the live archive's box is every region
               the user ever downloaded. *)
            let r_min_lon, r_min_lat, r_max_lon, r_max_lat =
              union_boxes
                (List.map
                   (fun (r : Basemap_job.request) ->
                     (r.min_lon, r.min_lat, r.max_lon, r.max_lat))
                   entry.Ledger.regions)
            in
            let r_depth =
              List.fold_left
                (fun acc (r : Basemap_job.request) -> max acc r.max_zoom)
                bh.Pmtiles.Header.min_zoom entry.Ledger.regions
            in
            let written = ref 0 in
            let new_header = ref None in
            Eio.Path.with_open_out ~create:(`Or_truncate 0o644) part_path
              (fun out ->
                let append str = Eio.Flow.copy_string str out in
                let copy ~index:_ ~origin:_ ~offset ~length =
                  check_cancel t;
                  Eio.Flow.copy_string
                    (b.Pmtiles.Archive.src.Pmtiles.Archive.read ~offset ~length)
                    out;
                  written := !written + length;
                  set t
                    (Basemap_job.Exporting
                       { done_bytes = min !written total; total_bytes = total })
                in
                new_header :=
                  Some
                    (Pmtiles.Merge.write ~metadata pruned bh
                       ~min_zoom:bh.Pmtiles.Header.min_zoom ~max_zoom:r_depth
                       ~min_lon:(Float.max r_min_lon (Degrees.of_e7 bh.Pmtiles.Header.min_lon_e7))
                       ~min_lat:(Float.max r_min_lat (Degrees.of_e7 bh.Pmtiles.Header.min_lat_e7))
                       ~max_lon:(Float.min r_max_lon (Degrees.of_e7 bh.Pmtiles.Header.max_lon_e7))
                       ~max_lat:(Float.min r_max_lat (Degrees.of_e7 bh.Pmtiles.Header.max_lat_e7))
                       ~append ~copy));
            (* Renamed only once whole, exactly as a download is: a half
               written export that looked like a finished one would be
               carried to an offline machine and fail there, which is the
               worst place to discover it. *)
            Eio.Path.rename part_path out_path;
            let bytes =
              match !new_header with
              | Some (nh : Pmtiles.Header.t) ->
                  nh.Pmtiles.Header.data_offset + nh.Pmtiles.Header.data_length
              | None -> !written
            in
            (file, bytes)))

let start_export t ~sw ~fs ~basemap_dir ~id =
  start_job t ~sw (fun () -> run_export t ~fs ~basemap_dir ~id)

(* What is sitting in the export directory, so the UI can offer the files
   for saving and say how much disk they are holding. Listed from the
   directory rather than remembered in the job: exports outlive the run that
   made them, which is the point -- a user collects several over an evening
   and copies them all to a stick at the end. *)
let exports_json ~fs ~basemap_dir =
  let dir = Eio.Path.(fs / basemap_dir / export_dir_name) in
  let names =
    match Eio.Path.read_dir dir with
    | names -> List.sort String.compare names
    | exception _ -> []
  in
  `List
    (List.filter_map
       (fun name ->
         if not (Filename.check_suffix name ".pmtiles") then None
         else
           match Eio.Path.stat ~follow:true Eio.Path.(dir / name) with
           | stat when stat.Eio.File.Stat.kind = `Regular_file ->
               Some
                 (`Assoc
                    [
                      ("file", `String name);
                      ( "bytes",
                        `Int (Optint.Int63.to_int stat.Eio.File.Stat.size) );
                    ])
           | _ -> None
           | exception _ -> None)
       names)

(* Deleting one export. The name is checked against the directory listing
   rather than trusted: it arrives from a request, and a name is the one
   thing here that could reach outside the export directory if it held a
   separator. *)
let delete_export ~fs ~basemap_dir ~file =
  let dir = Eio.Path.(fs / basemap_dir / export_dir_name) in
  let listed =
    match Eio.Path.read_dir dir with names -> names | exception _ -> []
  in
  if not (List.mem file listed) then Error "no such export"
  else
    match Eio.Path.unlink Eio.Path.(dir / file) with
    | () -> Ok ()
    | exception e -> Error (friendly e)

(* ----------------------------------------------------------------- import *)

(* Taking a map file someone carried here on a stick and folding it in.

   The trick is that this is not a new kind of download -- it is the ordinary
   one with a different source. [Pmtiles_source.open_url] already falls
   through to a plain file for anything that is not an http URL, and
   [run_download] already merges from whatever source it is handed. So an
   import is: receive the bytes, then run the download that was always
   there, pointed at the file instead of at a planet build on the internet.

   Everything downstream therefore comes free and stays identical to a
   networked download -- the merge that keeps what is already on disk, the
   ledger entry, the browse-cache prune, the search index rebuild. There is
   no second code path to keep in step, which matters more here than
   anywhere: the machine doing this is the one with no way to fetch a fix.

   Two steps, not one. The bytes land first and are described back to the
   user -- what regions, how deep, how big -- and only then does a second
   request commit them. A multi-gigabyte file that turns out to be the wrong
   country should cost a glance, not a merge. *)

let import_dir_name = "import"
let staged_file = "staged.pmtiles"
let staged_path ~fs ~basemap_dir = Eio.Path.(fs / basemap_dir / import_dir_name / staged_file)

(* Where the staged file lives, as the string [run_download] wants for a
   source. Built from the same pieces as the path above so the two cannot
   drift apart. *)
let staged_source ~basemap_dir =
  List.fold_left Filename.concat basemap_dir [ import_dir_name; staged_file ]

(* Receiving the upload. Streamed straight to disk under a .part name: the
   file is the size of a country and must never be held in memory, and a
   dropped connection must not leave something that looks like a finished
   import.

   [expected] is what Content-Length promised. A body that stops short is
   refused rather than kept, because a truncated PMTiles archive answers
   every directory lookup and fails half its reads -- it would import
   cleanly and then draw holes.

   One at a time, and never beside a job. Two uploads at once opened this same
   .part with [Or_truncate] and both wrote from byte zero, interleaving
   megabyte chunks; each counted only ITS bytes against ITS Content-Length, so
   both length checks passed over a file that was neither archive, and the
   result was renamed to staged.pmtiles and merged as garbage tiles. An upload
   arriving while an import merge is reading the staged file replaces that
   file underneath it. Both are refused rather than queued: a queue here means
   a socket held open for as long as somebody else's gigabyte takes, and the
   client can try again in a moment.

   The seat is its own flag rather than a job state, because receiving bytes
   is not a job -- it reports no progress, writes nothing a map is drawn from,
   and must not show up in the status a poller reads as a download. *)
let receive_import t ~fs ~basemap_dir ~expected ~read =
  let claimed =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        if t.staging || Basemap_job.is_running t.job then false
        else begin
          t.staging <- true;
          true
        end)
  in
  if not claimed then
    Error (Busy "the map is busy; try the upload again shortly")
  else
    Fun.protect
      ~finally:(fun () ->
        Eio.Mutex.use_rw ~protect:true t.mutex (fun () -> t.staging <- false))
      (fun () ->
        let dir = Eio.Path.(fs / basemap_dir / import_dir_name) in
        Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 dir;
        let part = Eio.Path.(dir / (staged_file ^ ".part")) in
        let discard () = try Eio.Path.unlink part with _ -> () in
        match
          let received = ref 0 in
          Eio.Path.with_open_out ~create:(`Or_truncate 0o644) part (fun out ->
              let buf = Cstruct.create (1 lsl 20) in
              let rec pump () =
                match read buf with
                | 0 -> ()
                | n ->
                    Eio.Flow.copy_string
                      (Cstruct.to_string (Cstruct.sub buf 0 n))
                      out;
                    received := !received + n;
                    pump ()
                | exception End_of_file -> ()
              in
              pump ());
          !received
        with
        | received when received <> expected ->
            discard ();
            Error
              (Rejected
                 (Printf.sprintf
                    "the upload stopped early: %d bytes arrived of the %d it \
                     declared"
                    received expected))
        | _ -> (
            (* Whether it is a map at all, decided before it is published
               under a name the commit will trust. *)
            match
              Eio.Switch.run @@ fun sw ->
              let file = Eio.Path.open_in ~sw part in
              Pmtiles.Archive.open_ (Pmtiles_source.file_source file)
            with
            | _archive ->
                Eio.Path.rename part (staged_path ~fs ~basemap_dir);
                Ok ()
            | exception _ ->
                discard ();
                Error (Rejected "that file is not a PMTiles map archive"))
        | exception e ->
            discard ();
            Error (Rejected (friendly e)))

(* What is sitting staged, described from the file itself.

   The regions come out of the exported archive's own ledger, which is what
   makes the far side of the trip need no typing: the file says which places
   it holds, how deep, and what it was called. A file from somewhere else --
   any valid PMTiles archive -- has no ledger, and is described by its header
   instead, as one box at whatever depth it reaches. *)
let import_summary ~fs ~basemap_dir =
  match
    Eio.Switch.run @@ fun sw ->
    let path = staged_path ~fs ~basemap_dir in
    let stat = Eio.Path.stat ~follow:true path in
    let file = Eio.Path.open_in ~sw path in
    let archive = Pmtiles.Archive.open_ (Pmtiles_source.file_source file) in
    let h = archive.Pmtiles.Archive.header in
    let entries =
      match Ledger.of_metadata (Pmtiles.Archive.metadata archive) with
      | Ok l -> l
      | Error _ -> []
    in
    (stat, h, entries)
  with
  | stat, h, entries ->
      let named =
        match entries with
        | [] -> None
        | e :: _ -> Some e.Ledger.name
      in
      let regions =
        match entries with
        | [] ->
            [
              `Assoc
                [
                  ("min_lon", `Float (Degrees.of_e7 h.Pmtiles.Header.min_lon_e7));
                  ("min_lat", `Float (Degrees.of_e7 h.Pmtiles.Header.min_lat_e7));
                  ("max_lon", `Float (Degrees.of_e7 h.Pmtiles.Header.max_lon_e7));
                  ("max_lat", `Float (Degrees.of_e7 h.Pmtiles.Header.max_lat_e7));
                  ("max_zoom", `Int h.Pmtiles.Header.max_zoom);
                ];
            ]
        | l -> List.concat_map (fun e -> List.map Ledger.json_of_region e.Ledger.regions) l
      in
      Ok
        (`Assoc
           [
             ("staged", `Bool true);
             ( "name",
               match named with Some n -> `String n | None -> `Null );
             ("bytes", `Int (Optint.Int63.to_int stat.Eio.File.Stat.size));
             ("min_zoom", `Int h.Pmtiles.Header.min_zoom);
             ("max_zoom", `Int h.Pmtiles.Header.max_zoom);
             ("tiles", `Int h.Pmtiles.Header.addressed_tiles);
             ("regions", `List regions);
           ])
  | exception _ -> Ok (`Assoc [ ("staged", `Bool false) ])

let discard_import ~fs ~basemap_dir =
  (try Eio.Path.unlink (staged_path ~fs ~basemap_dir) with _ -> ());
  Ok ()

(* Merging what was staged.

   The regions and their names come from the staged file's ledger, so an
   imported region lands in this machine's ledger under the name it was
   exported as -- listed, updatable and removable exactly like one that was
   downloaded here.

   Three shapes, and the difference between them is what the staged file says
   about itself.

   ONE record means this file already IS a region file: it is what a download
   writes and what an export hands over, and the way to import it is to put it
   where the others are. A rename, so importing a country is instant and costs
   no second copy of it -- which on the machine most likely to be short of
   disk is what matters. It lands under the name its own record gives it, so a
   file imported here and a file downloaded here are the same file with the
   same name, and one carried on to a third machine is the same again.

   SEVERAL records -- a legacy map.pmtiles someone copied off an old install
   -- is several regions, and each one is imported as itself. Folding them
   into a single entry took the name and the source of whichever happened to
   be first, labelled every progress bar with it, and wrote one combined
   record: importing an archive holding "Georgia" and "London" produced one
   row called Georgia, and London's name, date and byte count were gone for
   good, with both regions removable only as one blob.

   NO record is an archive from somewhere else, and it is merged whole -- see
   [merge_source]'s [whole_source], and the ledger-less region below.

   One terminal state for the lot, set by [terminate] here rather than by each
   merge, so a poller cannot see "done" between two of them. *)
let start_import t ~sw ~fs ~net ~basemap_dir ~budget ~now =
  (* An upload still landing would replace the staged file underneath this
     merge. Refused before the seat is claimed, so a refusal leaves no job
     behind to explain. *)
  if Eio.Mutex.use_ro t.mutex (fun () -> t.staging) then
    Error "a map file is still uploading; try again when it has finished"
  else
    start_job t ~sw @@ fun () ->
    let staged = staged_path ~fs ~basemap_dir in
    (* What the staged file was when this job started.
       Two things are decided by it, and both are about not destroying an
       upload. The staged file is removed only when the import actually
       succeeded -- a cancelled or failed merge leaves it where it is, so
       retrying costs nothing -- and only when it is still the same file this
       job opened, so a replacement uploaded meanwhile is never the one that
       gets deleted. *)
    let started_as =
      match Eio.Path.stat ~follow:true staged with
      | st -> Some (Tile_set.stamp_of st)
      | exception _ -> None
    in
    let consume_staged () =
      let still_ours =
        match (started_as, Eio.Path.stat ~follow:true staged) with
        | Some s, st -> s = Tile_set.stamp_of st
        | None, _ -> false
        | exception _ -> false
      in
      if still_ours then try Eio.Path.unlink staged with _ -> ()
    in
    terminate t ~fs ~basemap_dir
      ~ok:(fun (total_bytes, parts) -> Basemap_job.Done { total_bytes; parts })
    @@ fun () ->
    let entries =
      Eio.Switch.run @@ fun usw ->
      let archive =
        Pmtiles.Archive.open_
          (Pmtiles_source.file_source (Eio.Path.open_in ~sw:usw staged))
      in
      match Ledger.of_metadata (Pmtiles.Archive.metadata archive) with
      | Ok l -> (l, archive.Pmtiles.Archive.header)
      | Error m -> failwith m
    in
    let source = staged_source ~basemap_dir in
    let merge ~name ~origin ~whole_source regions =
      merge_source t ~fs ~net ~source ~origin
        (* No glyph fetch: see [fetch_assets]. *)
        ~assets:"" ~basemap_dir ~budget ~name:(Some name) ~now ~refresh:false
        ~replaces:None ~target:Detail ~whole_source regions
    in
    let result =
      match entries with
      | [], h ->
          (* Its header box at its own depth is the honest description of
             what it holds, and [whole_source] is what stops the network
             budget clamping it to something shallower. Nobody recorded where
             these tiles came from, so the origin stays blank rather than
             being invented. *)
          let r =
            {
              Basemap_job.min_lon = Degrees.of_e7 h.Pmtiles.Header.min_lon_e7;
              min_lat = Degrees.of_e7 h.Pmtiles.Header.min_lat_e7;
              max_lon = Degrees.of_e7 h.Pmtiles.Header.max_lon_e7;
              max_lat = Degrees.of_e7 h.Pmtiles.Header.max_lat_e7;
              max_zoom = h.Pmtiles.Header.max_zoom;
              polygon = None;
              label = None;
            }
          in
          merge ~name:(default_name [ r ]) ~origin:"" ~whole_source:true [ r ]
      | [ e ], _ ->
          let file = region_filename ~entry:e ~id:(Ledger.id e) in
          let bytes =
            Optint.Int63.to_int
              (Eio.Path.stat ~follow:true staged).Eio.File.Stat.size
          in
          Eio.Path.rename staged Eio.Path.(fs / basemap_dir / file);
          (* Same tail a download has, for the same reasons: a browsed copy of
             a tile this file now holds would shadow it forever, and the names
             it can offer are only findable once it is on disk. *)
          (try prune_cache t ~fs ~basemap_dir ~regions:e.Ledger.regions
           with err ->
             Logs.warn (fun m ->
                 m "browse cache prune failed: %s" (Printexc.to_string err)));
          (try reindex t ~fs ~basemap_dir
           with err ->
             Logs.warn (fun m ->
                 m "search index build failed: %s" (Printexc.to_string err)));
          (bytes, 1)
      | l, _ ->
          let landed = ref 0 in
          let bytes, parts =
            List.fold_left
              (fun (bytes, parts) (e : Ledger.entry) ->
                match
                  merge ~name:e.Ledger.name ~origin:e.Ledger.source
                    ~whole_source:false
                    (* The labels the exporting machine recorded travel with
                       the regions. An entry written before regions carried
                       them has none, and its own name is the only thing
                       anyone ever knew to call those boxes. *)
                    (List.map
                       (fun (r : Basemap_job.request) ->
                         match r.label with
                         | Some _ -> r
                         | None -> { r with label = Some e.Ledger.name })
                       e.Ledger.regions)
                with
                | b, p ->
                    incr landed;
                    (bytes + b, parts + p)
                (* One region of several already being on disk is not a
                   reason to abandon the others. Anything else -- a full
                   disk, an unreadable source -- stops the import, because
                   whatever it is applies to the records still to come. *)
                | exception Already_held -> (bytes, parts))
              (0, 0) l
          in
          if !landed = 0 then raise Already_held;
          (bytes, parts)
    in
    (* The staged file has done its job. Left behind it is a second copy of a
       country in the user's data directory, which on the machine most likely
       to be short of disk is the last thing to leave lying around -- but it
       goes ONLY here, on the success path, and only if it is still the file
       this job started from.

       It used to be unlinked on every outcome. Cancel a merge at 90% or run
       out of disk and the multi-gigabyte upload was gone, on the offline
       machine the two-step staging exists to spare that re-upload; and an
       upload that landed while the merge was running was deleted in place of
       the one the merge had been reading. *)
    consume_staged ();
    result

(* ----------------------------------------------------------------- browse *)

(* Folds the browse cache into the main archive: one merge whose "fresh"
   side is read from the cache file instead of the network, published under
   the same rename discipline as a download, ledger carried forward
   untouched -- browsed tiles stay anonymous. Claims the job (one
   map.pmtiles writer at a time); the caller skips folding when a download
   is running and tries again after a later browse. *)
let run_compact t ~fs ~basemap_dir =
  let dir = Eio.Path.(fs / basemap_dir) in
  let part_path = Eio.Path.(dir / "map.pmtiles.part") in
  let discard_part () = try Eio.Path.unlink part_path with _ -> () in
  match
    Eio.Switch.run @@ fun sw ->
    match open_cache ~sw ~fs ~basemap_dir with
    | None -> ()
    | Some _ when t.clear_requested ->
        (* Asked for between the fork and here: erase rather than fold, or
           the browsed tiles become permanent residents of the archive that
           no later erasing can reach. *)
        honor_clear t ~fs ~basemap_dir
    | Some cache ->
        let base = open_base ~sw ~fs ~basemap_dir in
        (* The fold stamps the cache's header over blobs copied verbatim
           from BOTH files. A compression mismatch -- the source changed
           schemes after the main archive was downloaded -- would relabel
           every pre-existing tile as something it is not, corrupting the
           whole archive in one silent rename. Refuse loudly instead. *)
        guard_compression ~h:cache.Pmtiles.Archive.header base;
        let base_meta, _ = base_ledger base in
        let fresh = plan_of_archive cache in
        let mp =
          Pmtiles.Merge.plan ~on_entry:(breathe ~cancel:t ()) ~base [ fresh ]
        in
        let total = mp.Pmtiles.Merge.total_bytes in
        set t (Basemap_job.Compacting { done_bytes = 0; total_bytes = total });
        let ch = cache.Pmtiles.Archive.header in
        let min_zoom', max_zoom', min_lon, min_lat, max_lon, max_lat =
          match base with
          | None ->
              ( ch.Pmtiles.Header.min_zoom,
                ch.Pmtiles.Header.max_zoom,
                Degrees.of_e7 ch.Pmtiles.Header.min_lon_e7,
                Degrees.of_e7 ch.Pmtiles.Header.min_lat_e7,
                Degrees.of_e7 ch.Pmtiles.Header.max_lon_e7,
                Degrees.of_e7 ch.Pmtiles.Header.max_lat_e7 )
          | Some b ->
              let bh = b.Pmtiles.Archive.header in
              ( min ch.Pmtiles.Header.min_zoom bh.Pmtiles.Header.min_zoom,
                max ch.Pmtiles.Header.max_zoom bh.Pmtiles.Header.max_zoom,
                Float.min
                  (Degrees.of_e7 ch.Pmtiles.Header.min_lon_e7)
                  (Degrees.of_e7 bh.Pmtiles.Header.min_lon_e7),
                Float.min
                  (Degrees.of_e7 ch.Pmtiles.Header.min_lat_e7)
                  (Degrees.of_e7 bh.Pmtiles.Header.min_lat_e7),
                Float.max
                  (Degrees.of_e7 ch.Pmtiles.Header.max_lon_e7)
                  (Degrees.of_e7 bh.Pmtiles.Header.max_lon_e7),
                Float.max
                  (Degrees.of_e7 ch.Pmtiles.Header.max_lat_e7)
                  (Degrees.of_e7 bh.Pmtiles.Header.max_lat_e7) )
        in
        Eio.Path.with_open_out ~create:(`Or_truncate 0o644) part_path
          (fun out ->
            let written = ref 0 in
            let append str = Eio.Flow.copy_string str out in
            let copy ~index:_ ~origin ~offset ~length =
              check_cancel t;
              let bytes =
                match origin with
                | Pmtiles.Merge.Base -> (
                    match base with
                    | Some b ->
                        b.Pmtiles.Archive.src.Pmtiles.Archive.read ~offset
                          ~length
                    | None -> assert false)
                | Pmtiles.Merge.Fresh ->
                    cache.Pmtiles.Archive.src.Pmtiles.Archive.read ~offset
                      ~length
              in
              Eio.Flow.copy_string bytes out;
              written := !written + length;
              set t
                (Basemap_job.Compacting
                   { done_bytes = min !written total; total_bytes = total })
            in
            ignore
              (Pmtiles.Merge.write ~metadata:base_meta mp ch
                 ~min_zoom:min_zoom' ~max_zoom:max_zoom' ~min_lon ~min_lat
                 ~max_lon ~max_lat ~append ~copy));
        (* The merged archive lands FIRST, and only then does the cache go.
           Do not swap these. A crash in this window leaves a cache holding
           tiles byte-identical to ones map.pmtiles now also holds: the
           endpoint serves the same bytes from either, the TileJSON folds
           to the same ranges, and the next browse past the threshold folds
           again and completes the unlink -- it self-heals, and costs
           nothing meanwhile. Unlinking first instead means a crash, or
           merely a failing rename, destroys every browsed tile while
           map.pmtiles is still the pre-fold archive. *)
        Eio.Path.rename part_path Eio.Path.(dir / "map.pmtiles");
        (* The fold is published; the leftover cache is the benign duplicate
           argued for above, so failing to remove it must not be reported as
           a failed compaction. *)
        (try Eio.Path.unlink Eio.Path.(dir / "cache.pmtiles") with _ -> ());
        (* Browsed tiles carry labels too, and they have just become part of
           the archive: without this, a place the user browsed to is on the
           map but not findable. *)
        (try reindex t ~fs ~basemap_dir with
        | Cancelled_by_user -> ()
        | e ->
            Logs.warn (fun m ->
                m "search index build failed: %s" (Printexc.to_string e)))
  with
  | () ->
      honor_clear t ~fs ~basemap_dir;
      set t Basemap_job.Idle
  | exception Cancelled_by_user ->
      discard_part ();
      honor_clear t ~fs ~basemap_dir;
      set t Basemap_job.Cancelled
  | exception e ->
      discard_part ();
      honor_clear t ~fs ~basemap_dir;
      set t (Basemap_job.Failed (friendly e))

(* One viewport's missing tiles, fetched into the cache. Opt-in (gated in
   the handler on the browse_cache setting), quiet, and bounded: a request
   naming too many tiles is refused rather than becoming a download in
   disguise -- the card is the place for those. *)
let max_browse_tiles = 1_024

(* The depth a browse can actually be served at: the view asks, the source
   decides. Named and separate because the answer travels back to the
   client, which compares it against the depth its map is showing -- a
   client that mistook its own request for what arrived would ask for a
   zoom the source cannot reach, forever. *)
let browse_zoom ~header ~requested =
  max header.Pmtiles.Header.min_zoom
    (min requested header.Pmtiles.Header.max_zoom)

let run_browse t ~sw ~fs ~net ~source ~basemap_dir ~budget
    (req : Basemap_job.request) =
  (* One browse at a time, and none while the archive writer is busy: a
     download prunes its region out of the cache when it completes, and a
     browse landing mid-prune would race the same file. *)
  let claimed =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        if t.browsing || Basemap_job.is_running t.job then false
        else begin
          t.browsing <- true;
          true
        end)
  in
  if not claimed then Error "the map is busy; try again shortly"
  else
    Fun.protect
      ~finally:(fun () ->
        release_browsing t;
        (* This fiber wrote the cache; it is the one that must erase it if
           the user switched browsing off while it was in flight. *)
        honor_clear t ~fs ~basemap_dir)
      (fun () ->
        match
          Eio.Switch.run @@ fun bsw ->
          let _resolved, src, archive = open_source ~sw:bsw ~fs ~net ~source in
          let h = archive.Pmtiles.Archive.header in
          let zoom = browse_zoom ~header:h ~requested:req.max_zoom in
          let ids =
            Pmtiles.Tile_id.count_ids ~min_zoom:zoom ~max_zoom:zoom
              ~min_lon:req.min_lon ~min_lat:req.min_lat ~max_lon:req.max_lon
              ~max_lat:req.max_lat
          in
          if ids > max_browse_tiles then
            failwith "the view is too wide to cache; zoom in"
          else begin
            let plan =
              Pmtiles.Extract.plan
                ~on_tile:(breathe ())
                archive ~min_zoom:zoom ~max_zoom:zoom ~min_lon:req.min_lon
                ~min_lat:req.min_lat ~max_lon:req.max_lon ~max_lat:req.max_lat
            in
            (* Every downloaded archive, not just the merged one: with a
               file per region, the tiles a browse must not re-fetch are
               spread across as many files as the user has kept.

               Each is carried with its header, because the held-check below
               runs per candidate tile and most archives cannot possibly hold
               any of them: a viewport is one place and the regions are twenty
               others. [Tile_set.may_hold] answers that from the header
               already in hand, which is exactly what the tile endpoint does
               before it opens anything -- without it a settled pan cost
               twenty directory walks per tile, nineteen of them over ground
               the archive does not cover. *)
            let downloaded =
              List.filter_map
                (fun (e : Tile_set.entry) ->
                  if e.Tile_set.name = cache_file || e.Tile_set.name = world_file
                  then None
                  else
                    Option.map
                      (fun a -> (e.Tile_set.header, a))
                      (open_readable ~sw:bsw ~fs ~basemap_dir e.Tile_set.name))
                (Tile_set.entries ~dir:Eio.Path.(fs / basemap_dir))
            in
            let cache = open_cache ~sw:bsw ~fs ~basemap_dir in
            (* Same refusal as a download's, and against the same two files:
               a source whose compression no longer matches what a browse
               would WRITE into must not write a single blob. That is the
               cache, whose header compaction later stamps over everything,
               and map.pmtiles, which is what compaction folds it into.

               Not the region files. Nothing merges those with anything, and
               each one is read through its own header, so two regions in two
               compressions are two files that both draw. Refusing a browse
               over that would be refusing on behalf of a merge that cannot
               happen. *)
            guard_compression ~h (open_base ~sw:bsw ~fs ~basemap_dir);
            guard_compression ~h cache;
            let held_in a id = Pmtiles.Archive.locate a id <> None in
            let held id =
              let z, x, y = Pmtiles.Tile_id.to_zxy id in
              (match cache with None -> false | Some c -> held_in c id)
              || List.exists
                   (fun (h, a) ->
                     Tile_set.may_hold h ~z ~x ~y && held_in a id)
                   downloaded
            in
            (* Tiles any archive holds are not fetched again; the tile
               endpoint already serves them. *)
            let wanted =
              Array.of_list
                (List.filter
                   (fun (id, _) -> not (held id))
                   (Array.to_list plan.Pmtiles.Extract.tiles))
            in
            if Array.length wanted = 0 then (0, zoom)
            else begin
              let filtered = { plan with Pmtiles.Extract.tiles = wanted } in
              let mp =
                Pmtiles.Merge.plan ~on_entry:(breathe ()) ~base:cache
                  [ filtered ]
              in
              let part_path =
                Eio.Path.(fs / basemap_dir / "cache.pmtiles.part")
              in
              ensure_dir Eio.Path.(fs / basemap_dir);
              Eio.Path.with_open_out ~create:(`Or_truncate 0o644) part_path
                (fun out ->
                  let append str = Eio.Flow.copy_string str out in
                  let copy ~index:_ ~origin ~offset ~length =
                    let bytes =
                      match origin with
                      | Pmtiles.Merge.Base -> (
                          match cache with
                          | Some c ->
                              c.Pmtiles.Archive.src.Pmtiles.Archive.read
                                ~offset ~length
                          | None -> assert false)
                      | Pmtiles.Merge.Fresh ->
                          src.Pmtiles.Archive.read ~offset ~length
                    in
                    Eio.Flow.copy_string bytes out
                  in
                  let u_min_lon, u_min_lat, u_max_lon, u_max_lat =
                    match cache with
                    | None -> (req.min_lon, req.min_lat, req.max_lon, req.max_lat)
                    | Some c ->
                        let chh = c.Pmtiles.Archive.header in
                        ( Float.min req.min_lon (Degrees.of_e7 chh.Pmtiles.Header.min_lon_e7),
                          Float.min req.min_lat (Degrees.of_e7 chh.Pmtiles.Header.min_lat_e7),
                          Float.max req.max_lon (Degrees.of_e7 chh.Pmtiles.Header.max_lon_e7),
                          Float.max req.max_lat (Degrees.of_e7 chh.Pmtiles.Header.max_lat_e7) )
                  in
                  let min_zoom' =
                    match cache with
                    | None -> zoom
                    | Some c -> min zoom c.Pmtiles.Archive.header.Pmtiles.Header.min_zoom
                  in
                  let max_zoom' =
                    match cache with
                    | None -> zoom
                    | Some c -> max zoom c.Pmtiles.Archive.header.Pmtiles.Header.max_zoom
                  in
                  ignore
                    (Pmtiles.Merge.write mp h ~min_zoom:min_zoom'
                       ~max_zoom:max_zoom' ~min_lon:u_min_lon
                       ~min_lat:u_min_lat ~max_lon:u_max_lon
                       ~max_lat:u_max_lat ~append ~copy));
              Eio.Path.rename part_path
                Eio.Path.(fs / basemap_dir / "cache.pmtiles");
              (mp.Pmtiles.Merge.fresh_tiles, zoom)
            end
          end
        with
        | (fetched, written_zoom) ->
            (* Fold the cache into the main archive once it outgrows the
               threshold -- unless a download holds the writer's seat, in
               which case a later browse will try again. Failures here stay
               here: a broken look at the cache must not fail the browse
               that already succeeded, and it must not escape as a dropped
               connection either. *)
            (if fetched > 0 && not t.clear_requested then
               try
                 Eio.Switch.run @@ fun csw ->
                 match open_cache ~sw:csw ~fs ~basemap_dir with
                 | Some c
                   when c.Pmtiles.Archive.header.Pmtiles.Header.data_length
                        > budget.compact ->
                     if claim t then
                       Eio.Fiber.fork ~sw (fun () ->
                           run_compact t ~fs ~basemap_dir)
                 | _ -> ()
               with
               | Eio.Cancel.Cancelled _ as e -> raise e
               | e ->
                 Logs.warn (fun m ->
                     m "compaction check failed: %s" (Printexc.to_string e)));
            Ok (fetched, written_zoom)
        | exception (Eio.Cancel.Cancelled _ as e) -> raise e
        | exception e ->
            (* The .part is dead weight the moment its browse dies; the
               file is also reachable under /basemap/, so litter is not
               merely untidy. *)
            (try
               Eio.Path.unlink Eio.Path.(fs / basemap_dir / "cache.pmtiles.part")
             with _ -> ());
            Error (friendly e))

(* Turning the browse setting off also forgets what was browsed: the cache
   is a record of the places the user looked at, and in a privacy-focused
   tool "off" should mean gone, not dormant. Tiles already folded into the
   main archive are past helping -- the hint text says as much.

   Never waits. The obvious spelling -- block until the in-flight browse
   finishes, then delete -- puts an unbounded network wait on a request the
   user is watching: a stalled upstream read would hang the settings
   response until the browser gave up, and the toggle would snap back to
   "on" over a setting the server had already saved. So a busy cache is
   marked instead, and whoever holds it erases it as it leaves. *)
let clear_cache t ~fs ~basemap_dir =
  if t.browsing || Basemap_job.is_running t.job then t.clear_requested <- true
  else unlink_cache ~fs ~basemap_dir

(* ------------------------------------------------------------- lifecycle *)

(* The overview covers the planet or it is not one.

   Checked rather than trusted because the client says which kind of download
   this is, and a half-planet written to world.pmtiles would be a file whose
   name is a lie -- the floor measurement would still be honest, since it
   counts tiles rather than reading the name, but every later reader of that
   file would be wrong about it. The world offer sends exactly this box.

   [Ledger.spans_regions] with no slack, because this is the strict half of a
   question the ledger's overview lock also asks: the two used to be separate
   predicates with separate thresholds, so a box starting at -179.5 longitude
   was the whole world to one of them and not to the other. *)
let covers_the_planet (reqs : Basemap_job.request list) =
  Ledger.spans_regions reqs

let start t ~sw ~fs ~net ~source ~assets ~basemap_dir ~budget ~name ~world ~now
    reqs =
  let target = if world then World else Detail in
  if world && not (covers_the_planet reqs) then
    Error "a world overview has to cover the whole world"
  else
    start_job t ~sw (fun () ->
        run_download t ~fs ~net ~source ~assets ~basemap_dir ~budget ~name ~now
          ~refresh:false ~replaces:None ~target reqs)

(* An update is the recorded download run again with the merge tie inverted:
   every tile in the region is fetched fresh and replaces its stale copy.
   The regions come from the ledger, and the run replaces the entry it came
   from by id -- explicitly, so a budget change that alters the granted
   depth cannot leave two records claiming the same place. *)
let start_update t ~sw ~fs ~net ~source ~assets ~basemap_dir ~budget ~now ~id =
  (* Before the seat is claimed, so a refusal costs nothing and leaves no
     job behind to explain. An update is a re-download of an entry's regions
     under its recorded name, and the overview has no entry: there is
     nothing to re-download and nothing to name it. Deepening the planet is
     a world download, which the card already offers in its own right. *)
  if id = overview_id then
    Error "the world overview is not updated from the downloads list"
  else
    start_job t ~sw @@ fun () ->
    match Eio.Switch.run @@ fun usw -> home_of ~sw:usw ~fs ~basemap_dir ~id with
    | None -> set t (Basemap_job.Failed "no such downloaded map")
    (* Same line as removal's, for a reason of its own: an update lands in a
       NEW file and leaves the merged row where it is, so the row would be
       duplicated by something that cannot then be undone -- the original is
       in the base archive and nothing removes from there. The button is gone
       from the card too. *)
    | Some (file, _) when file = base_file ->
        set t
          (Basemap_job.Failed
             "that map is part of the base map this server is drawing from \
              and is not updated from here")
    | Some (_, e) ->
        (* Updates come from ledger entries, and only the detail archive has
           one. The regions go back in as they were recorded, labels
           included: a download of "France and Germany" saved two boxes under
           the names the picker gave them, and an update redraws those two
           bars rather than two copies of the entry's own name -- which is
           what a synthesized list of identical labels produced, losing the
           per-region naming the feature exists for on every re-download.

           An entry written before regions carried labels has none, and then
           the entry's name is the only thing anyone ever knew to call those
           boxes. *)
        run_download t ~fs ~net ~source ~assets ~basemap_dir ~budget
          ~name:(Some e.Ledger.name) ~now ~refresh:true ~replaces:(Some id)
          ~target:Detail
          (List.map
             (fun (r : Basemap_job.request) ->
               match r.label with
               | Some _ -> r
               | None -> { r with label = Some e.Ledger.name })
             e.Ledger.regions)
    | exception e -> set t (Basemap_job.Failed (friendly e))

let start_remove t ~sw ~fs ~basemap_dir ~id =
  start_job t ~sw (fun () -> run_remove t ~fs ~basemap_dir ~id)

(* What the archive holds, for the UI's downloaded-maps list. Reading it
   opens the archive fresh each time -- a header and a metadata blob, not
   the tiles -- so the list is always what is on disk right now. *)
let ledger_json ~fs ~basemap_dir =
  match
    Eio.Switch.run @@ fun sw ->
    let led = homes ~sw ~fs ~basemap_dir in
    (* The map under the map, listed first because it is underneath.

       It has no ledger record and never will -- packages ship it, the
       extraction tool writes it, and the world download merges into it
       without recording anything -- so this row is assembled from the file
       itself: its size on disk and the depth its header claims. Everything
       a record would supply is absent and says so. [completed] is 0, which
       the page already renders as "age unknown"; the source is empty
       because nothing wrote down where this one came from.

       Listing it is the fix for a real complaint, and the complaint was not
       that a button was wrong. Leaving the overview out meant the panel's
       answer to "what maps do I have" omitted the largest and most
       important file on disk, so a small download named for the viewport
       read as the world map, and its Remove button as the button that
       deletes the world. A row with a size and no verbs answers the
       question and closes the door in the same line. *)
    let overview =
      List.filter_map
        (fun (e : Tile_set.entry) ->
          if e.Tile_set.name <> world_file then None
          else
            Some
              (`Assoc
                 [
                   ("id", `String overview_id);
                   ("file", `String "");
                   (* Named by the page, not here. A row the user reads has
                      to be in the user's language, and this server has no
                      opinion about which that is. *)
                   ("name", `String "");
                   ("completed", `Int 0);
                   ("source", `String "");
                   ("bytes", `Int e.Tile_set.size);
                   ("regions", `Int 1);
                   ("overview", `Bool true);
                   ( "max_zoom",
                     `Int e.Tile_set.header.Pmtiles.Header.max_zoom );
                 ]))
        (Tile_set.entries ~dir:Eio.Path.(fs / basemap_dir))
    in
    `Assoc
      [
        (* Whether there is a map on disk at all, which is NOT whether the
           ledger has entries. A world overview fetched with the extraction
           tool writes no entry and is still a drawn, labelled planet, and
           the setup docs make fetching one step 1 -- so a banner reading
           "no basemap found" over it would be contradicting the map behind
           it. Answered here rather than by the page probing for files,
           because a probe for one that is absent is a 404 in the console on
           a supported configuration. *)
        ( "held",
          `Bool
            (List.exists
               (fun name -> name <> cache_file)
               (tile_files ~fs ~basemap_dir)) );
        ( "entries",
          `List
            (overview
            @ List.map
               (fun (file, (e : Ledger.entry)) ->
                 `Assoc
                   [
                     ("id", `String (Ledger.id e));
                     (* The file this region's tiles are in, which is the
                        file to carry away: a download IS its own archive
                        now, so there is nothing to build and nothing to
                        wait for. Empty for a region still living inside the
                        old merged map.pmtiles, which has to be extracted
                        out of it -- the export path below, kept for exactly
                        that case. *)
                     ( "file",
                       `String (if file = base_file then "" else file) );
                     ("name", `String e.Ledger.name);
                     ("completed", `Int e.Ledger.completed);
                     ("source", `String e.Ledger.source);
                     ("bytes", `Int e.Ledger.bytes);
                     ("regions", `Int (List.length e.Ledger.regions));
                     (* The row is real and its tiles are really there, so
                        it is listed and can still be brought up to date --
                        but it is the ground under everything else, and the
                        UI must not offer to take it away. Sent as a fact
                        about the entry rather than left for the page to
                        work out, so the two locks agree on one answer. *)
                     ("overview",
                       `Bool (file = base_file && Ledger.spans_world e));
                     ( "max_zoom",
                       `Int
                         (List.fold_left
                            (fun acc (r : Basemap_job.request) ->
                              max acc r.max_zoom)
                            0 e.Ledger.regions) );
                   ])
               led) );
      ]
  with
  | json -> Ok json
  | exception e -> Error (friendly e)

(* ------------------------------------------------------------- coverage *)

(* Where the map goes blank, and how deep it goes where it does not.

   One question about one viewport: which of its tiles this server can
   actually serve, answered with a directory lookup each and no tile bytes
   read at all. The map draws whatever the tile endpoint returns, so this
   asks the same archives in the same order -- browse cache first, then the
   main one -- rather than reading the ledger. The ledger is a different
   thing: it records what was ASKED for. An archive seeded by the
   extraction tool holds tiles no entry claims, browsed tiles belong to no
   entry at all, and a mask drawn from the ledger would grey out places the
   user can plainly see drawn -- which is worse than saying nothing, the
   state this replaces.

   Bounded by construction: a viewport is a few dozen tiles at its own
   zoom, and a query for more than [max_coverage_tiles] is refused rather
   than answered slowly. *)

let max_coverage_tiles = 4096

(* The deepest zoom the DOWNLOADED archives reach, and [None] when there
   are none of them at all.

   Separate from the floor's depth, which is about the overview underneath.
   This one answers "how deep does detail go", and it is the question the
   coverage clamp below needs. *)
let detail_depth ~sw ~fs ~basemap_dir =
  match
    List.filter_map (open_readable ~sw ~fs ~basemap_dir)
      (detail_files ~fs ~basemap_dir)
  with
  | [] -> None
  | archives ->
      Some
        (List.fold_left
           (fun acc (a : Pmtiles.Archive.t) ->
             max acc a.Pmtiles.Archive.header.Pmtiles.Header.max_zoom)
           0 archives)

let coverage ~fs ~basemap_dir (req : Basemap_job.request) =
  (* The zoom the map is DISPLAYING, carried in [max_zoom] because that is
     the field a validated request has; nothing here downloads.

     Clamped HERE rather than by the client, and that is the whole of this
     fix. Past a source's own depth MapLibre stops asking for more and
     overzooms the deepest tiles it has, so a query at the camera zoom
     would report a blank that is not on screen -- the clamp is real and
     has to happen somewhere. It used to happen in the browser, against the
     depth `/tiles.json` advertised, which forced that number to lie: an
     archive with no detail in it had to claim depth 15 or the clamp
     dragged every question down to the floor's zoom, where the overview
     answers "present" and the offer to download this area never appears.
     One number cannot both tell MapLibre what to request and tell this
     query what to ask about.

     So the client sends the zoom it is really looking at, and the answer
     is clamped against the archives that actually hold detail. With none
     of them the camera zoom stands, which is the honest reading: there is
     no detail at any zoom, and the note that says so is exactly what a
     fresh install needs to see. *)
  let z =
    match
      Eio.Switch.run (fun sw -> detail_depth ~sw ~fs ~basemap_dir)
    with
    | Some deepest -> min req.max_zoom deepest
    | None -> req.max_zoom
    | exception _ -> req.max_zoom
  in
  let last = (1 lsl z) - 1 in
  let grid v = max 0 (min last v) in
  (* The same floor arithmetic [Tile_id.covering] plans with, so a cell
     means the tile the map will ask for rather than its neighbour. *)
  let x0 = grid (Pmtiles.Tile_id.tile_x ~z ~lon:req.min_lon)
  and x1 = grid (Pmtiles.Tile_id.tile_x ~z ~lon:req.max_lon)
  and y0 = grid (Pmtiles.Tile_id.tile_y ~z ~lat:req.max_lat)
  and y1 = grid (Pmtiles.Tile_id.tile_y ~z ~lat:req.min_lat) in
  let w = x1 - x0 + 1 and h = y1 - y0 + 1 in
  if w * h > max_coverage_tiles then
    Error
      (Too_large
         (Printf.sprintf "a coverage query covers at most %d tiles"
            max_coverage_tiles))
  else
    match
      Eio.Switch.run @@ fun sw ->
      (* The tile endpoint's own list, in its own order -- though an
         existence test cannot tell the difference. What makes this agree
         with what the map is served is not the order but that
         [Archive.tile] IS [locate] followed by a read: the same directory
         walk, the same run-length entries, the same nested leaves.

         The world floor counts. It is a real tile the map really draws, so
         calling it absent would wash a drawn map grey and offer a download
         for something already on screen. *)
      let archives =
        List.filter_map (open_readable ~sw ~fs ~basemap_dir)
          (tile_files ~fs ~basemap_dir)
      in
      let held ~z ~x ~y =
        let id = Pmtiles.Tile_id.of_zxy ~z ~x ~y in
        List.exists (fun a -> Pmtiles.Archive.locate a id <> None) archives
      in
      (* Row-major from the north-west corner, one character per tile: the
         client draws rectangles from it, and a string survives a JSON
         round trip without a base64 step on either side. *)
      let present = Buffer.create (w * h) in
      for y = y0 to y1 do
        for x = x0 to x1 do
          Buffer.add_char present (if held ~z ~x ~y then '1' else '0')
        done
      done;
      (* How deep the archive goes under the middle of the view.

         Measured at the centre of the middle CELL of the rectangle above,
         not at the midpoint of the requested degrees. Those are different
         tiles surprisingly often -- Mercator is not linear in latitude and
         the viewport's edges fall at arbitrary points inside their tiles --
         and when they disagreed, the client could be told the middle of
         its view was blank while the depth described the tile next door.
         The descent starts at the zoom asked about rather than at the
         archive's own depth, which makes the answer an exact statement
         about the middle cell: depth = zoom means that cell is held, and
         anything less means it is not, with the number saying how far out
         the map still has something. Starting deeper would let a partial
         archive report a depth ABOVE a zoom it has no tile at, and the
         client would then have a blank middle and a depth denying it. *)
      let cx = x0 + (w / 2) and cy = y0 + (h / 2) in
      let cl, cb, cr, ct = Pmtiles.Tile_id.tile_box ~z ~x:cx ~y:cy in
      let lon = (cl +. cr) /. 2. and lat = (cb +. ct) /. 2. in
      let rec depth_at zd =
        if zd < 0 then -1
        else
          let n = (1 lsl zd) - 1 in
          let clamp v = max 0 (min n v) in
          if
            held ~z:zd
              ~x:(clamp (Pmtiles.Tile_id.tile_x ~z:zd ~lon))
              ~y:(clamp (Pmtiles.Tile_id.tile_y ~z:zd ~lat))
          then zd
          else depth_at (zd - 1)
      in
      (* Whether the map underneath draws here at all, which is NOT what
         [depth] says.

         A one-city archive holds the single zoom-0 tile of the whole
         planet, so its depth over Tokyo is 0 -- and whether anything is
         drawn there depends on the floor covering the planet at that zoom,
         which is a fact about the whole archive rather than about this
         view. Told only the depth, the client would promise "this is the
         wider map" over ground with no wider map on it. *)
      let floor_here =
        floor_depth
          (whole_archives ~sw ~fs ~basemap_dir (tile_files ~fs ~basemap_dir))
        >= 0
      in
      `Assoc
        [
          ("zoom", `Int z);
          ("x", `Int x0);
          ("y", `Int y0);
          ("w", `Int w);
          ("h", `Int h);
          ("present", `String (Buffer.contents present));
          ("floor", `Bool floor_here);
          ("depth", `Int (depth_at z));
        ]
    with
    | json -> Ok json
    | exception e -> Error (Unreadable (friendly e))

let ops t ~sw ~fs ~net ~source ~assets ~basemap_dir ~budget ~now =
  {
    estimate =
      (fun ~world reqs ->
        estimate ~fs ~net ~source ~basemap_dir ~budget ~world reqs);
    start =
      (fun ~name ~world reqs ->
        start t ~sw ~fs ~net ~source ~assets ~basemap_dir ~budget ~name ~world
          ~now reqs);
    cancel = (fun () -> cancel t);
    status = (fun () -> status t);
    ledger = (fun () -> ledger_json ~fs ~basemap_dir);
    update =
      (fun ~id ->
        start_update t ~sw ~fs ~net ~source ~assets ~basemap_dir ~budget ~now
          ~id);
    remove = (fun ~id -> start_remove t ~sw ~fs ~basemap_dir ~id);
    export = (fun ~id -> start_export t ~sw ~fs ~basemap_dir ~id);
    exports = (fun () -> exports_json ~fs ~basemap_dir);
    delete_export = (fun ~file -> delete_export ~fs ~basemap_dir ~file);
    receive =
      (fun ~expected ~read ->
        receive_import t ~fs ~basemap_dir ~expected ~read);
    staged =
      (fun () ->
        match import_summary ~fs ~basemap_dir with
        | Ok j -> j
        | Error _ -> `Assoc [ ("staged", `Bool false) ]);
    import = (fun () -> start_import t ~sw ~fs ~net ~basemap_dir ~budget ~now);
    discard_import = (fun () -> discard_import ~fs ~basemap_dir);
    browse =
      (fun req -> run_browse t ~sw ~fs ~net ~source ~basemap_dir ~budget req);
    clear_cache = (fun () -> clear_cache t ~fs ~basemap_dir);
    coverage = (fun req -> coverage ~fs ~basemap_dir req);
    search =
      (fun ~query ~limit ->
        match Place_index.search ~fs ~basemap_dir ~query ~limit with
        | results -> Ok (Place_index.to_json results)
        | exception e -> Error (friendly e));
  }
