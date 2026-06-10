#!/usr/bin/env bash
# build-ios.sh — build the HelloHQ native DB layer for iOS as DYNAMIC xcframeworks:
#   dist/ios/libsqlcipher.xcframework   (device arm64 + simulator arm64/x86_64)
#   dist/ios/crsqlite.xcframework
#
# DYNAMIC, not static: the Path A mechanism loads cr-sqlite per-connection via
# `sqlite3_load_extension` (after PRAGMA key), which requires a dynamic library
# `dlopen` can reach. So both ship as dynamic dylibs (install_name @rpath/…)
# inside xcframeworks; the consuming app embeds + signs them, and resolves them
# by name from its Frameworks dir (BundledNativeLibs). (doc 47 §4, §8c.)
#
# Crypto provider: **CommonCrypto** (system; no OpenSSL). Toolchain: Apple clang
# via xcrun (iphoneos + iphonesimulator SDKs), tclsh (amalgamation gen), nightly
# Rust with the apple-ios targets (cr-sqlite uses -Zbuild-std).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC="${ROOT}/.src"
OUT="${ROOT}/dist/ios"
WORK="${ROOT}/dist/_ios-work"
rm -rf "${WORK}"; mkdir -p "${OUT}" "${WORK}"

CC="$(xcrun -f clang)"
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
IOS_MIN="16.0"
DEFS="-DSQLITE_HAS_CODEC -DSQLCIPHER_CRYPTO_CC -DSQLITE_THREADSAFE=1 \
      -DSQLITE_TEMP_STORE=2 -DSQLITE_EXTRA_INIT=sqlcipher_extra_init \
      -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown"

# ── 1. SQLCipher: generate the amalgamation once, compile a dynamic dylib per
#       slice. (Compiling sqlite3.c directly is reliable across iOS SDKs; the
#       autosetup `configure` cross-build to a shared lib is not.) ─────────────
echo "▸ SQLCipher amalgamation (native)"
( cd "${SRC}/sqlcipher"
  make clean >/dev/null 2>&1 || true
  ./configure --with-tempstore=yes --disable-math \
    CFLAGS="-DSQLITE_HAS_CODEC -DSQLCIPHER_CRYPTO_CC" LDFLAGS="-framework Security" >/dev/null
  make sqlite3.c >/dev/null )
AMALG="${SRC}/sqlcipher/sqlite3.c"

# The dylib FILENAME inside each xcframework slice must be the canonical name the
# app dlopens (BundledNativeLibs: libsqlcipher.dylib / crsqlite.dylib) — dyld
# resolves dlopen-by-name by filename. Put each slice in its own dir, same name.
mkdir -p "${WORK}/sc/device" "${WORK}/sc/sim" "${WORK}/cr/device" "${WORK}/cr/sim"

sc_slice() { # <sysroot> <arch> <min-flag> <out.dylib>
  "${CC}" -dynamiclib -arch "$2" -isysroot "$1" "$3" -O2 -fPIC ${DEFS} \
    -framework Security -framework CoreFoundation \
    -install_name @rpath/libsqlcipher.dylib "${AMALG}" -o "$4"
}
echo "▸ SQLCipher dynamic dylib slices"
sc_slice "${IOS_SDK}" arm64  "-mios-version-min=${IOS_MIN}"            "${WORK}/sc/device/libsqlcipher.dylib"
sc_slice "${SIM_SDK}" arm64  "-mios-simulator-version-min=${IOS_MIN}" "${WORK}/sc-sim-arm64.dylib"
sc_slice "${SIM_SDK}" x86_64 "-mios-simulator-version-min=${IOS_MIN}" "${WORK}/sc-sim-x86_64.dylib"
lipo -create "${WORK}/sc-sim-arm64.dylib" "${WORK}/sc-sim-x86_64.dylib" -output "${WORK}/sc/sim/libsqlcipher.dylib"

# ── 2. cr-sqlite: dynamic loadable dylib per slice. The Makefile's iOS path
#       (IOS_TARGET) already links `dist/crsqlite.dylib` as a dynamic library;
#       just re-stamp its install_name to @rpath. ─────────────────────────────
echo "▸ cr-sqlite dynamic dylib slices"
cr_slice() { # <ios-rust-target> <out.dylib>
  ( cd "${SRC}/cr-sqlite/core"
    make clean >/dev/null 2>&1 || true
    IOS_TARGET="$1" make loadable >/dev/null )
  local built="${SRC}/cr-sqlite/core/dist/crsqlite.dylib"
  install_name_tool -id @rpath/crsqlite.dylib "${built}"
  cp "${built}" "$2"
}
cr_slice aarch64-apple-ios     "${WORK}/cr/device/crsqlite.dylib"
cr_slice aarch64-apple-ios-sim "${WORK}/cr-sim-arm64.dylib"
cr_slice x86_64-apple-ios      "${WORK}/cr-sim-x86_64.dylib"
lipo -create "${WORK}/cr-sim-arm64.dylib" "${WORK}/cr-sim-x86_64.dylib" -output "${WORK}/cr/sim/crsqlite.dylib"

# ── 3. Assemble dynamic xcframeworks (device slice + fat simulator slice) ─────
echo "▸ assembling dynamic xcframeworks"
rm -rf "${OUT}/libsqlcipher.xcframework" "${OUT}/crsqlite.xcframework"
xcodebuild -create-xcframework \
  -library "${WORK}/sc/device/libsqlcipher.dylib" \
  -library "${WORK}/sc/sim/libsqlcipher.dylib" \
  -output  "${OUT}/libsqlcipher.xcframework" >/dev/null
xcodebuild -create-xcframework \
  -library "${WORK}/cr/device/crsqlite.dylib" \
  -library "${WORK}/cr/sim/crsqlite.dylib" \
  -output  "${OUT}/crsqlite.xcframework" >/dev/null

echo "✅ iOS dynamic xcframeworks in ${OUT}:"
ls "${OUT}"
echo "ℹ️  capability verified by hellohq_db's iOS Simulator integration test."
