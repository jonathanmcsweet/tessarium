#!/usr/bin/env bash
# What the built binaries demand of the system they will run on.
#
#   tools/check-glibc-floor.sh path/to/binary [more...]
#
# A binary asks for the newest symbol version its build host happens to offer,
# and that version becomes the floor for every machine that then runs it.
# Nothing in this repository chooses it. It is a property of the machine the
# release was built on, which is why it can move without a single line
# changing.
#
# Which packages that decides, and which it does not:
#
#   Flatpak, Snap    run against the runtime's glibc     unaffected
#   .deb, .rpm       run against the host's              refuse to install
#   AppImage, tar    run against the host's              CRASH on launch
#
# The last row is why this check exists. AppImage carries no dependency
# metadata to catch the mistake, and "runs anywhere" is the whole of what that
# format is for -- so the one package that cannot warn the user is the one
# whose floor nobody would notice moving.
#
# What this can and cannot do. It cannot LOWER the floor: the only way to do
# that is to build on an older base and let the result run forward. What it
# does is stop the floor drifting up unnoticed when a build image is updated,
# and put the number in front of whoever is cutting a release rather than
# leaving it in a roadmap entry nobody reads at that moment.

set -euo pipefail

# What we currently ship, not what we would like to ship. Lowering this is a
# change of build host, and the entry in roadmap.md says which one.
DECLARED=2.35

# Named so the cost of the declared floor is stated every time a package is
# built, rather than discovered by somebody whose app will not start.
EXCLUDES="RHEL 9 and its rebuilds (2.34), Debian 11 and Ubuntu 20.04 (2.31)"

if [ "$#" -eq 0 ]; then
  echo "usage: tools/check-glibc-floor.sh <binary>..." >&2
  exit 2
fi

if ! command -v objdump > /dev/null 2>&1; then
  echo "error: objdump is missing, so the glibc floor cannot be read back" >&2
  echo "       out of the binaries. Install binutils." >&2
  exit 1
fi

# `|| true` so that objdump failing -- an unreadable path, a file that is not
# an ELF binary -- reaches the empty-result branch below with an explanation,
# instead of dying at this assignment under `set -e` with only objdump's own
# one-line complaint to go on.
found="$(objdump -T "$@" 2> /dev/null \
  | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1 || true)"

if [ -z "$found" ]; then
  echo "error: no GLIBC_ symbol versions in $* -- objdump found nothing to" >&2
  echo "       read, so this check would pass for the wrong reason." >&2
  exit 1
fi

# The highest version wins, so "found is newer than declared" is the failure.
newest="$(printf '%s\n%s\n' "$found" "$DECLARED" | sort -V | tail -1)"
if [ "$newest" != "$DECLARED" ]; then
  echo "error: these binaries need glibc $found; this project declares" >&2
  echo "       $DECLARED. The build host got newer, and every machine below" >&2
  echo "       $found now fails to start rather than failing to install." >&2
  echo "       Build on an older base, or change DECLARED here and say so." >&2
  exit 1
fi

printf '    glibc floor %s (declared %s)\n' "$found" "$DECLARED"
printf '    excludes %s\n' "$EXCLUDES"
