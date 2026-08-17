# BIP-39 English wordlist

`english.txt`, verbatim and canonical.

```
sha256  2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda
```

That checksum is the one to verify against
[bitcoin/bips](https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt).
A single altered word changes which addresses a phrase produces, silently.

It lives here rather than beside any one implementation because it is shared
input, not part of any of them. `ocaml/lib/wordlist.ml` is generated from this
file at build time and is not committed.

## Why this list

Prefix-unique in the first four letters, curated against confusable pairs, and
already supported by tooling in most languages. The four-letter property is
what lets `slic.salm.swam.4866` resolve — see `resolve_word` in
`ocaml/lib/tessarium.ml`.

The list is a fixed part of the address format. Changing it would invalidate
every address anyone has written down.
