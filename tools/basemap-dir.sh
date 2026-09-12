#!/usr/bin/env bash
# Where downloaded maps live. Prints a path; changes nothing.
#
# Not inside the checkout. Downloaded maps are USER DATA -- hundreds of
# megabytes a person chose to fetch, that nothing regenerates -- and a
# gitignored directory in the working tree is deleted by things whose job is
# to delete build output. A 666 MB region went that way on this project,
# taken by a re-clone, and nothing announced it: `git status` is silent about
# ignored files, so the tree looked identical before and after.
#
# The path is the one the installed launchers already use (see
# packaging/tessarium-launcher, and the flatpak and snap wrappers), so a
# development run and an installed run read one map store instead of two.
#
# TESSARIUM_BASEMAP overrides it, for a second store or a scratch one; `make`
# also takes BASEMAP_DIR=... for a single command.

set -euo pipefail

if [ -n "${TESSARIUM_BASEMAP:-}" ]; then
  printf '%s\n' "$TESSARIUM_BASEMAP"
else
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/tessarium/basemap"
fi
