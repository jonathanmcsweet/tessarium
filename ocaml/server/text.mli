(** Splitting a string at a delimiter. Pure.

    Seven modules here were each spelling out [String.index_opt] followed by
    two [String.sub] calls with hand-computed lengths, which is where an
    off-by-one hides. The vocabulary is Bünzli's [astring]: [cut] returns the
    two halves without the separator, or [None] when there is none to cut at.
*)

val cut : char -> string -> (string * string) option
(** [cut sep s] is the text before and after the FIRST [sep] in [s], neither
    half including it. [None] when [s] holds no [sep]. *)

val rcut : char -> string -> (string * string) option
(** [rcut sep s] is [cut] at the LAST [sep] instead of the first. *)

val before : char -> string -> string
(** [before sep s] is the text up to the first [sep], or all of [s] when there
    is none. *)
