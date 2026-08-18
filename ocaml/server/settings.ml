(* One user preference so far: how old a downloaded region may grow before
   the UI suggests updating it. Server-side, in the basemap directory,
   because the browser deliberately persists nothing -- the e2e suite
   asserts an empty localStorage, and that assertion is worth more than a
   convenient place to stash a number.

   A sidecar file rather than archive metadata on purpose: toggling a
   preference must not rewrite a multi-gigabyte archive. Unlike the ledger
   there is nothing here the archive must stay consistent with. *)

type t = { update_reminder_days : int }

let default = { update_reminder_days = 90 }
let filename = "settings.json"

(* 0 is "never remind"; ten years is as good as never but keeps the number
   honest in a UI that displays it. *)
let valid_days d = d >= 0 && d <= 3650

let to_json t : Yojson.Safe.t =
  `Assoc [ ("update_reminder_days", `Int t.update_reminder_days) ]

let of_json = function
  | `Assoc fields -> (
      match List.assoc_opt "update_reminder_days" fields with
      | Some (`Int d) when valid_days d -> Ok { update_reminder_days = d }
      | Some _ -> Error "update_reminder_days must be 0..3650"
      | None -> Error "missing update_reminder_days")
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

(* The two operations the API exposes, bound to a directory. *)
type ops = {
  get : unit -> (Yojson.Safe.t, string) result;
  set : int -> (Yojson.Safe.t, string) result;
}

let ops ~fs ~basemap_dir =
  {
    get = (fun () -> Result.map to_json (load ~fs ~basemap_dir));
    set =
      (fun days ->
        if not (valid_days days) then
          Error "update_reminder_days must be 0..3650"
        else begin
          let t = { update_reminder_days = days } in
          save ~fs ~basemap_dir t;
          Ok (to_json t)
        end);
  }
