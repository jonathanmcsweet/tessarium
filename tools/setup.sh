#!/usr/bin/env bash
# Install the toolchain this project pins, from nothing.
#
#   tools/setup.sh          install what is missing
#   tools/setup.sh --check  report what is missing, change nothing
#
# Everything lands in $HOME. Nothing here needs root, and nothing is installed
# system-wide, so a machine can carry several checkouts on different versions.
#
# The versions are the ones CI uses. They are duplicated in
# .github/workflows/ci.yml, and --check compares against that file so the two
# cannot drift silently.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

FSTAR_VERSION="2026.08.09"
OCAML_VERSION="5.3.0"
# Matches (lang dune 3.17) in dune-project; ocaml/js/dune needs its fields.
DUNE_MIN="3.17"
SWITCH="tessarium"
NVM_VERSION="v0.40.6"
TOOLCHAIN="$HOME/toolchain"

check_only=false
[ "${1:-}" = "--check" ] && check_only=true

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()  { printf '    \033[32mok\033[0m   %s\n' "$1"; }
no()  { printf '    \033[31mmiss\033[0m %s\n' "$1"; }

missing=0
need() {
  if eval "$2" >/dev/null 2>&1; then ok "$1"; return 1; else no "$1"; missing=$((missing+1)); return 0; fi
}

# The workflow is the reference for these versions; disagreeing with it means
# a contributor proves something CI does not.
say "versions"
for pair in "FSTAR_VERSION:$FSTAR_VERSION" "OCAML_VERSION:$OCAML_VERSION"; do
  key="${pair%%:*}"; want="${pair#*:}"
  ci="$(sed -n "s/^  ${key}: \"\(.*\)\"$/\1/p" .github/workflows/ci.yml)"
  if [ "$ci" != "$want" ]; then
    echo "    error: $key is $want here and $ci in ci.yml" >&2
    exit 1
  fi
  ok "$key $want (matches ci.yml)"
done

say "F* $FSTAR_VERSION and Z3"
if need "fstar.exe" "PATH=$TOOLCHAIN/fstar/bin:\$PATH command -v fstar.exe"; then
  if ! $check_only; then
    mkdir -p "$TOOLCHAIN"
    url="https://github.com/FStarLang/FStar/releases/download/v${FSTAR_VERSION}/fstar-v${FSTAR_VERSION}-Linux-x86_64.tar.gz"
    echo "    downloading $url"
    curl -fsSL -o "$TOOLCHAIN/fstar.tar.gz" "$url"
    tar -xzf "$TOOLCHAIN/fstar.tar.gz" -C "$TOOLCHAIN"
    rm -f "$TOOLCHAIN/fstar.tar.gz"
    # The tarball's top directory is versioned; normalise it so PATH is stable.
    find "$TOOLCHAIN" -maxdepth 1 -type d -name 'fstar*' ! -name fstar \
      -exec mv {} "$TOOLCHAIN/fstar" \;
    ok "installed to $TOOLCHAIN/fstar (Z3 ships with it)"
  fi
fi

say "opam switch '$SWITCH' on OCaml $OCAML_VERSION"
if ! command -v opam >/dev/null 2>&1; then
  no "opam is not installed"
  echo "    opam itself is the one thing this script will not install for you:"
  echo "    it is the package manager, and how you get it is a decision about"
  echo "    your machine. See https://opam.ocaml.org/doc/Install.html"
  missing=$((missing+1))
elif need "switch $SWITCH" "opam switch list --short | grep -qx $SWITCH"; then
  if ! $check_only; then
    opam switch create "$SWITCH" "ocaml-base-compiler.$OCAML_VERSION"
    ok "created"
  fi
fi

if command -v opam >/dev/null 2>&1 && opam switch list --short 2>/dev/null | grep -qx "$SWITCH"; then
  if $check_only; then
    # dune's version, not merely its presence: ocaml/js/dune uses the
    # `sourcemap` and `compilation_mode` fields, which do not exist before
    # 3.17. A switch created against the older constraint reports a healthy
    # dune here and then fails the build, which is the wrong place to find out.
    dune_have="$(opam exec --switch="$SWITCH" -- dune --version 2>/dev/null || true)"
    if [ -z "$dune_have" ]; then
      no "project dependencies"; missing=$((missing+1))
    elif [ "$(printf '%s\n%s\n' "$DUNE_MIN" "$dune_have" \
             | sort -V | head -1)" != "$DUNE_MIN" ]; then
      no "dune $dune_have is older than $DUNE_MIN"
      echo "    opam upgrade --switch=$SWITCH dune"
      missing=$((missing+1))
    else
      ok "project dependencies (dune $dune_have)"
    fi
  else
    echo "    installing dependencies from tessarium.opam"
    opam install --switch="$SWITCH" . --deps-only --with-test -y
    ok "dependencies"
  fi

  # Not a build dependency: the tool `make test-core` audits the build's
  # dependency declarations with. It cannot come from tessarium.opam,
  # because it exists to check that file.
  say "opam-dune-lint (checks dune against dune-project)"
  if need "opam-dune-lint" "opam exec --switch=$SWITCH -- sh -c 'command -v opam-dune-lint'"; then
    if ! $check_only; then
      opam install --switch="$SWITCH" opam-dune-lint -y
      ok "opam-dune-lint"
    fi
  fi
fi

say "node (from .nvmrc)"
node_want="$(cat .nvmrc)"
if need "node $node_want" "[ \"\$(. \$HOME/.nvm/nvm.sh >/dev/null 2>&1; nvm version $node_want)\" != N/A ]"; then
  if ! $check_only; then
    if [ ! -s "$HOME/.nvm/nvm.sh" ]; then
      echo "    installing nvm $NVM_VERSION"
      curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" | bash
    fi
    # shellcheck disable=SC1091
    . "$HOME/.nvm/nvm.sh"
    nvm install "$node_want"
    ok "node $node_want"
  fi
fi

# F* ships its OCaml support library as precompiled objects. OCaml 5.3
# compresses .cmi with zstd when the compiler has it, and F*'s build did, so
# those objects are unreadable to a compiler without it. Building them from the
# shipped sources sidesteps the question entirely -- but it has to happen
# before anything links against them.
say "F* support library"
if $check_only; then
  if [ -f ocaml/fstarlib/prims.ml ] || [ -f ocaml/fstarlib/Prims.ml ]; then
    ok "vendored"
  else
    no "vendored (run: make -C fstar fstarlib)"; missing=$((missing+1))
  fi
elif [ -d "$TOOLCHAIN/fstar" ]; then
  PATH="$TOOLCHAIN/fstar/bin:$PATH" make -C fstar fstarlib
fi

if $check_only; then
  say "result"
  if [ "$missing" -eq 0 ]; then
    echo "    everything present. eval \"\$(make env)\" to put it on PATH."
  else
    echo "    $missing missing. run tools/setup.sh to install."
    exit 1
  fi
else
  say "done"
  cat <<'TXT'
    Put the toolchain on PATH for this shell:

      eval "$(make env)"

    Then:

      make verify     prove the core
      make ui         build the web UI
      make build      compile, embedding the UI in the binary
      make test       all six suites
TXT
fi
