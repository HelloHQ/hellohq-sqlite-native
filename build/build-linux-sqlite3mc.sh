#!/usr/bin/env bash
# build-linux-sqlite3mc.sh — build SQLite3 Multiple Ciphers for Linux x86_64:
#   dist/linux-x64/libsqlite3mc.so        (the sqlite3 library, MC ciphers built in)
#   dist/linux-x64/sqlite3mc-include/     (public headers, for the contract test)
#
# This is a SEPARATE library from libsqlcipher.so (build-linux.sh). We ship both:
# SQLCipher for consumers on the SQLCipher-proper API, sqlite3mc for the Flutter
# app, whose hellohq_db issues `PRAGMA cipher = 'sqlcipher'` + `PRAGMA legacy = 4`
# — sqlite3mc-only pragmas that real SQLCipher REJECTS. Pointing the app at
# libsqlcipher.so instead is a known dead end: it was tried on Windows and
# reverted in HelloHQ/hellohq a9735d15f. See HelloHQ/hellohq#1074.
#
# ── Why this exists (HelloHQ/hellohq, Linux release blocker) ─────────────────
# Linux was the only platform with no provisioned sqlite3mc. macOS/iOS get one
# from the SPM frameworks, Windows gets sqlite3mc.dll from this repo, and
# `flutter test` gets test libs from fetch-test-db-libs.sh — but the Linux
# DESKTOP APP was expected to compile sqlite3mc itself, via package:sqlite3's
# `hook/build.dart` and the amalgamation vendored in the HelloHQ sqlite3.dart
# fork.
#
# That hook does not run during `flutter build linux`. It opens with
#
#     if (!input.config.buildCodeAssets) { return; }
#
# and a Flutter Linux desktop build does not request code assets (setting
# `flutter config --enable-native-assets true` does not change this). The
# measured consequence: build/linux/x64/*/release/bundle/lib contains NO sqlite3
# library at all, and the app resolves libsqlite3.so.0 from
# /lib/x86_64-linux-gnu — the distro SQLite, which has no encryption codec. So
# `PRAGMA cipher` returns "" and hellohq_db's assertSqlcipher throws
# UnsupportedError on first database open. The app fails CLOSED (no data is
# written unencrypted), but Linux is unusable.
#
# Shipping the library from here removes Linux's dependence on a mechanism that
# does not run, and puts all three desktop platforms on provisioned,
# trust-gated artifacts.
#
# ── Naming is load-bearing ───────────────────────────────────────────────────
# The consumer sets `source: system` + `name_linux: sqlite3mc`, which
# package:sqlite3 resolves through
#   OS.linux.libraryFileName('sqlite3mc', ...)  ->  libsqlite3mc.so
# so the output filename AND its SONAME must both be exactly `libsqlite3mc.so`.
# Do not rename the output. (Same care as the Windows script: there
# `name_windows: sqlite3mc` resolves `sqlite3mc.dll`.)
#
# ── Version lockstep ─────────────────────────────────────────────────────────
# upstream.lock pins sqlite3mc to the SAME version vendored in the sqlite3.dart
# fork's third_party/sqlite3mc/. A mismatch would key and format databases with
# different parameters across platforms. Bump both or neither.
#
# Crypto provider: NONE external. sqlite3mc carries its own AES/SHA/PBKDF2, so
# unlike libsqlcipher.so this library needs no libcrypto beside it.
#
# Build deps (CI installs these): clang, cmake, ninja-build, patchelf.
# No Rust, no OpenSSL, no tcl.
#
# Usage:
#   SQLITE3MC=1 bash build/fetch.sh && bash build/build-linux-sqlite3mc.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC="${ROOT}/.src/sqlite3mc"
BLD="${ROOT}/.build/sqlite3mc-linux-x64"
OUT="${ROOT}/dist/linux-x64"

if [ ! -d "${SRC}" ]; then
  echo "sqlite3mc source missing at ${SRC} — run: SQLITE3MC=1 bash build/fetch.sh" >&2
  exit 1
fi
mkdir -p "${OUT}"
JOBS="$(nproc 2>/dev/null || echo 4)"

# ── 1. Configure ─────────────────────────────────────────────────────────────
# BUILD_SHELL=OFF: we ship a library, not the sqlite3mc CLI.
# STATIC=OFF: SQLITE3MC_TARGET becomes `sqlite3mc` (shared) → libsqlite3mc.so.
echo "▸ configuring sqlite3mc (clang, x86_64, Release)"
cmake -S "${SRC}" -B "${BLD}" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DSQLITE3MC_STATIC=OFF \
  -DSQLITE3MC_BUILD_SHELL=OFF

# ── 2. Build ─────────────────────────────────────────────────────────────────
echo "▸ building sqlite3mc"
cmake --build "${BLD}" --target sqlite3mc --parallel "${JOBS}"

# ── 3. Collect ───────────────────────────────────────────────────────────────
# Search rather than hard-code the path, so a generator change cannot silently
# produce an empty artifact.
so="$(find "${BLD}" -name 'libsqlite3mc.so*' -type f | head -1)"
if [ -z "${so}" ]; then
  echo "libsqlite3mc.so not produced under ${BLD}" >&2
  find "${BLD}" -name '*.so*' | head -20 >&2
  exit 1
fi
cp "$(readlink -f "${so}")" "${OUT}/libsqlite3mc.so"

# The consumer dlopens the bare name, so the SONAME must match it exactly —
# otherwise the dynamic loader records a versioned dependency the app cannot
# satisfy. Same treatment build-linux.sh gives libsqlcipher.so.
patchelf --set-soname libsqlite3mc.so "${OUT}/libsqlite3mc.so"

# Headers for the contract test. sqlite3mc's own sqlite3.h collides by name with
# the one SQLCipher ships into this same dist dir, so keep it in a subdirectory —
# the contract test then compiles unchanged against either library by choosing
# the include dir (-I), not by editing its #include.
INC="${OUT}/sqlite3mc-include"
mkdir -p "${INC}"
for h in sqlite3.h sqlite3ext.h sqlite3mc.h sqlite3mc_version.h; do
  cp "${SRC}/src/${h}" "${INC}/${h}"
done

# ── 4. Verify exports ────────────────────────────────────────────────────────
# cr-sqlite is registered per-connection via sqlite3_load_extension AFTER the key
# pragma. If the export table lacks those symbols the app cannot load cr-sqlite
# at all — this is precisely the failure the Linux leg hit with the upstream
# prebuilt, so gate on it here rather than at runtime.
echo "▸ verifying export table"
missing=()
for sym in sqlite3_open sqlite3_key sqlite3_rekey \
           sqlite3_enable_load_extension sqlite3_load_extension; do
  # -w so sqlite3_open is not satisfied by sqlite3_open_v2 ('_' is a word
  # character, so there is no boundary between "open" and "_v2").
  if ! nm -D --defined-only "${OUT}/libsqlite3mc.so" | awk '{print $NF}' \
       | grep -qxF "${sym}"; then
    missing+=("${sym}")
  fi
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "libsqlite3mc.so is missing required exports: ${missing[*]}" >&2
  exit 1
fi

# ── 5. Verify it is genuinely sqlite3mc, not plain SQLite ────────────────────
# The whole point of this artifact is the MC codec. A build that silently fell
# back to vanilla SQLite would export the symbols above and still leave
# `PRAGMA cipher` empty — exactly the failure this replaces, only harder to see.
echo "▸ verifying the MC codec is present"
if ! nm -D --defined-only "${OUT}/libsqlite3mc.so" | grep -q 'sqlite3mc_'; then
  echo "libsqlite3mc.so exports no sqlite3mc_* symbols — this is not a Multiple Ciphers build" >&2
  exit 1
fi

echo "✅ Linux x64 sqlite3mc artifact in ${OUT}:"
ls -la "${OUT}/libsqlite3mc.so"
echo "    soname:"; patchelf --print-soname "${OUT}/libsqlite3mc.so" | sed 's/^/    /'
echo "    dependencies:"; ldd "${OUT}/libsqlite3mc.so" | sed 's/^/    /'
