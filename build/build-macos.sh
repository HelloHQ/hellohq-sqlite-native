#!/usr/bin/env bash
# build-macos.sh — build the HelloHQ native DB layer for ONE macOS arch:
#   dist/macos-<arch>/libsqlcipher.dylib   (SQLCipher = the sqlite3 library)
#   dist/macos-<arch>/crsqlite.dylib       (cr-sqlite loadable extension)
#
# Fuse the two arch outputs into a universal binary with build/lipo-macos.sh.
# CI builds each arch natively (arm64 on macos-14, x86_64 on macos-13) and lipos
# them; this script is that per-arch leg, and also cross-builds locally when
# ARCH != host so one machine can produce both slices.
#
# Crypto provider: **CommonCrypto** (Apple system framework; -DSQLCIPHER_CRYPTO_CC
# + -framework Security). No OpenSSL → the artifact has NO third-party dynamic
# dependency and loads on any mac without Homebrew. (OpenSSL was the bring-up
# path; CommonCrypto is the shippable one — ROADMAP Milestone 1.)
#
# Toolchain: Apple clang via `xcrun` (the PATH `clang` may be Homebrew LLVM, which
# cannot link the macOS SDK for a non-host arch), tclsh (SQLCipher autosetup),
# Rust **nightly** (cr-sqlite uses unstable features).
#
# Usage:  bash build/fetch.sh               # materialize .src/ first
#         bash build/build-macos.sh         # host arch
#         ARCH=x86_64 bash build/build-macos.sh
set -euo pipefail

ARCH="${ARCH:-$(uname -m)}"            # arm64 | x86_64
HOST_ARCH="$(uname -m)"
case "${ARCH}" in
  arm64)  TRIPLE=aarch64-apple-darwin ;;
  x86_64) TRIPLE=x86_64-apple-darwin ;;
  *) echo "❌ unsupported ARCH=${ARCH} (expected arm64 or x86_64)" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC="${ROOT}/.src"
OUT="${ROOT}/dist/macos-${ARCH}"
mkdir -p "${OUT}"

# Apple toolchain + SDK (NOT the PATH clang, which may be Homebrew LLVM).
CC="$(xcrun -f clang)"
SDK="$(xcrun --show-sdk-path)"
ARCHFLAGS="-arch ${ARCH} -isysroot ${SDK}"
echo "▸ macOS/${ARCH} build · CC=${CC}"

# ── 1. SQLCipher → libsqlcipher.dylib (CommonCrypto codec) ───────────────────
echo "▸ building SQLCipher (CommonCrypto codec)"
( cd "${SRC}/sqlcipher"
  make clean >/dev/null 2>&1 || true
  ./configure --with-tempstore=yes \
    CC="${CC}" \
    CFLAGS="${ARCHFLAGS} -O2 -DSQLITE_HAS_CODEC -DSQLCIPHER_CRYPTO_CC \
            -DSQLITE_TEMP_STORE=2 \
            -DSQLITE_EXTRA_INIT=sqlcipher_extra_init \
            -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown" \
    LDFLAGS="${ARCHFLAGS} -framework Security -framework CoreFoundation" >/dev/null
  make -j"$(sysctl -n hw.ncpu)" libsqlite3.dylib >/dev/null
)
cp "${SRC}/sqlcipher/libsqlite3.dylib" "${OUT}/libsqlcipher.dylib"
install_name_tool -id "@rpath/libsqlcipher.dylib" "${OUT}/libsqlcipher.dylib"

# ── 2. cr-sqlite → crsqlite.dylib (loadable extension, ${TRIPLE}) ────────────
echo "▸ building cr-sqlite (loadable extension; Rust nightly; ${TRIPLE})"
( cd "${SRC}/cr-sqlite/core"
  make clean >/dev/null 2>&1 || true
  # Pin cargo to ${TRIPLE} so a host machine can cross-produce the other slice.
  CARGO_BUILD_TARGET="${TRIPLE}" make loadable >/dev/null
)
cp "${SRC}/cr-sqlite/core/dist/crsqlite.dylib" "${OUT}/crsqlite.dylib"

# ── 3. Contract test (only runnable for the host arch) ───────────────────────
if [ "${ARCH}" = "${HOST_ARCH}" ]; then
  echo "▸ contract test (test/contract.c)"
  "${CC}" ${ARCHFLAGS} -O2 -I"${SRC}/sqlcipher" "${ROOT}/test/contract.c" \
     -L"${OUT}" -lsqlcipher -Wl,-rpath,"${OUT}" \
     -o "${OUT}/contract"
  rm -f /tmp/hq-native-contract.db
  "${OUT}/contract" "${OUT}/crsqlite.dylib" /tmp/hq-native-contract.db
else
  echo "▸ contract test skipped (cross-built ${ARCH} on ${HOST_ARCH}; runs in CI)"
fi

echo "✅ macOS/${ARCH} artifacts in ${OUT}:"
ls -la "${OUT}"
echo "    dependencies:"
otool -L "${OUT}/libsqlcipher.dylib" | sed 's/^/    /'
