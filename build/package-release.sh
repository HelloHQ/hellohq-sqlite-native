#!/usr/bin/env bash
# package-release.sh <version> — assemble per-platform release archives from the
# downloaded CI build artifacts (artifacts/) plus THIRD_PARTY_LICENSES, and write
# SHA256SUMS over them. Each archive bundles the libraries + the license file so
# a consumer gets everything in one download.
#
#   in:   artifacts/{macos-universal,linux-x64,linux-sqlite3mc,windows-x64,ios,android}/...
#         THIRD_PARTY_LICENSES/THIRD_PARTY_LICENSES.txt
#   out:  release/hellohq-sqlite-native-<version>-<platform>.{tar.gz,zip} + SHA256SUMS
set -euo pipefail

VER="${1:?usage: package-release.sh <version>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ART="${ROOT}/artifacts"
LIC="${ROOT}/THIRD_PARTY_LICENSES/THIRD_PARTY_LICENSES.txt"
OUT="${ROOT}/release"
mkdir -p "${OUT}"
NAME="hellohq-sqlite-native-${VER}"

# Copy a platform's artifacts + the license into a clean staging dir.
# Extra subdirs are merged in, so a platform whose libraries are produced by
# more than one CI job still ships as ONE archive.
stage() { # <artifact-subdir> [extra-subdir...]  -> echoes the staging dir
  local sub="$1" d extra
  shift
  d="$(mktemp -d)"
  cp -R "${ART}/${sub}/." "${d}/"
  for extra in "$@"; do
    [ -d "${ART}/${extra}" ] && cp -R "${ART}/${extra}/." "${d}/"
  done
  [ -f "${LIC}" ] && cp "${LIC}" "${d}/"
  echo "${d}"
}

if [ -d "${ART}/macos-arm64" ]; then
  tar -czf "${OUT}/${NAME}-macos-arm64.tar.gz" -C "$(stage macos-arm64)" .
fi
if [ -d "${ART}/linux-x64" ]; then
  # linux-sqlite3mc is built by its own job (no Rust/OpenSSL/tcl needed), but it
  # ships in the SAME archive — a consumer asking for "linux-x64" must get every
  # library that platform provides, not two downloads with a naming trap.
  tar -czf "${OUT}/${NAME}-linux-x64.tar.gz" -C "$(stage linux-x64 linux-sqlite3mc)" .
fi
if [ -d "${ART}/windows-x64" ]; then
  ( cd "$(stage windows-x64)" && zip -qr "${OUT}/${NAME}-windows-x64.zip" . )
fi
if [ -d "${ART}/ios" ]; then
  ( cd "$(stage ios)" && zip -qr "${OUT}/${NAME}-ios-xcframework.zip" . )
fi
if [ -d "${ART}/android" ]; then
  tar -czf "${OUT}/${NAME}-android.tar.gz" -C "$(stage android)" .
fi

[ -f "${LIC}" ] && cp "${LIC}" "${OUT}/"
# Checksum every release file except the checksum manifest itself.
( cd "${OUT}" && ls | grep -v '^SHA256SUMS$' | xargs shasum -a 256 > SHA256SUMS )

echo "✅ release artifacts in ${OUT}:"
ls -la "${OUT}"
