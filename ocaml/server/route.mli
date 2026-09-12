(** Request target -> what to do about it. Pure: no socket, no filesystem.

    Which root a target belongs to, and whether its method is allowed. The
    effectful layer does the opening; nothing here touches disk. *)

type t =
  | Health
  | Asset of string list  (** under the UI root *)
  | Basemap of string list  (** under the basemap root *)
  | Tile of { z : int; x : int; y : int }  (** one vector tile *)
  | Tile_json of { floor : bool }
      (** source metadata for MapLibre: the detail that was downloaded, or
          the shallow floor underneath it when [floor] *)
  | Api of string  (** the API sub-path, e.g. ["session"] *)
  | Import  (** an uploaded archive, streamed to disk rather than buffered *)
  | Not_found
  | Method_not_allowed

val of_request : meth:Cohttp.Code.meth -> target:string -> t
(** [of_request ~meth ~target] classifies one request. The target is resolved
    through {!Url_path.resolve} first, so a traversal is [Not_found] however
    it was spelled.

    A known path reached with the wrong method is [Method_not_allowed] rather
    than [Not_found]: only reads may be [`GET]/[`HEAD], only [/api/*] and
    [/import] may be [`POST]. A prefix matched but not completed ([/api],
    [/tiles]) is [Not_found] -- it names no endpoint under any method. *)

val is_basemap_api : string -> bool
(** Whether an {!Api} endpoint belongs to the basemap UI rather than to the
    opt-in encode/decode API, and so stays reachable with [--api] off. These
    carry a bounding box and no key material. *)

val is_spa_fallback : string list -> bool
(** Whether a missing asset should serve index.html instead of 404. True for
    a path with no extension, which is a client-side route: [/about] must
    survive a reload. A missing [.js] is a real 404. *)
