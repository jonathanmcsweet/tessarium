(lang dune 3.6)
(name tessarium)

(generate_opam_files true)

(source (uri "https://github.com/tessarium/tessarium"))
(license Apache-2.0)

(package
 (name tessarium)
 (synopsis "Seed-derived geocoding: three BIP-39 words address every 3 m square")
 (description
  "A formally verified core, written in F* and extracted to OCaml, mapping every\n\
   ~3 m square on Earth to three BIP-39 words plus a four-digit number under a\n\
   permutation private to the user's seed phrase. The same extraction builds the\n\
   native server and, through js_of_ocaml, the browser client.")
 ; OCaml 5.1+ is a hard floor: zarith_stubs_js, which is what makes the
 ; extracted core's bignum arithmetic work in a browser, requires it. Eio wants
 ; 5.2+. The development switch is 5.3.0, matching the compiler F* itself was
 ; built with, so extraction can link its shipped support objects directly.
 (depends
  (ocaml (>= 5.2.0))
  (dune (>= 3.0))
  zarith
  zarith_stubs_js
  (digestif (>= 1.3.0))
  yojson
  js_of_ocaml
  js_of_ocaml-ppx
  cohttp-eio
  eio_main
  cmdliner
  logs
  fmt
  base64
  decompress))
