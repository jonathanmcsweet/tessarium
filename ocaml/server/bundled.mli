(** The map a package ships, copied into the directory the app writes to. *)

val entries : string list
(** What a bundle holds, and the only names [seed] will copy. *)

val default_dir : unit -> string
(** Where a packaged build keeps its bundle, derived from the running
    executable: [<prefix>/bin/tessarium-server] gives
    [<prefix>/share/tessarium/basemap]. A source build resolves this to a
    directory that does not exist, which [seed] treats as nothing to do. *)

val seed : fs:_ Eio.Path.t -> from:string -> into:string -> unit
(** Copy every entry of [from] that [into] does not already have. Never
    overwrites, never partially publishes, and does nothing at all when
    [from] is not a directory. Failures are logged, not raised: a map that
    could not be seeded is a worse first run, not a reason to refuse to
    start. *)
