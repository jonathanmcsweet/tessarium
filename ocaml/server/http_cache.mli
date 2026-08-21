(** Conditional requests: entity-tags and [If-None-Match]. Pure.

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
(** The tag for a representation we are holding in full: a hash of the exact
    bytes that go on the wire. [encoding] is the [Content-Encoding] the
    response will carry; it is part of the tag because gzipped and identity
    bodies are different representations of one resource and must not share
    a validator. *)

val of_digest : encoding:string option -> string -> string
(** The tag for a representation whose hash was computed at build time -- the
    embedded UI assets, which are fixed when the binary is linked. Hashing the
    5 MB core on every request to say "unchanged" would be its own kind of
    waste. *)

val of_stamp : encoding:string option -> size:int -> mtime:float -> string
(** The tag for a representation we are streaming off disk and will not read
    twice to hash. Size and modification time, the same approximation every
    static file server makes: not a proof of byte-identity, but it changes
    whenever the file is rewritten. *)

val is_fresh : if_none_match:string option -> etag:string -> bool
(** Whether the client already holds this representation, and so should be
    answered [304] with no body. Weak comparison, as [If-None-Match] requires:
    [W/"x"] and ["x"] are the same cache entry. *)
