#!/usr/bin/env bash
# lipo-macos.sh — fuse the per-arch macOS builds into universal binaries.
#
#   in:   dist/macos-arm64/{libsqlcipher,crsqlite}.dylib
#         dist/macos-x86_64/{libsqlcipher,crsqlite}.dylib
#   out:  dist/macos/{libsqlcipher,crsqlite}.dylib   (arm64 + x86_64)
#
# Each slice is produced natively by build/build-macos.sh on its own runner
# (arm64 on macos-14, x86_64 on macos-13). This step combines them. If a slice
# is missing it does NOT silently ship a thin binary — it fails, unless
# ALLOW_THIN=1 (used for local single-arch verification, with a loud warning).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARM="${ROOT}/dist/macos-arm64"
X64="${ROOT}/dist/macos-x86_64"
OUT="${ROOT}/dist/macos"
mkdir -p "${OUT}"

for lib in libsqlcipher.dylib crsqlite.dylib; do
  slices=()
  [ -f "${ARM}/${lib}" ] && slices+=("${ARM}/${lib}")
  [ -f "${X64}/${lib}" ] && slices+=("${X64}/${lib}")

  if [ "${#slices[@]}" -eq 0 ]; then
    echo "❌ ${lib}: no per-arch slice found (run build/build-macos.sh first)" >&2
    exit 1
  fi

  if [ "${#slices[@]}" -lt 2 ]; then
    if [ "${ALLOW_THIN:-0}" != "1" ]; then
      echo "❌ ${lib}: only ${#slices[@]} arch present — refusing to ship a thin" \
           "universal binary. Build the missing arch, or set ALLOW_THIN=1." >&2
      exit 1
    fi
    echo "⚠️  ${lib}: THIN — only $(basename "$(dirname "${slices[0]}")") present" \
         "(ALLOW_THIN=1). NOT a release artifact." >&2
    cp "${slices[0]}" "${OUT}/${lib}"
  else
    lipo -create "${slices[@]}" -output "${OUT}/${lib}"
  fi

  install_name_tool -id "@rpath/${lib}" "${OUT}/${lib}" 2>/dev/null || true
  printf '   %s → ' "${lib}"; lipo -info "${OUT}/${lib}"
done

echo "✅ universal artifacts in ${OUT}"
