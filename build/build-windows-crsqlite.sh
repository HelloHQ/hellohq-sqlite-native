#!/usr/bin/env bash
# build-windows-crsqlite.sh — cross-build cr-sqlite's loadable crsqlite.dll for
# Windows x64 from **Linux** with mingw-w64.
#
# This is cr-sqlite's own recipe (publish.yaml): native Windows cr-sqlite is
# unsupported upstream ("complete nonsense" — their words), so the loadable DLL
# is produced by cross-compiling from Linux. SQLCipher's DLL is built separately
# on a Windows runner (MSVC); the two are combined in the `windows` job.
#
# Deps (CI installs): mingw-w64 (x86_64-w64-mingw32-gcc), and the
# x86_64-pc-windows-gnu Rust target (added by build/setup-rust.sh).
#
#   Usage:  bash build/fetch.sh && bash build/build-windows-crsqlite.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/.src"
OUT="${ROOT}/dist/windows-x64"
mkdir -p "${OUT}"

echo "▸ cr-sqlite → crsqlite.dll (mingw cross from Linux; x86_64-pc-windows-gnu)"
( cd "${SRC}/cr-sqlite/core"
  make clean >/dev/null 2>&1 || true
  # Exactly cr-sqlite's prebuild-windows-x86_64 recipe.
  export CI_MAYBE_TARGET="x86_64-pc-windows-gnu"
  export CI_GCC="x86_64-w64-mingw32-gcc"
  make loadable >/dev/null )

cp "${SRC}/cr-sqlite/core/dist/crsqlite.dll" "${OUT}/crsqlite.dll"
echo "✅ crsqlite.dll → ${OUT}"
file "${OUT}/crsqlite.dll" 2>/dev/null || true
