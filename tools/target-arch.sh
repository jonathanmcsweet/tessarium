#!/usr/bin/env bash
# Print the architecture a built binary is FOR, in the naming a packager
# wants.
#
#   tools/target-arch.sh --gnu    BIN   # x86_64  aarch64   (rpm, AppImage, uname)
#   tools/target-arch.sh --debian BIN   # amd64   arm64     (.deb)
#
# Read out of the binary rather than taken from `uname -m`, which answers for
# the machine doing the building. Those are the same thing until the day
# someone cross-compiles, and on that day `uname` would label an ARM package
# amd64 -- a package that installs cleanly and then cannot run a single
# byte of what is inside it.
#
# An architecture this does not know is an error. Guessing produces exactly
# the mislabelled package this exists to prevent.

set -euo pipefail

naming="--gnu"
case "${1:-}" in
  --gnu | --debian) naming="$1"; shift ;;
esac

bin="${1:-}"
if [ -z "$bin" ] || [ ! -f "$bin" ]; then
  echo "usage: $0 [--gnu|--debian] BINARY" >&2
  exit 1
fi

# `|| true`: without it pipefail kills the script at this assignment when
# readelf rejects the file, and the explanation below is never reached --
# the caller gets exit 1 and no reason.
machine="$(readelf -h "$bin" 2> /dev/null \
  | sed -n 's/^ *Machine: *//p' | head -1 || true)"
if [ -z "$machine" ]; then
  echo "error: $bin is not an ELF binary, so there is no architecture to" \
    "read from it." >&2
  exit 1
fi

case "$machine" in
  "Advanced Micro Devices X86-64") gnu=x86_64  debian=amd64 ;;
  "AArch64")                       gnu=aarch64 debian=arm64 ;;
  *)
    echo "error: $bin is built for '$machine', which no packager here knows" \
      "how to name. Add it rather than letting a package be mislabelled." >&2
    exit 1
    ;;
esac

case "$naming" in
  --gnu) echo "$gnu" ;;
  --debian) echo "$debian" ;;
esac
