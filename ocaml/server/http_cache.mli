(** Conditional requests: entity-tags, [If-None-Match] and [If-Range]. Pure.

    Everything here is [cache-control: no-cache] apart from the content-hashed
    bundle Vite emits, and that is deliberate -- a browse-cache download
    changes tiles under the same URL, and a rebuild changes the UI under the
    same URL. But [no-cache] on its own does not mean "revalidate cheaply", it
    means "ask again"; and with no validator attached, "ask again" is answered
    in full every time. This module supplies the validator, so the same
    freshness rule costs an empty 304 instead of a megabyte.

    ETags only, no [Last-Modified]. [If-None-Match] takes precedence over
    [If-Modified-Since] wherever both appear (RFC 9110 13.1.3), so sending a
    second validator we would then have to ignore buys nothing and invites the
    belief that it is honoured. *)

val of_bytes : encoding:string option -> string -> string
(** The tag for a representation we are holding in full: a hash of the bytes,
    plus the [Content-Encoding] the response will carry. The encoding is part
    of the tag because gzipped and identity bodies are different
    representations of one resource and must not share a validator. *)

val of_digest : encoding:string option -> string -> string
(** The same, from a hash computed elsewhere -- the embedded UI assets, whose
    digests are fixed when the binary is linked. Hashing the 5 MB core on
    every request to say "unchanged" would be its own kind of waste. Takes the
    full hex; the truncation lives here, so both paths shorten it the same
    way. *)

val of_stamp : key:string -> size:int -> mtime:float -> string
(** The tag for a representation we are streaming off disk and will not read
    twice to hash. Path, size and modification time: the size and time are the
    approximation every static file server makes -- not a proof of
    byte-identity, but they change whenever the file is rewritten -- and the
    path is there so that two files written in the same instant at the same
    length are still two tags. *)

val is_fresh : if_none_match:string option -> etag:string -> bool
(** Whether the client already holds this representation, and so should be
    answered [304] with no body. Weak comparison, as [If-None-Match] requires:
    [W/"x"] and ["x"] are the same cache entry. *)

val range_is_current : if_range:string option -> etag:string -> bool
(** Whether a [Range] may be honoured. [If-Range] means "send me the window if
    what you have is still what I have, and the whole thing otherwise", and it
    compares STRONGLY -- a weak tag never matches, because a weak tag admits
    that the bytes may have moved and a partial response is exactly where that
    matters. No [If-Range] at all means yes. *)
