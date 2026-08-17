(* gzip, in one place.

   Three callers need it and they would otherwise each carry their own copy of
   decompress's refill/flush plumbing: PMTiles directories arrive gzipped, the
   embedded UI assets are stored gzipped, and the server has to decompress them
   again for the rare client that will not accept gzip. *)

let chunked ~f data =
  let i = De.bigstring_create De.io_buffer_size in
  let o = De.bigstring_create De.io_buffer_size in
  let out = Buffer.create (String.length data) in
  let pos = ref 0 in
  let refill buf =
    let len = min (String.length data - !pos) De.io_buffer_size in
    Bigstringaf.blit_from_string data ~src_off:!pos buf ~dst_off:0 ~len;
    pos := !pos + len;
    len
  in
  let flush buf len = Buffer.add_string out (Bigstringaf.substring buf ~off:0 ~len) in
  f ~refill ~flush ~i ~o;
  Buffer.contents out

exception Bad_gzip of string

let decompress data =
  let result = ref (Ok ()) in
  let out =
    chunked ~f:(fun ~refill ~flush ~i ~o ->
        match Gz.Higher.uncompress ~refill ~flush i o with
        | Ok _ -> ()
        | Error (`Msg m) -> result := Error m)
      data
  in
  match !result with Ok () -> out | Error m -> raise (Bad_gzip m)

(* Level 9, and a fixed timestamp: output has to be identical across builds or
   an embedded asset makes the binary irreproducible for no reason. *)
let compress ?(level = 9) data =
  let w = De.Lz77.make_window ~bits:15 in
  let q = De.Queue.create 0x1000 in
  let cfg = Gz.Higher.configuration Gz.Unix (fun () -> 0l) in
  chunked
    ~f:(fun ~refill ~flush ~i ~o ->
      Gz.Higher.compress ~w ~q ~level ~refill ~flush () cfg i o)
    data
