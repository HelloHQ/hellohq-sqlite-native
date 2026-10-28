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
#
#       Each slice also gets a dSYM, so App Store Connect can symbolicate a
#       crash inside cr-sqlite (hellohq#584). The C side is compiled with -g and
#       the Rust side with debug info kept in its objects. The Makefile compiles
#       and links the C sources in one clang call, whose temporary objects are
#       gone afterwards, so the dSYM is the one clang's driver writes next to
#       the dylib during that call (a later dsymutil would miss the C half).
#       `strip -S` then drops the debug map from the shipped dylib. Neither step
#       changes the dylib's UUID, which is what ties it to its dSYM.
echo "▸ cr-sqlite dynamic dylib slices (+ dSYMs)"
cr_slice() { # <ios-rust-target> <out.dylib> <out.dSYM>
  ( cd "${SRC}/cr-sqlite/core"
    make clean >/dev/null 2>&1 || true
    rm -rf dist/crsqlite.dylib.dSYM
    IOS_TARGET="$1" CARGO_PROFILE_RELEASE_DEBUG=limited \
      CARGO_PROFILE_RELEASE_SPLIT_DEBUGINFO=off \
      make loadable SHARED_CFLAGS=-g >/dev/null )
  local built="${SRC}/cr-sqlite/core/dist/crsqlite.dylib"
  install_name_tool -id @rpath/crsqlite.dylib "${built}"
  rm -rf "$3"
  [ -d "${built}.dSYM" ] || { echo "clang wrote no ${built}.dSYM" >&2; exit 1; }
  cp -R "${built}.dSYM" "$3"
  strip -S "${built}"
  dsym_matches "${built}" "$3"
  cp "${built}" "$2"
}
uuids() { dwarfdump --uuid "$1" | awk '{print $2}' | sort; }
dsym_matches() { # <binary> <dSYM>: same UUID per arch, and real debug info
  local dwarf
  dwarf="$(find "$2/Contents/Resources/DWARF" -type f | head -1)"
  [ -n "${dwarf}" ] && [ "$(uuids "$1")" = "$(uuids "${dwarf}")" ] \
    || { echo "dSYM $2 does not match $1" >&2; exit 1; }
  # grep -c, not -q: -q would stop reading early and, under pipefail, fail on
  # dwarfdump's SIGPIPE.
  [ "$(dwarfdump --debug-info "${dwarf}" | grep -c DW_TAG_compile_unit)" -gt 0 ] \
    || { echo "dSYM $2 has no debug info" >&2; exit 1; }
}
mkdir -p "${WORK}/cr/device-dsym" "${WORK}/cr/sim-dsym"
cr_slice aarch64-apple-ios     "${WORK}/cr/device/crsqlite.dylib" "${WORK}/cr/device-dsym/crsqlite.dylib.dSYM"
cr_slice aarch64-apple-ios-sim "${WORK}/cr-sim-arm64.dylib"       "${WORK}/cr-sim-arm64.dylib.dSYM"
cr_slice x86_64-apple-ios      "${WORK}/cr-sim-x86_64.dylib"      "${WORK}/cr-sim-x86_64.dylib.dSYM"
lipo -create "${WORK}/cr-sim-arm64.dylib" "${WORK}/cr-sim-x86_64.dylib" -output "${WORK}/cr/sim/crsqlite.dylib"
# The fat simulator dylib's dSYM: the arm64 bundle with both archs' DWARF.
SIM_DSYM="${WORK}/cr/sim-dsym/crsqlite.dylib.dSYM"
cp -R "${WORK}/cr-sim-arm64.dylib.dSYM" "${SIM_DSYM}"
rm "${SIM_DSYM}/Contents/Resources/DWARF/"*
lipo -create \
  "$(find "${WORK}/cr-sim-arm64.dylib.dSYM/Contents/Resources/DWARF" -type f | head -1)" \
  "$(find "${WORK}/cr-sim-x86_64.dylib.dSYM/Contents/Resources/DWARF" -type f | head -1)" \
  -output "${SIM_DSYM}/Contents/Resources/DWARF/crsqlite.dylib"
dsym_matches "${WORK}/cr/sim/crsqlite.dylib" "${SIM_DSYM}"

# ── 3. Assemble dynamic xcframeworks (device slice + fat simulator slice) ─────
echo "▸ assembling dynamic xcframeworks"
rm -rf "${OUT}/libsqlcipher.xcframework" "${OUT}/crsqlite.xcframework"
xcodebuild -create-xcframework \
  -library "${WORK}/sc/device/libsqlcipher.dylib" \
  -library "${WORK}/sc/sim/libsqlcipher.dylib" \
  -output  "${OUT}/libsqlcipher.xcframework" >/dev/null
# -debug-symbols needs an absolute path; each slice keeps its dSYM under
# <slice>/dSYMs/, where hellohq's framework wrap and Xcode's archive find it.
xcodebuild -create-xcframework \
  -library "${WORK}/cr/device/crsqlite.dylib" \
  -debug-symbols "${WORK}/cr/device-dsym/crsqlite.dylib.dSYM" \
  -library "${WORK}/cr/sim/crsqlite.dylib" \
  -debug-symbols "${SIM_DSYM}" \
  -output  "${OUT}/crsqlite.xcframework" >/dev/null

echo "✅ iOS dynamic xcframeworks in ${OUT}:"
ls "${OUT}"
echo "ℹ️  capability verified by hellohq_db's iOS Simulator integration test."
