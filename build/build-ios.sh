#!/usr/bin/env bash
# build-ios.sh — build the HelloHQ native DB layer for iOS as an xcframework:
#   dist/ios/libsqlcipher.xcframework   (device arm64 + simulator arm64/x86_64)
#   dist/ios/crsqlite.xcframework
#
# Crypto provider: **CommonCrypto** (same as macOS — system, no OpenSSL).
# iOS dynamic libraries must ship inside a framework/xcframework; the consuming
# app embeds it and dlopens within the app sandbox.
#
# Toolchain: Apple clang via xcrun (iphoneos + iphonesimulator SDKs), tclsh,
# nightly Rust with the apple-ios targets.
#
# ⚠️ FIRST-DRAFT — runs only on a macOS runner; not yet validated. SQLCipher's
#    autosetup cross-build for iOS SDKs + the xcframework assembly will need CI
#    iteration. The capability contract runs on a Simulator in CI (separate job).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC="${ROOT}/.src"
OUT="${ROOT}/dist/ios"
WORK="${ROOT}/dist/_ios-work"
mkdir -p "${OUT}" "${WORK}"
CC="$(xcrun -f clang)"

CC_DEFS="-DSQLITE_HAS_CODEC -DSQLCIPHER_CRYPTO_CC -DSQLITE_TEMP_STORE=2 \
         -DSQLITE_EXTRA_INIT=sqlcipher_extra_init \
         -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown"

# Build one SQLCipher static lib for a given SDK + arch.
build_sqlcipher_slice() { # <sdk> <arch> <min-flag> <out.a>
  local sdk="$1" arch="$2" minflag="$3" outa="$4"
  local sysroot; sysroot="$(xcrun --sdk "${sdk}" --show-sdk-path)"
  ( cd "${SRC}/sqlcipher"
    make clean >/dev/null 2>&1 || true
    ./configure --with-tempstore=yes \
      CC="${CC}" \
      CFLAGS="-arch ${arch} -isysroot ${sysroot} ${minflag} -O2 ${CC_DEFS}" \
      LDFLAGS="-arch ${arch} -isysroot ${sysroot} -framework Security -framework CoreFoundation" >/dev/null
    # Static lib slice (iOS ships static into the xcframework).
    make -j"$(sysctl -n hw.ncpu)" libsqlite3.a >/dev/null )
  cp "${SRC}/sqlcipher/libsqlite3.a" "${outa}"
}

echo "▸ SQLCipher slices (CommonCrypto)"
build_sqlcipher_slice iphoneos        arm64  "-mios-version-min=16.0"            "${WORK}/sc-device-arm64.a"
build_sqlcipher_slice iphonesimulator arm64  "-mios-simulator-version-min=16.0" "${WORK}/sc-sim-arm64.a"
build_sqlcipher_slice iphonesimulator x86_64 "-mios-simulator-version-min=16.0" "${WORK}/sc-sim-x86_64.a"
lipo -create "${WORK}/sc-sim-arm64.a" "${WORK}/sc-sim-x86_64.a" -output "${WORK}/sc-sim.a"

echo "▸ cr-sqlite slices (Rust nightly; apple-ios targets)"
build_crsqlite_slice() { # <rust-target> <out.a>
  local target="$1" outa="$2"
  # cr-sqlite's Makefile crosses for Apple via IOS_TARGET (sets -Zbuild-std,
  # RS_TARGET, and the iOS sysroot). Build the static bundle for the target.
  ( cd "${SRC}/cr-sqlite/core" && make clean >/dev/null 2>&1 || true
    IOS_TARGET="${target}" make loadable >/dev/null )
  cp "$(find "${SRC}/cr-sqlite" -path "*/${target}/release/libcrsql_bundle*.a" | head -1)" "${outa}"
}
build_crsqlite_slice aarch64-apple-ios        "${WORK}/cr-device-arm64.a"
build_crsqlite_slice aarch64-apple-ios-sim    "${WORK}/cr-sim-arm64.a"
build_crsqlite_slice x86_64-apple-ios         "${WORK}/cr-sim-x86_64.a"
lipo -create "${WORK}/cr-sim-arm64.a" "${WORK}/cr-sim-x86_64.a" -output "${WORK}/cr-sim.a"

echo "▸ assembling xcframeworks"
rm -rf "${OUT}/libsqlcipher.xcframework" "${OUT}/crsqlite.xcframework"
xcodebuild -create-xcframework \
  -library "${WORK}/sc-device-arm64.a" \
  -library "${WORK}/sc-sim.a" \
  -output  "${OUT}/libsqlcipher.xcframework"
xcodebuild -create-xcframework \
  -library "${WORK}/cr-device-arm64.a" \
  -library "${WORK}/cr-sim.a" \
  -output  "${OUT}/crsqlite.xcframework"

echo "✅ iOS xcframeworks in ${OUT}:"
ls -la "${OUT}"
echo "ℹ️  capability contract runs on a Simulator in CI (separate job)."
