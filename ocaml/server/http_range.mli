(** RFC 9110 byte ranges, single-range only. Pure. *)

type span = { first : int; last : int }  (** both inclusive *)

type t =
  | Whole  (** serve the whole representation: 200 *)
  | Partial of span  (** 206 *)
  | Unsatisfiable  (** 416 *)

val length_of : span -> int

val parse : header:string option -> length:int -> t
(** [parse ~header ~length] interprets a [Range] header against a
    representation of [length] bytes. A malformed or multi-range header yields
    [Whole], which is a correct response rather than an error. *)

val content_range : span -> length:int -> string
(** The [Content-Range] value for a 206. *)

val unsatisfiable_content_range : length:int -> string
(** The [Content-Range] value for a 416. *)
