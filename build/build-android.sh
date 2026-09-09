#!/usr/bin/env bash
# build-android.sh — build the HelloHQ native DB layer for Android, per ABI:
#   dist/android/<abi>/libsqlcipher.so   (SQLCipher = the sqlite3 library)
#   dist/android/<abi>/libcrsqlite.so    (cr-sqlite loadable extension; lib* for
#                                         Android/Gradle jniLibs packaging)
# ABIs: arm64-v8a · armeabi-v7a · x86_64   (jniLibs layout)
#
# Crypto provider: **OpenSSL** (Android has no CommonCrypto). Per-ABI prebuilt
# OpenSSL static libs are expected under $OPENSSL_ANDROID/<abi> (the CI provisions
# them, or builds them once); we static-link libcrypto so each .so is
# self-contained on device.
#
# Toolchain: Android NDK (clang per ABI), tclsh, nightly Rust with the
# *-linux-android targets + cargo-ndk.
#
# ⚠️ FIRST-DRAFT — cross-compiles on a Linux runner; not yet validated. The NDK
#    triple/clang wiring and the OpenSSL-per-ABI provisioning will need CI
#    iteration. Capability contract runs on an emulator in CI (separate job).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC="${ROOT}/.src"
OUT="${ROOT}/dist/android"
: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to the NDK root}"
: "${OPENSSL_ANDROID:?set OPENSSL_ANDROID to a dir with <abi>/{include,lib} OpenSSL}"
API="${ANDROID_API:-24}"
TOOLCHAIN="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64"

# Android 15 runs 64-bit devices on 16 KB memory pages, and refuses to load a
# shared library whose PT_LOAD segments are aligned to the old 4 KB page size.
# NDK r26 still defaults to 4 KB (r27+ flipped the default), so every .so we
# ship has to ask for it explicitly — this applies to BOTH libraries, not just
# cr-sqlite: they are dlopen'd from the same jniLibs directory and either one
# being misaligned bricks the app on a 16 KB device.
#
# Verified against NDK r26d: a trivial .so links at align 4096 without this
# flag and 16384 with it. The assertion at the bottom of this script is what
# actually keeps it true.
PAGE16K_LDFLAG="-Wl,-z,max-page-size=16384"

# ABI → (clang target triple, rust target)
abi_clang_triple() { case "$1" in
  arm64-v8a)   echo "aarch64-linux-android${API}" ;;
  armeabi-v7a) echo "armv7a-linux-androideabi${API}" ;;
  x86_64)      echo "x86_64-linux-android${API}" ;;
esac; }
abi_rust_target() { case "$1" in
  arm64-v8a)   echo "aarch64-linux-android" ;;
  armeabi-v7a) echo "armv7-linux-androideabi" ;;
  x86_64)      echo "x86_64-linux-android" ;;
esac; }

build_abi() {
  local abi="$1"
  local triple; triple="$(abi_clang_triple "${abi}")"
  local rust;   rust="$(abi_rust_target "${abi}")"
  local cc="${TOOLCHAIN}/bin/${triple}-clang"
  local osl="${OPENSSL_ANDROID}/${abi}"
  local out="${OUT}/${abi}"
  mkdir -p "${out}"
  echo "▸ ${abi} (clang ${triple})"

  # SQLCipher — static-link libcrypto so the .so is self-contained on device.
  ( cd "${SRC}/sqlcipher"
    make clean >/dev/null 2>&1 || true
    # --disable-math: autosetup's libm run-probe fails when cross-compiling
    # (can't exec the target test binary); we don't use SQLite's math SQL
    # functions, so skip the probe rather than wrongly linking the host libm.
    ./configure --with-tempstore=yes --disable-math \
      CC="${cc}" \
      CFLAGS="-O2 -fPIC -DSQLITE_HAS_CODEC -DSQLITE_THREADSAFE=1 \
              -DSQLITE_TEMP_STORE=2 \
              -DSQLITE_EXTRA_INIT=sqlcipher_extra_init \
              -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown \
              -I${osl}/include" \
      LDFLAGS="-L${osl}/lib -l:libcrypto.a -llog ${PAGE16K_LDFLAG}" >/dev/null   # -llog: SQLite/Android uses __android_log_*
    make -j"$(nproc)" libsqlite3.so >/dev/null )
  cp "$(readlink -f "${SRC}/sqlcipher/libsqlite3.so")" "${out}/libsqlcipher.so"
  patchelf --set-soname libsqlcipher.so "${out}/libsqlcipher.so" 2>/dev/null || true

  # cr-sqlite's Makefile crosses for Android via ANDROID_TARGET + ANDROID_NDK_HOME
  # (sets the NDK clang, sysroot, -Zbuild-std, and the .so extension).
  ( cd "${SRC}/cr-sqlite/core"
    make clean >/dev/null 2>&1 || true
    ANDROID_TARGET="${rust}" ANDROID_NDK_HOME="${ANDROID_NDK_HOME}" \
      NDK_HOSTARCH=linux-x86_64 \
      make SHARED_CFLAGS="${PAGE16K_LDFLAG}" loadable >/dev/null )
  # Android requires lib*.so naming (Gradle only packages/extracts lib*.so into
  # the APK's jniLibs), and the consumer dlopens it by name. Ship libcrsqlite.so.
  cp "${SRC}/cr-sqlite/core/dist/crsqlite.so" "${out}/libcrsqlite.so"
}

for abi in arm64-v8a armeabi-v7a x86_64; do build_abi "${abi}"; done

# Ship the generated amalgamation header (ABI-independent) so the off-device
# contract compile in the android-contract job can #include "sqlite3.h".
cp "${SRC}/sqlcipher/sqlite3.h" "${OUT}/sqlite3.h"

# ── 16 KB page alignment gate ────────────────────────────────────────────────
# A misaligned .so does not fail to build; it fails at dlopen on an Android 15
# device, long after this repo has published and something downstream has pinned
# it. v0.1.4 shipped all six libraries at 4 KB and nothing here noticed. So the
# producer proves the property itself rather than leaving it to the consumer.
#
# Read PT_LOAD alignment straight out of the program headers with the NDK's own
# readelf — already required by this script, so no new build dependency.
READELF="${TOOLCHAIN}/bin/llvm-readelf"
misaligned=0
while IFS= read -r so; do
  # Align is the final hex column of each LOAD line. Take the MINIMUM across
  # segments, not the last one: they agree today, but one lagging segment is
  # exactly the case worth catching.
  align_dec=""
  while read -r a; do
    [ -n "$a" ] || continue
    if [ -z "${align_dec}" ] || [ $(( a )) -lt "${align_dec}" ]; then align_dec=$(( a )); fi
  done < <("${READELF}" --program-headers "${so}" \
    | awk '/^ *LOAD/ { for (i = NF; i >= 1; i--) if ($i ~ /^0x[0-9a-fA-F]+$/) { print $i; break } }')
  if [ -z "${align_dec}" ]; then
    echo "❌ ${so}: no PT_LOAD segments found — not a shared library?" >&2
    misaligned=1
    continue
  fi
  if [ "${align_dec}" -lt 16384 ]; then
    echo "❌ ${so}: PT_LOAD align ${align_dec} < 16384 (Android 15 will not dlopen this)" >&2
    misaligned=1
  else
    echo "    ✓ $(basename "$(dirname "${so}")")/$(basename "${so}") align ${align_dec}"
  fi
done < <(find "${OUT}" -name '*.so' | sort)
if [ "${misaligned}" -ne 0 ]; then
  echo "❌ refusing to publish 4 KB-aligned Android libraries — see PAGE16K_LDFLAG above." >&2
  exit 1
fi

echo "✅ Android artifacts under ${OUT} (all 16 KB aligned):"
find "${OUT}" -name '*.so' | sed 's/^/    /'
echo "ℹ️  capability contract runs on an emulator in CI (separate job)."
