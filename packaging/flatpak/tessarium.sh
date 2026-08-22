#!/bin/sh
# Inside the sandbox XDG_DATA_HOME is already the app's own private directory
# -- ~/.var/app/io.github.tessarium.Tessarium/data -- so this needs no
# permission and cannot see anything else the user owns.
#
# --basemap is not repeatable, so a user who names their own directory must
# win over the default. Detecting it here rather than teaching the server a
# second default keeps one answer to "where are the maps" in the binary.
set -eu
case " $* " in
  *" --basemap "* | *" --basemap="*)
    exec tessarium-server "$@" ;;
  *)
    dir="${XDG_DATA_HOME:-$HOME/.local/share}/tessarium/basemap"
    mkdir -p "$dir"
    exec tessarium-server --basemap "$dir" "$@" ;;
esac
