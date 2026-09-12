let cut sep s =
  Option.map
    (fun i ->
      (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1)))
    (String.index_opt s sep)

let rcut sep s =
  Option.map
    (fun i ->
      (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1)))
    (String.rindex_opt s sep)

let before sep s = Option.fold ~none:s ~some:fst (cut sep s)
