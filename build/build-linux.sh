#!/usr/bin/env bash
# build-linux.sh — build the HelloHQ native DB layer for Linux x86_64:
#   dist/linux-x64/libsqlcipher.so   (SQLCipher = the sqlite3 library)
#   dist/linux-x64/crsqlite.so       (cr-sqlite loadable extension)
#
# Crypto provider: **OpenSSL** (no CommonCrypto on Linux). The .so links the
# system libcrypto — acceptable on Linux where OpenSSL is ubiquitous; a fully
# static libcrypto is a future hardening option (see ROADMAP).
#
# Build deps (CI installs these): clang, make, tcl (SQLCipher autosetup),
# libssl-dev, patchelf, and a **nightly Rust** toolchain for cr-sqlite.
#
# Usage:  bash build/fetch.sh && bash build/build-linux.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC="${ROOT}/.src"
OUT="${ROOT}/dist/linux-x64"
mkdir -p "${OUT}"
JOBS="$(nproc 2>/dev/null || echo 4)"

# ── 1. SQLCipher → libsqlcipher.so (OpenSSL codec) ───────────────────────────
echo "▸ building SQLCipher (OpenSSL codec)"
( cd "${SRC}/sqlcipher"
  make clean >/dev/null 2>&1 || true
  ./configure --with-tempstore=yes \
    CFLAGS="-O2 -fPIC -DSQLITE_HAS_CODEC \
            -DSQLITE_TEMP_STORE=2 \
            -DSQLITE_EXTRA_INIT=sqlcipher_extra_init \
            -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown" \
    LDFLAGS="-lcrypto" >/dev/null
  make -j"${JOBS}" libsqlite3.so >/dev/null
)
# The autosetup build emits a versioned soname; copy the real object and rename
# its SONAME so consumers dlopen `libsqlcipher.so`.
cp "$(readlink -f "${SRC}/sqlcipher/libsqlite3.so")" "${OUT}/libsqlcipher.so"
patchelf --set-soname libsqlcipher.so "${OUT}/libsqlcipher.so"

# ── 2. cr-sqlite → crsqlite.so (loadable extension) ──────────────────────────
echo "▸ building cr-sqlite (loadable extension; Rust nightly)"
( cd "${SRC}/cr-sqlite/core" && make clean >/dev/null 2>&1 || true; make loadable >/dev/null )
cp "${SRC}/cr-sqlite/core/dist/crsqlite.so" "${OUT}/crsqlite.so"

# ── 3. Contract test ─────────────────────────────────────────────────────────
echo "▸ contract test (test/contract.c)"
cc -O2 -I"${SRC}/sqlcipher" "${ROOT}/test/contract.c" \
   -L"${OUT}" -lsqlcipher -Wl,-rpath,'$ORIGIN' -Wl,-rpath,"${OUT}" \
   -o "${OUT}/contract"
rm -f /tmp/hq-native-contract.db
"${OUT}/contract" "${OUT}/crsqlite.so" /tmp/hq-native-contract.db

echo "✅ Linux x64 artifacts in ${OUT}:"
ls -la "${OUT}"
echo "    dependencies:"; ldd "${OUT}/libsqlcipher.so" | sed 's/^/    /'
