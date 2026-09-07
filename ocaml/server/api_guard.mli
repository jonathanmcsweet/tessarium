(** Everything a request must pass before an /api/ handler sees it.

    [t] is abstract and only this module builds one, so a handler that takes
    a [t] cannot run without the checks. They used to be three branches in
    one match, which held only as long as nobody reordered it, added a route
    below them, or wrote a second dispatch. A new endpoint that skips them
    now fails to compile.

    Draining lives here too. A refused request still has to come off the
    socket, or the next request on a keep-alive connection starts parsing
    mid-body. That was got wrong twice while these checks were written, once
    for the origin check and once for the size bound. *)

type t

(** The body, already bounded. *)
val body : t -> string

type refusal =
  | From_another_site
      (** A page on another origin sent it. The browser sets the headers
          this is decided by; a page cannot forge them. *)
  | Not_json
      (** text/plain, form-urlencoded and multipart are the three types a
          page can post with no preflight, so JSON is required: the browser
          then has to ask permission first, and nothing here answers. *)
  | Too_large  (** past [max_body], or an upload that declared no size *)
  | Not_binary
      (** an upload that was not application/octet-stream. Same reasoning as
          [Not_json], for the route that takes bytes instead. *)

(** Whether the refused body could be taken off the socket. An oversized one
    cannot be, and then the only safe answer is to close the connection. *)
type disposal = Drained | Connection_must_close

type outcome = Allowed of t | Refused of refusal * disposal

(** 4 MiB. The realistic worst case is near 250 KB: every region the UI
    knows about, polygons included, selected at once. *)
val max_body : int

(** [read ()] takes the body off the socket, answering [None] if it is over
    [max_body]. It is called at most once, and only when [declares_body]. *)
val check :
  header:(string -> string option) ->
  declares_body:bool ->
  read:(unit -> string option) ->
  outcome

type stream
(** An upload that passed the same-origin and content-type checks and
    declared its size. Abstract for the same reason [t] is: the route that
    streams a file to disk cannot be reached without them. *)

val check_stream :
  header:(string -> string option) -> declares_body:bool -> (stream, refusal) result

val declared_length : stream -> int
(** What Content-Length said. Checked against the disk before a byte is
    written, and against the bytes actually received afterwards. *)

(** Exposed for the tests, which spell out what a browser sends. Neither is
    needed to use this module. *)
val from_another_site : (string -> string option) -> bool

val is_json : (string -> string option) -> bool
