open Prims
type byte = Prims.nat
let nul : byte= Prims.int_zero
let hash : byte= Prims.of_int 35
let pct : byte= Prims.of_int 37
let dot : byte= Prims.of_int 46
let slash : byte= Prims.of_int 47
let question : byte= Prims.of_int 63
let backslash : byte= Prims.of_int 92
let rec query_stripped (p : byte Prims.list) : byte Prims.list=
  match p with
  | [] -> []
  | b::tl ->
      if (b = question) || (b = hash) then [] else b :: (query_stripped tl)
let hex_val (b : byte) : Prims.nat FStar_Pervasives_Native.option=
  if (b >= (Prims.of_int 48)) && (b <= (Prims.of_int 57))
  then FStar_Pervasives_Native.Some (b - (Prims.of_int 48))
  else
    if (b >= (Prims.of_int 97)) && (b <= (Prims.of_int 102))
    then FStar_Pervasives_Native.Some (b - (Prims.of_int 87))
    else
      if (b >= (Prims.of_int 65)) && (b <= (Prims.of_int 70))
      then FStar_Pervasives_Native.Some (b - (Prims.of_int 55))
      else FStar_Pervasives_Native.None
let rec percent_decode (p : byte Prims.list) :
  byte Prims.list FStar_Pervasives_Native.option=
  match p with
  | [] -> FStar_Pervasives_Native.Some []
  | b::tl ->
      if b <> pct
      then
        (match percent_decode tl with
         | FStar_Pervasives_Native.None -> FStar_Pervasives_Native.None
         | FStar_Pervasives_Native.Some r ->
             FStar_Pervasives_Native.Some (b :: r))
      else
        (match tl with
         | hi::lo::rest ->
             (match ((hex_val hi), (hex_val lo)) with
              | (FStar_Pervasives_Native.Some h, FStar_Pervasives_Native.Some
                 l) ->
                  (match percent_decode rest with
                   | FStar_Pervasives_Native.None ->
                       FStar_Pervasives_Native.None
                   | FStar_Pervasives_Native.Some r ->
                       FStar_Pervasives_Native.Some
                         (((h * (Prims.of_int 16)) + l) :: r))
              | uu___ -> FStar_Pervasives_Native.None)
         | uu___ -> FStar_Pervasives_Native.None)
let rec split_slash (p : byte Prims.list) : byte Prims.list Prims.list=
  match p with
  | [] -> [[]]
  | b::tl ->
      let r = split_slash tl in
      if b = slash
      then [] :: r
      else (b :: (FStar_List_Tot_Base.hd r)) :: (FStar_List_Tot_Base.tl r)
let segments (p : byte Prims.list) : byte Prims.list Prims.list=
  FStar_List_Tot_Base.filter (fun s -> Prims.uu___is_Cons s) (split_slash p)
let safe (s : byte Prims.list) : Prims.bool=
  match s with
  | [] -> false
  | d::uu___ ->
      ((d <> dot) && (Prims.op_Negation (FStar_List_Tot_Base.mem nul s))) &&
        (Prims.op_Negation (FStar_List_Tot_Base.mem backslash s))
let opens_under_root (s : byte Prims.list) : Prims.bool=
  (((((Prims.uu___is_Cons s) &&
        (Prims.op_Negation (FStar_List_Tot_Base.mem slash s)))
       && (Prims.op_Negation (FStar_List_Tot_Base.mem backslash s)))
      && (Prims.op_Negation (FStar_List_Tot_Base.mem nul s)))
     && (s <> [dot]))
    && (s <> [dot; dot])
let names_no_dotfile (s : byte Prims.list) : Prims.bool=
  match s with | [] -> false | d::uu___ -> d <> dot
let index_html : byte Prims.list=
  [Prims.of_int 105;
  Prims.of_int 110;
  Prims.of_int 100;
  Prims.of_int 101;
  Prims.of_int 120;
  Prims.of_int 46;
  Prims.of_int 104;
  Prims.of_int 116;
  Prims.of_int 109;
  Prims.of_int 108]
let resolve (target : byte Prims.list) :
  byte Prims.list Prims.list FStar_Pervasives_Native.option=
  match percent_decode (query_stripped target) with
  | FStar_Pervasives_Native.None -> FStar_Pervasives_Native.None
  | FStar_Pervasives_Native.Some path ->
      let segs = segments path in
      if FStar_List_Tot_Base.for_all safe segs
      then
        (match segs with
         | [] -> FStar_Pervasives_Native.Some [index_html]
         | uu___ -> FStar_Pervasives_Native.Some segs)
      else FStar_Pervasives_Native.None
