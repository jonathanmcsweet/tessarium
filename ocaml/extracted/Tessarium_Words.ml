open Prims
type byte = Prims.nat
type word = byte Prims.list
let rec is_prefix (typed : word) (w : word) : Prims.bool=
  match (typed, w) with
  | ([], uu___) -> true
  | (uu___::uu___1, []) -> false
  | (a::typed', b::w') -> (a = b) && (is_prefix typed' w')
let rec exact (typed : word) (words : word Prims.list) (base : Prims.nat) :
  Prims.nat FStar_Pervasives_Native.option=
  match words with
  | [] -> FStar_Pervasives_Native.None
  | w::rest ->
      if w = typed
      then FStar_Pervasives_Native.Some base
      else exact typed rest (base + Prims.int_one)
let rec matching (typed : word) (words : word Prims.list) (base : Prims.nat)
  : Prims.nat Prims.list=
  match words with
  | [] -> []
  | w::rest ->
      if is_prefix typed w
      then base :: (matching typed rest (base + Prims.int_one))
      else matching typed rest (base + Prims.int_one)
let min_abbrev : Prims.nat= Prims.of_int 4
let resolve (typed : word) (words : word Prims.list) :
  Prims.nat FStar_Pervasives_Native.option=
  match exact typed words Prims.int_zero with
  | FStar_Pervasives_Native.Some i -> FStar_Pervasives_Native.Some i
  | FStar_Pervasives_Native.None ->
      if (FStar_List_Tot_Base.length typed) < min_abbrev
      then FStar_Pervasives_Native.None
      else
        (match matching typed words Prims.int_zero with
         | i::[] -> FStar_Pervasives_Native.Some i
         | uu___ -> FStar_Pervasives_Native.None)
