#!/bin/sh
# $SNAP_USER_DATA is this revision's own directory under ~/snap/tessarium/,
# which strict confinement grants without any interface. A multi-gigabyte
# basemap under a revisioned directory would be copied on every refresh, so
# $SNAP_USER_COMMON -- which is shared across revisions and never copied -- is
# the right home for it.
#
# --basemap is not repeatable, so a user naming their own directory has to win
# over this default. That needs the `home` plug connected.
set -eu
case " $* " in
  *" --basemap "* | *" --basemap="*)
    exec "$SNAP/bin/tessarium-server" "$@" ;;
  *)
    dir="${SNAP_USER_COMMON:-$HOME}/basemap"
    mkdir -p "$dir"
    exec "$SNAP/bin/tessarium-server" --basemap "$dir" "$@" ;;
esac
