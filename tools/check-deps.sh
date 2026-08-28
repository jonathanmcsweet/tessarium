#!/usr/bin/env bash
# Every library a dune file names must be declared in dune-project.
#
# A dependency satisfied only transitively is satisfied by accident. It works
# until the package that happened to pull it drops it, and in the meantime a
# fresh `opam install . --deps-only` builds a switch this project cannot
# compile in. That is invisible to CI, whose switch is restored from cache and
# therefore still holds whatever an earlier solve happened to install -- so
# the person who finds it is someone setting up from nothing, which is the
# worst audience for it.
#
# Comparing the two lists is enough to catch the whole class, and costs no
# network and no switch.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

python3 - "$@" <<'PY'
import pathlib, re, sys

def forms(text, head):
    """Bodies of every (head ...) form, comments and nested forms removed."""
    out = []
    for m in re.finditer(r"\(%s\b" % head, text):
        i, depth, buf = m.end(), 1, []
        while i < len(text) and depth:
            c = text[i]
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if not depth:
                    break
            buf.append(c)
            i += 1
        out.append("".join(buf))
    return out

def tokens(body):
    body = re.sub(r";[^\n]*", " ", body)       # dune comments
    body = re.sub(r"\([^()]*\)", " ", body)    # (>= 1.2), :with-test and friends
    return body.split()

dune_files = sorted(pathlib.Path("ocaml").rglob("dune"))

# What this project builds itself. Discovered rather than listed, so a new
# library cannot be mistaken for a missing dependency.
internal = set()
for d in dune_files:
    text = d.read_text()
    for head in ("name", "public_name"):
        for body in forms(text, head):
            internal.update(tokens(body))

# Shipped with the compiler, so never an opam dependency.
stdlib = {"str", "unix", "threads", "bytes", "dynlink", "compiler-libs"}

referenced = {}
for d in dune_files:
    text = d.read_text()
    for head in ("libraries", "pps"):
        for body in forms(text, head):
            for tok in tokens(body):
                # decompress.de and digestif.ocaml are sub-libraries of one
                # opam package; it is the package that gets depended on.
                pkg = tok.split(".")[0]
                if pkg in internal or pkg in stdlib:
                    continue
                referenced.setdefault(pkg, set()).add(str(d))

project = pathlib.Path("dune-project").read_text()
declared = set()
for body in forms(project, "depends"):
    for tok in tokens(body):
        declared.add(tok.split(".")[0])
# (digestif (>= 1.3.0)) loses its name to the nested-form strip above, so the
# package names wrapped in a constraint are recovered here.
for name in re.findall(r"\(([a-z0-9_-]+)\s+\(?[:>=<]", project):
    declared.add(name)

missing = {p: v for p, v in referenced.items() if p not in declared}
print(f"    {len(referenced)} libraries referenced, {len(declared)} declared")
if missing:
    print()
    print("error: used by a dune file, absent from dune-project:", file=sys.stderr)
    for pkg in sorted(missing):
        where = ", ".join(sorted(f.replace("ocaml/", "") for f in missing[pkg]))
        print(f"       {pkg:24} {where}", file=sys.stderr)
    print(file=sys.stderr)
    print("       Add them to (depends) in dune-project; dune regenerates", file=sys.stderr)
    print("       tessarium.opam from it on the next build.", file=sys.stderr)
    sys.exit(1)
print("    every dune library is declared")
PY
