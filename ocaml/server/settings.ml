(* User preferences for the map archives. Server-side, in the basemap
   directory, because the browser deliberately persists nothing -- the e2e
   suite asserts an empty localStorage, and that assertion is worth more
   than a convenient place to stash two values.

   A sidecar file rather than archive metadata on purpose: toggling a
   preference must not rewrite a multi-gigabyte archive. Unlike the ledger
   there is nothing here the archive must stay consistent with. *)

type t = {
  update_reminder_days : int;
      (** how old a downloaded region may grow before the UI suggests
          updating it; 0 is "never remind" *)
  browse_cache : bool;
      (** whether missing viewport tiles are fetched and kept while
          browsing online. Off by default, deliberately: a privacy-focused
          offline tool must not phone home while panning without being
          asked. *)
}

let default = { update_reminder_days = 90; browse_cache = false }
let filename = "settings.json"

(* 0 is "never remind"; ten years is as good as never but keeps the number
   honest in a UI that displays it. *)
let valid_days d = d >= 0 && d <= 3650

let to_json t : Yojson.Safe.t =
  `Assoc
    [
      ("update_reminder_days", `Int t.update_reminder_days);
      ("browse_cache", `Bool t.browse_cache);
    ]

let of_json = function
  | `Assoc fields -> (
      let days =
        match List.assoc_opt "update_reminder_days" fields with
        | Some (`Int d) when valid_days d -> Ok d
        | Some _ -> Error "update_reminder_days must be 0..3650"
        | None -> Error "missing update_reminder_days"
      in
      (* Absent means off: that is every settings.json written before the
         browse cache existed. *)
      let browse =
        match List.assoc_opt "browse_cache" fields with
        | Some (`Bool b) -> Ok b
        | Some _ -> Error "browse_cache must be a boolean"
        | None -> Ok false
      in
      match (days, browse) with
      | Ok update_reminder_days, Ok browse_cache ->
          Ok { update_reminder_days; browse_cache }
      | Error e, _ | _, Error e -> Error e)
  | _ -> Error "settings must be an object"

let of_string s =
  match Yojson.Safe.from_string s with
  | exception _ -> Error "settings.json is not JSON"
  | j -> of_json j

let to_string t = Yojson.Safe.to_string (to_json t)

(* Missing means default -- that is every installation from before the file
   existed. Unreadable means exactly that, out loud: guessing a default over
   a corrupt file would silently discard whatever the user had chosen. *)
let load ~fs ~basemap_dir =
  let path = Eio.Path.(fs / basemap_dir / filename) in
  match Eio.Path.kind ~follow:true path with
  | `Regular_file ->
      Result.map_error
        (Printf.sprintf "%s: %s" filename)
        (of_string (Eio.Path.load path))
  | _ -> Ok default

let save ~fs ~basemap_dir t =
  let dir = Eio.Path.(fs / basemap_dir) in
  (match Eio.Path.kind ~follow:true dir with
  | `Directory -> ()
  | _ -> Eio.Path.mkdir ~perm:0o755 dir);
  let part = Eio.Path.(dir / (filename ^ ".part")) in
  Eio.Path.save ~create:(`Or_truncate 0o644) part (to_string t);
  Eio.Path.rename part Eio.Path.(dir / filename)

(* Read-modify-write: the API may set either field alone, and a partial
   update must not reset the other to its default. *)
let apply t ~days ~browse =
  let t = match days with Some d -> { t with update_reminder_days = d } | None -> t in
  match browse with Some b -> { t with browse_cache = b } | None -> t

(* The operations the API exposes, bound to a directory. *)
type ops = {
  get : unit -> (Yojson.Safe.t, string) result;
  set :
    days:int option -> browse:bool option -> (Yojson.Safe.t, string) result;
  browse_enabled : unit -> bool;
}

let ops ~fs ~basemap_dir =
  let get_t () = load ~fs ~basemap_dir in
  (* One writer at a time. [set] is a read-modify-write of a shared file,
     and the reminder select and the browse toggle are separate controls a
     quick user can fire together: unserialized, the later save silently
     reverts the earlier field, and two bodies interleaving through the
     same .part file can leave settings.json unparseable -- which [load]
     deliberately refuses to paper over. *)
  let write_lock = Eio.Mutex.create () in
  {
    get = (fun () -> Result.map to_json (get_t ()));
    set =
      (fun ~days ~browse ->
        Eio.Mutex.use_rw ~protect:true write_lock @@ fun () ->
        match days with
        | Some d when not (valid_days d) ->
            Error "update_reminder_days must be 0..3650"
        | _ -> (
            match get_t () with
            | Error _ as e -> e |> Result.map to_json
            | Ok current -> (
                let t = apply current ~days ~browse in
                match save ~fs ~basemap_dir t with
                | () -> Ok (to_json t)
                | exception e ->
                    Error
                      (match e with
                      | Failure m -> m
                      | e -> Printexc.to_string e))));
    browse_enabled =
      (fun () ->
        match get_t () with Ok t -> t.browse_cache | Error _ -> false);
  }
