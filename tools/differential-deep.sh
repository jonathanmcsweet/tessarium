#!/usr/bin/env bash
# The deep differential sweep: ten million points across five keys.
#
# This is the recorded evidence behind the extraction-trust roadmap item,
# committed so the claim is re-runnable rather than an anecdote. About 50
# minutes of CPU. Any disagreement fails the run loudly -- as does a
# configuration that checks nothing, which a dead generator once made look
# like four passes.

set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

dune build ocaml/tools/differential.exe

run() { # seed mnemonic [passphrase]
  echo "== seed $1 ${3:+(passphrase set) }-- ${2:0:30}..."
  ./_build/default/ocaml/tools/differential.exe --count 2000000 --seed "$1" \
    --mnemonic "$2" ${3:+--passphrase "$3"} 2> /dev/null \
    | node js/differential.mjs -
}

A="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"
B="legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title"
C="letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic bless"
D="zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote"

run 1001 "$A"
run 1002 "$B"
run 1003 "$C"
run 1004 "$D"
run 1005 "$A" "TREZOR"
echo "deep sweep complete: 5 x 2,012,298 points, all agreeing"
