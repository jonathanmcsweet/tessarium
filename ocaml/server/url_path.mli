(** Turning a request target into a path we are willing to open.

    This is what stops [GET /../../etc/passwd], and the decision is not made
    here: {!resolve} wraps [Tessarium_UrlPath.resolve], extracted from F*, where
    two theorems are proved of it. Every segment it accepts is non-empty, is
    neither ["."] nor [".."], and carries no ['/'], ['\\'] or NUL; and a target
    that DECODES to a traversal is refused however it was spelled.

    Everything below {!resolve} is hand-written and trusted. The proof covers
    which files may be opened, not what is said about them afterwards, and
    {!content_type} is not a cosmetic decision -- a wrong type on a script is a
    security question. *)

val resolve : string -> string list option
(** [resolve target] is the path segments to open under the asset root, or
    [None] for a target we refuse. A directory target resolves to [index.html],
    so the app is reachable at ["/"].

    Targets longer than 8 KiB are refused unread. That is a resource limit
    rather than a safety one -- the proved resolver is linear in a list of boxed
    bytes, and this runs on every request before the rate limiter. *)

val extension : string -> string
(** [extension name] is the lowercased final extension including its dot, or
    [""] when there is none. *)

val content_type : string -> string
(** The [Content-Type] for a filename. An unknown extension is
    [application/octet-stream] deliberately, rather than a guess. *)

val cache_control : string list -> string
(** The [Cache-Control] for a resolved path. Content-hashed filenames (Vite's
    [index-D4ipvZ4X.js]) are immutable forever; everything else must be
    revalidated, or a rebuild is invisible. *)

val bytes_of_string : string -> Z.t list
(** The octets of a request target, as the proved resolver takes them. *)

val string_of_bytes : Z.t list -> string
(** The inverse. Walks the list once: written the obvious way, with [List.nth]
    inside [String.init], it is quadratic -- 4 KB of path took 6.6 ms against 20
    us for this -- and it runs on every request.

    Both conversions are public so the test suite can hold this wrapper to the
    proved module's own predicates. *)
