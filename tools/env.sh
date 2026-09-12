# The pinned toolchain, on PATH for the current shell. Source this, do not run
# it: it changes the shell rather than doing anything.
#
#   . tools/env.sh        from a script
#   eval "$(make env)"    from a terminal -- which prints the line above
#
# One copy of "where the toolchain is". tools/dev.sh carried a second, and
# `make env` a third, so a shell that had sourced one still lacked what the
# other knew about.
#
# No `set -e` and no `exit` anywhere below: a sourced script's failure is the
# calling shell's failure, and this one runs in interactive shells.

_tsr_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

# F* and Z3 live in $HOME, installed by tools/setup.sh, never system-wide.
_tsr_fstar_bin="$HOME/toolchain/fstar/bin"
if [ -d "$_tsr_fstar_bin" ]; then
  case ":$PATH:" in
    *":$_tsr_fstar_bin:"*) ;;
    *) PATH="$_tsr_fstar_bin:$PATH"; export PATH ;;
  esac
fi

# The switch, not the default one: this project pins OCaml 5.3.0, and a
# machine can carry several checkouts on different versions.
if command -v opam >/dev/null 2>&1; then
  eval "$(opam env --switch=tessarium 2>/dev/null)" || true
fi

if [ -s "$HOME/.nvm/nvm.sh" ]; then
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
  # .nvmrc is the pin; nvm's default alias is whatever that machine last set.
  if command -v nvm >/dev/null 2>&1 && [ -f "$_tsr_root/.nvmrc" ]; then
    nvm use --silent "$(cat "$_tsr_root/.nvmrc")" >/dev/null 2>&1 || true
  fi
fi

unset _tsr_root _tsr_fstar_bin
