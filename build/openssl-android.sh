#!/usr/bin/env bash
# openssl-android.sh — build static OpenSSL (libcrypto.a) per Android ABI from
# the pinned source (upstream.lock), into $OPENSSL_ANDROID/<abi>/{include,lib}.
# SQLCipher links this statically so each on-device .so is self-contained.
# Run before build-android.sh.
#
#   env:  ANDROID_NDK_HOME, OPENSSL_ANDROID, [ANDROID_API=24], [NDK_HOSTARCH=linux-x86_64]
set -euo pipefail

: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"
: "${OPENSSL_ANDROID:?set OPENSSL_ANDROID (output root)}"
API="${ANDROID_API:-24}"
NDK_HOSTARCH="${NDK_HOSTARCH:-linux-x86_64}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="${ROOT}/upstream.lock"
SRC="${ROOT}/.src/openssl"
TOOLCHAIN="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/${NDK_HOSTARCH}"

val() { # val <section> <key>  — tiny YAML reader (matches build/fetch.sh)
  python3 - "$LOCK" "$1" "$2" <<'PY'
import sys
lock, section, key = sys.argv[1:4]
cur = None
for raw in open(lock):
    line = raw.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"): continue
    if not line.startswith((" ", "\t")) and line.rstrip().endswith(":"):
        cur = line.strip()[:-1]; continue
    if cur == section and ":" in line:
        k, _, v = line.strip().partition(":")
        if k.strip() == key: print(v.strip()); break
PY
}

# Fetch the pinned OpenSSL commit (once).
if [ ! -d "${SRC}/.git" ]; then
  url="$(val openssl source)"; commit="$(val openssl commit)"
  echo "▸ openssl: ${url} @ ${commit:0:12}"
  rm -rf "${SRC}"; git init -q "${SRC}"
  git -C "${SRC}" remote add origin "${url}"
  git -C "${SRC}" fetch -q --depth 1 origin "${commit}"
  git -C "${SRC}" checkout -q FETCH_HEAD
  got="$(git -C "${SRC}" rev-parse HEAD)"
  [ "${got}" = "${commit}" ] || { echo "❌ openssl commit mismatch: ${got}" >&2; exit 1; }
fi

abi_target() { case "$1" in
  arm64-v8a)   echo android-arm64 ;;
  armeabi-v7a) echo android-arm ;;
  x86_64)      echo android-x86_64 ;;
esac; }

export ANDROID_NDK_ROOT="${ANDROID_NDK_HOME}"
export PATH="${TOOLCHAIN}/bin:${PATH}"

for abi in arm64-v8a armeabi-v7a x86_64; do
  target="$(abi_target "${abi}")"
  prefix="${OPENSSL_ANDROID}/${abi}"
  echo "▸ openssl ${abi} (${target}, API ${API})"
  ( cd "${SRC}"
    make clean >/dev/null 2>&1 || true
    ./Configure "${target}" -D__ANDROID_API__="${API}" \
      no-shared no-tests no-apps no-docs --prefix="${prefix}" >/dev/null
    make -j"$(nproc)" build_libs >/dev/null
    make install_dev >/dev/null )
  [ -f "${prefix}/lib/libcrypto.a" ] || { echo "❌ ${abi}: libcrypto.a missing" >&2; exit 1; }
done

echo "✅ OpenSSL static libs under ${OPENSSL_ANDROID}/<abi>/lib/libcrypto.a"
