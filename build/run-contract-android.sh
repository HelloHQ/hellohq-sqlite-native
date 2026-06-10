#!/usr/bin/env bash
# run-contract-android.sh — compile test/contract.c for Android x86_64 and run it
# on a booted emulator (via adb), against the built per-ABI artifact. Verifies the
# Android binary is capability-correct ON the real OS, not just that it linked.
#
# Runs inside reactivecircus/android-emulator-runner (emulator booted, adb ready).
# Expects the android artifact extracted under dist/android/ (incl. sqlite3.h).
#
#   env:  ANDROID_NDK_HOME  (set by the NDK setup step)
set -euo pipefail

: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ART="${ROOT}/dist/android"
ABI="x86_64"                                   # the emulator ABI
API="${ANDROID_API:-24}"
TRIPLE="x86_64-linux-android${API}"
CC="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin/${TRIPLE}-clang"
LIBS="${ART}/${ABI}"
DEV="/data/local/tmp/hq-contract"

[ -f "${LIBS}/libsqlcipher.so" ] || { echo "❌ missing ${LIBS}/libsqlcipher.so" >&2; exit 1; }
[ -f "${LIBS}/libcrsqlite.so" ] || { echo "❌ missing ${LIBS}/libcrsqlite.so" >&2; exit 1; }

echo "▸ compiling contract.c for ${TRIPLE}"
cc_out="${ROOT}/contract-android"
"${CC}" -O2 -I"${ART}" "${ROOT}/test/contract.c" \
  -L"${LIBS}" -lsqlcipher -o "${cc_out}"

echo "▸ pushing to emulator"
adb wait-for-device
adb shell "rm -rf ${DEV}; mkdir -p ${DEV}"
adb push "${cc_out}" "${LIBS}/libsqlcipher.so" "${LIBS}/libcrsqlite.so" "${DEV}/"
adb shell "chmod 755 ${DEV}/contract-android"

echo "▸ running contract on emulator"
adb shell "cd ${DEV} && LD_LIBRARY_PATH=${DEV} ./contract-android ${DEV}/libcrsqlite.so ${DEV}/hq.db" \
  | tee /tmp/android-contract.out
grep -q "CONTRACT OK" /tmp/android-contract.out || { echo "❌ contract failed on emulator" >&2; exit 1; }
echo "✅ Android capability contract passed on the emulator"
