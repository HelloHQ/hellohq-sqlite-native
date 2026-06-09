#!/usr/bin/env bash
# build-macos.sh — build the HelloHQ native DB layer for macOS:
#   dist/macos/libsqlcipher.dylib   (SQLCipher = the sqlite3 library)
#   dist/macos/crsqlite.dylib       (cr-sqlite loadable extension)
#
# This is the VALIDATED host recipe (macOS arm64, SQLCipher v4.16.0 + superfly
# cr-sqlite). Run `bash build/fetch.sh` first to materialize .src/.
#
# Toolchain: clang, tclsh (SQLCipher autosetup configure), Rust **nightly**
# (cr-sqlite uses #![feature(lang_items)]), and a crypto provider.
#
# Crypto provider: this script currently links **OpenSSL** (the validated path).
# TODO(Milestone 2): switch macOS/iOS to CommonCrypto (`-DSQLCIPHER_CRYPTO_CC`
# + `-framework Security`) to avoid bundling OpenSSL — see upstream.lock.
#
# TODO(Milestone 2): produce a universal (arm64 + x86_64) lib via lipo; this
# builds for the host arch only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC="${ROOT}/.src"
OUT="${ROOT}/dist/macos"
mkdir -p "${OUT}"

OPENSSL_PREFIX="${OPENSSL_PREFIX:-$(brew --prefix openssl@3 2>/dev/null || brew --prefix openssl 2>/dev/null || echo /opt/homebrew/opt/openssl@3)}"
[ -d "${OPENSSL_PREFIX}/include" ] || { echo "❌ OpenSSL not found at ${OPENSSL_PREFIX}" >&2; exit 1; }

# ── 1. SQLCipher → libsqlcipher.dylib ────────────────────────────────────────
echo "▸ building SQLCipher (autosetup configure + codec)"
( cd "${SRC}/sqlcipher"
  make clean >/dev/null 2>&1 || true
  ./configure --with-tempstore=yes \
    CFLAGS="-DSQLITE_HAS_CODEC -DSQLITE_TEMP_STORE=2 \
            -DSQLITE_EXTRA_INIT=sqlcipher_extra_init \
            -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown \
            -I${OPENSSL_PREFIX}/include" \
    LDFLAGS="-L${OPENSSL_PREFIX}/lib -lcrypto" >/dev/null
  # libsqlite3.dylib = shipped artifact; sqlite3 shell = used by the smoke test only.
  make -j"$(sysctl -n hw.ncpu)" libsqlite3.dylib sqlite3 >/dev/null
)
cp "${SRC}/sqlcipher/libsqlite3.dylib" "${OUT}/libsqlcipher.dylib"
install_name_tool -id "@rpath/libsqlcipher.dylib" "${OUT}/libsqlcipher.dylib"

# ── 2. cr-sqlite → crsqlite.dylib (loadable extension) ───────────────────────
echo "▸ building cr-sqlite (loadable extension; Rust nightly)"
( cd "${SRC}/cr-sqlite/core" && make loadable >/dev/null )
cp "${SRC}/cr-sqlite/core/dist/crsqlite.dylib" "${OUT}/crsqlite.dylib"

# ── 3. Contract test (capability checklist against the built artifact) ───────
echo "▸ contract test (test/contract.c)"
cc -O2 -I"${SRC}/sqlcipher" "${ROOT}/test/contract.c" \
   -L"${OUT}" -lsqlcipher -Wl,-rpath,"${OUT}" \
   -o "${OUT}/contract"
rm -f /tmp/hq-native-contract.db
"${OUT}/contract" "${OUT}/crsqlite.dylib" /tmp/hq-native-contract.db

echo "✅ macOS artifacts in ${OUT}:"
ls -la "${OUT}"
