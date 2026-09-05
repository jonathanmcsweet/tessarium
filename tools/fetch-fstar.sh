#!/usr/bin/env bash
# Install the pinned F* release (Z3 ships inside it) into a toolchain directory.
#
#   tools/fetch-fstar.sh 2026.08.09              # into $HOME/toolchain
#   tools/fetch-fstar.sh 2026.08.09 /opt/tc      # or wherever
#
# One rule, in one place. It used to be four: three byte-identical blocks in
# .github/workflows/ci.yml and a fourth in tools/setup.sh, each spelling out
# the same download, the same unpack and the same normalisation with slightly
# different paths. The cost is not hypothetical -- the `mv fstar*` glob below
# had to be fixed in three of them in lockstep, and the copy that missed a fix
# would install a broken toolchain, or silently re-cache a quarter of a
# gigabyte, without anything saying so.
#
# The caller decides WHEN to run this: CI on a cache miss, tools/setup.sh when
# fstar.exe is not already on PATH. This one only knows how.

set -euo pipefail

version="${1:-}"
toolchain="${2:-$HOME/toolchain}"

if [ -z "$version" ]; then
  echo "usage: tools/fetch-fstar.sh VERSION [TOOLCHAIN_DIR]" >&2
  exit 2
fi

url="https://github.com/FStarLang/FStar/releases/download/v${version}/fstar-v${version}-Linux-x86_64.tar.gz"

mkdir -p "$toolchain"
echo "downloading $url"
curl -fsSL -o "$toolchain/fstar.tar.gz" "$url"
tar -xzf "$toolchain/fstar.tar.gz" -C "$toolchain"

# The toolchain directory is what CI caches, and the tarball is 230 MB of it
# that nothing reads again.
rm -f "$toolchain/fstar.tar.gz"

# The tarball's top directory has been both a versioned name and a bare
# `fstar`, and `mv fstar* fstar` only survives the first: once the archive
# unpacks to `fstar` the glob also catches the tarball and mv is asked to move
# a directory into itself. Normalise whichever arrived instead, which is a
# no-op for the bare one -- so PATH is $toolchain/fstar/bin either way.
find "$toolchain" -maxdepth 1 -type d -name 'fstar*' ! -name fstar \
  -exec mv {} "$toolchain/fstar" \;

echo "F* $version installed to $toolchain/fstar (Z3 ships with it)"
