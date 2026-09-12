#!/usr/bin/env bash
# The half of "zero admits" that F* does not enforce.
#
# `--report_assumes error` catches every escape hatch reached through a TERM:
# `admit()`, `assume (p)`, `magic ()`, `admitP`. Measured against F* 2026.08.09,
# it says nothing at all about an escape hatch reached through a DECLARATION:
#
#   assume val ax : squash (1 == 2)
#
# verifies clean, exit 0, "All verification conditions discharged
# successfully" -- and everything downstream of it is then proved from an
# axiom nobody wrote a proof for. The same is true of `assume type`, and of a
# `.fsti` whose `.fst` is missing: F* checks the interface alone and every
# `val` in it becomes an assumption. Deleting Tessarium.Table.Data.fst leaves
# `make verify` green with the band table's three lemmas unproven.
#
# So this runs beside the flag rather than instead of it, and only over what
# the flag misses. The grep this project rejected once fired on the word
# "assume" in prose; comments are stripped here before anything is matched,
# which is the difference.

set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# Comments out, then declaration-position `assume` in what is left. Nested
# `(* *)`, `//` to end of line, and string literals, because `"(*"` is text
# and `(* "assume val" *)` is not a declaration.
strip_comments() {
  awk '
    BEGIN { depth = 0; instr = 0 }
    {
      line = $0; out = ""; i = 1; n = length(line)
      while (i <= n) {
        c = substr(line, i, 1); d = substr(line, i, 2)
        if (instr) {
          if (c == "\\") { i += 2; continue }
          if (c == "\"") instr = 0
          i += 1; continue
        }
        if (depth > 0) {
          if (d == "(*") { depth += 1; i += 2; continue }
          if (d == "*)") { depth -= 1; i += 2; continue }
          i += 1; continue
        }
        if (d == "(*") { depth += 1; i += 2; continue }
        if (d == "//") break
        if (c == "\"") { instr = 1; i += 1; continue }
        out = out c; i += 1
      }
      print out
    }
  ' "$1"
}

bad=0

for f in $(find fstar -name '*.fst' -o -name '*.fsti' | sort); do
  hits="$(strip_comments "$f" \
    | grep -nE '(^|[^[:alnum:]_.])assume([[:space:]]+(val|type|new)\b|[[:space:]]*$)' \
    || true)"
  if [ -n "$hits" ]; then
    while IFS= read -r h; do
      echo "$f:${h%%:*}: assumed declaration -- ${h#*:}" >&2
      bad=$((bad + 1))
    done <<< "$hits"
  fi
done

# An interface with no implementation is the same hole spelled differently:
# every `val` in it is assumed, and F* reports nothing.
for f in $(find fstar -name '*.fsti' | sort); do
  if [ ! -f "${f%i}" ]; then
    echo "$f: interface with no implementation -- every val in it is assumed" >&2
    bad=$((bad + 1))
  fi
done

if [ "$bad" -gt 0 ]; then
  echo >&2
  echo "error: $bad assumed declaration(s) in fstar/." >&2
  echo "       An assumed val, type or interface is a theorem nobody proved," >&2
  echo "       and --report_assumes error does not see it. Prove it or delete it." >&2
  exit 1
fi

echo "    ok   no assumed declarations in fstar/"
