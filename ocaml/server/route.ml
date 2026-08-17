(* Request target -> what to do about it. Pure, so the routing table is
   testable without binding a socket.

   The effectful layer resolves [Asset] and [Basemap] against the filesystem;
   this module only decides which root a target belongs to and whether the
   segments are safe to open. *)

type t =
  | Health
  | Asset of string list  (** under the UI root *)
  | Basemap of string list  (** under the basemap root *)
  | Api of string  (** the API sub-path, e.g. "session" *)
  | Not_found
  | Method_not_allowed

(* Under the mount prefix [p], the remaining segments, if the target is under
   it at all. *)
let strip_prefix p segments =
  match segments with
  | first :: rest when String.equal first p -> Some rest
  | _ -> None

let of_request ~meth ~target =
  let readable = match meth with `GET | `HEAD -> true | _ -> false in
  match Url_path.resolve target with
  | None -> Not_found
  | Some segments -> (
      match strip_prefix "healthz" segments with
      | Some [] -> if readable then Health else Method_not_allowed
      | Some _ -> Not_found
      | None -> (
          match strip_prefix "api" segments with
          | Some [ endpoint ] ->
              if meth = `POST then Api endpoint else Method_not_allowed
          | Some _ -> Not_found
          | None -> (
              match strip_prefix "basemap" segments with
              | Some [] -> Not_found
              | Some rest -> if readable then Basemap rest else Method_not_allowed
              | None -> if readable then Asset segments else Method_not_allowed)))

(* A path with no extension is a client-side route -- the UI is a single-page
   app, so `/about` must return index.html rather than 404, or a reload of any
   deep link breaks. A missing `.js` is a genuine 404 and must stay one. *)
let is_spa_fallback segments =
  match List.rev segments with
  | [] -> true
  | last :: _ -> String.equal (Url_path.extension last) ""
