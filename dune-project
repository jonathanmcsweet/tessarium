(lang dune 3.17)
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
 ; Everything a `dune` file names in (libraries) or (pps) belongs here, even
 ; when some other package would drag it in anyway. A dependency that is only
 ; ever satisfied transitively is satisfied by accident: it disappears the day
 ; the package that happened to pull it drops it, and until then a fresh
 ; `opam install . --deps-only` produces a switch that cannot build this
 ; project -- which is invisible to CI, whose switch is restored from cache.
 (depends
  (ocaml (>= 5.2.0))
  zarith
  zarith_stubs_js
  (digestif (>= 1.3.0))
  yojson
  js_of_ocaml
  js_of_ocaml-ppx
  ; The word lookup folds and compares Unicode.
  uunf
  ; F*'s support modules, built from source here rather than linked from the
  ; release: they carry ppx_deriving attributes and stdint's fixed widths.
  stdint
  ppx_deriving
  ppx_deriving_yojson
  ; Floored at the release that normalises percent-encoded path separators
  ; before matching (OSEC-2026-16, fixed in 6.3.0). This server never asks
  ; cohttp to resolve a path -- every target goes through Url_path.resolve,
  ; which is extracted F* and decodes before it validates, which is the
  ; ordering that bug got wrong -- so the floor is belt to that braces. It is
  ; here so a fresh solve cannot quietly pick a vulnerable one.
  (cohttp-eio (>= 6.3.0))
  eio_main
  ; Reading a planet build over HTTP range requests: bare eio for the source
  ; itself, and TLS with compiled-in Mozilla trust anchors, because the
  ; desktop build is one binary and cannot assume a system certificate store
  ; exists where it lands.
  eio
  tls-eio
  mirage-crypto-rng
  ca-certs-nss
  domain-name
  uri
  cmdliner
  logs
  fmt
  base64
  decompress
  ; decompress's bigarray buffers, handled directly in ocaml/gzip.
  bigstringaf
  ; The pmtiles suite builds its own responses to drive the range reader.
  (http :with-test)))
