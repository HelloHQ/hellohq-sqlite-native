#!/usr/bin/env bash
# build-macos.sh — build the HelloHQ native DB layer for the HOST macOS arch:
#   dist/macos-<arch>/libsqlcipher.dylib   (SQLCipher = the sqlite3 library)
#   dist/macos-<arch>/crsqlite.dylib       (cr-sqlite loadable extension)
#
# A universal binary is produced by building each arch NATIVELY on its own runner
# (arm64 on macos-14, x86_64 on macos-13) and fusing with build/lipo-macos.sh.
# This is native-only by design: cr-sqlite uses `-Zbuild-std` and does NOT
# cross-compile cleanly, so each arch is built on a matching runner — no local
# cross-build. (SQLCipher's C cross-builds fine, but cr-sqlite is the constraint.)
#
# Crypto provider: **CommonCrypto** (Apple system framework; -DSQLCIPHER_CRYPTO_CC
# + -framework Security). No OpenSSL → the artifact has NO third-party dynamic
# dependency and loads on any mac without Homebrew. (OpenSSL was the bring-up
# path; CommonCrypto is the shippable one — ROADMAP Milestone 1.)
#
# Toolchain: Apple clang via `xcrun` (the PATH `clang` may be Homebrew LLVM, which
# mis-links the macOS SDK), tclsh (SQLCipher autosetup), Rust **nightly** with
# rust-src (cr-sqlite uses -Zbuild-std).
#
# Usage:  bash build/fetch.sh && bash build/build-macos.sh
set -euo pipefail

ARCH="$(uname -m)"                     # native arch only (arm64 | x86_64)
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

# ── 2. cr-sqlite → crsqlite.dylib (loadable extension, host arch) ────────────
echo "▸ building cr-sqlite (loadable extension; Rust nightly)"
( cd "${SRC}/cr-sqlite/core"
  make clean >/dev/null 2>&1 || true
  make loadable >/dev/null            # native host build (no -Zbuild-std cross)
)
cp "${SRC}/cr-sqlite/core/dist/crsqlite.dylib" "${OUT}/crsqlite.dylib"

# ── 3. Contract test ─────────────────────────────────────────────────────────
echo "▸ contract test (test/contract.c)"
"${CC}" ${ARCHFLAGS} -O2 -I"${SRC}/sqlcipher" "${ROOT}/test/contract.c" \
   -L"${OUT}" -lsqlcipher -Wl,-rpath,"${OUT}" \
   -o "${OUT}/contract"
rm -f /tmp/hq-native-contract.db
"${OUT}/contract" "${OUT}/crsqlite.dylib" /tmp/hq-native-contract.db

echo "✅ macOS/${ARCH} artifacts in ${OUT}:"
ls -la "${OUT}"
echo "    dependencies:"
otool -L "${OUT}/libsqlcipher.dylib" | sed 's/^/    /'
