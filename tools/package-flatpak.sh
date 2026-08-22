#!/usr/bin/env bash
# Build the Flatpak, from the release tarball `make package` produces.
#
# Two steps rather than one because they fail for different reasons and the
# distinction matters: the tarball is this repository's own build and must
# work anywhere, while flatpak-builder needs a runtime downloaded from
# Flathub and a host that has Flatpak at all. When the second is missing the
# tarball is still built and this says what to install, rather than failing
# a release for a tool a build machine may not carry -- the same choice
# package-appimage.sh makes about appimagetool.
#
# This script has never been run to completion: nothing here has
# flatpak-builder, so only the tarball half of it is exercised.

set -euo pipefail
umask 022

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

app_id="io.github.tessarium.Tessarium"
manifest="packaging/flatpak/${app_id}.yml"
version="$(sed -n 's/.*~version:"\([^"]*\)".*/\1/p' ocaml/server/bin/main.ml | head -1)"
version="${version:-0.0.0}"
tarball="dist/tessarium-${version}-linux-x86_64.tar.gz"

if [ ! -f "$tarball" ]; then
  echo "==> $tarball is missing; building it"
  tools/package.sh
fi

# The manifest names the tarball by version. A mismatch here is a stale
# manifest, and it would otherwise surface as a confusing "source not found"
# from inside flatpak-builder.
if ! grep -q "tessarium-${version}-linux-x86_64.tar.gz" "$manifest"; then
  echo "error: $manifest does not reference tessarium-${version}-..." >&2
  echo "       the version in ocaml/server/bin/main.ml moved; update the" >&2
  echo "       manifest's archive source to match." >&2
  exit 1
fi

if ! command -v flatpak-builder > /dev/null 2>&1; then
  echo "flatpak-builder not found."
  echo "  Fedora/Silverblue:  flatpak install -y flathub org.flatpak.Builder"
  echo "  Debian/Ubuntu:      apt install flatpak-builder"
  echo "then: tools/package-flatpak.sh"
  exit 0
fi

echo "==> runtime"
flatpak install -y --noninteractive --user flathub \
  org.freedesktop.Platform//24.08 org.freedesktop.Sdk//24.08 2>/dev/null \
  || echo "    (assuming the runtime is already present)"

echo "==> building"
rm -rf dist/flatpak-build dist/flatpak-repo
flatpak-builder --force-clean --repo=dist/flatpak-repo \
  dist/flatpak-build "$manifest"

bundle="dist/Tessarium-${version}-x86_64.flatpak"
flatpak build-bundle dist/flatpak-repo "$bundle" "$app_id"

echo
echo "$bundle"
echo "  install:  flatpak install --user $bundle"
echo "  run:      flatpak run $app_id"
