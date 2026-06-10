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

# Bundle the mingw runtime DLLs crsqlite.dll imports (libgcc/libwinpthread), so
# the artifact loads on a clean Windows machine without a mingw install — and so
# the contract test isn't silently relying on the runner's mingw in PATH.
for dll in $(x86_64-w64-mingw32-objdump -p "${OUT}/crsqlite.dll" 2>/dev/null \
             | awk '/DLL Name:/{print $3}'); do
  case "${dll}" in
    libgcc*|libwinpthread*|libstdc*)
      src="$(find /usr/lib/gcc/x86_64-w64-mingw32 /usr/x86_64-w64-mingw32 \
               -name "${dll}" 2>/dev/null | head -1)"
      [ -n "${src}" ] && cp "${src}" "${OUT}/" && echo "  bundled ${dll}" ;;
  esac
done

echo "✅ crsqlite.dll → ${OUT}"
ls -la "${OUT}"
