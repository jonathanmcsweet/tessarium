let () =
  let key =
    Tessarium.derive_key ~kdf:Tessarium_argon2.kdf
      ~mnemonic:
        "legal winner thank year wave sausage worth useful legal winner thank \
         year wave sausage worth useful legal winner thank year wave sausage \
         worth title"
      ~passphrase:""
  in
  let n = 20_000 in
  let t0 = Unix.gettimeofday () in
  for i = 0 to n - 1 do
    ignore
      (Tessarium.encode_z ~key
         ~lat:(Z.of_int (511111111 + i))
         ~lon:(Z.of_int (-131111111 + i)))
  done;
  let dt = Unix.gettimeofday () -. t0 in
  Printf.printf "%d encodes in %.3f s = %.1f us each\n" n dt (dt /. float_of_int n *. 1e6)
