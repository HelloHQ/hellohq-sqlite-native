#!/usr/bin/env bash
# ClusterFuzzLite build script — builds fuzz/crsql_changes_fuzzer against a
# statically-linked cr-sqlite (which embeds SQLite and auto-registers cr-sqlite
# via SQLITE_EXTRA_INIT=core_init). No SQLCipher: the fuzzed parser is
# encryption-independent.
#
# Runs inside the image from .clusterfuzzlite/Dockerfile. $CC/$CXX/$CFLAGS/
# $CXXFLAGS/$LIB_FUZZING_ENGINE/$OUT/$WORK/$SRC are provided by OSS-Fuzz.
set -euo pipefail

ROOT="${SRC}/hellohq-sqlite-native"
CORE="${ROOT}/.src/cr-sqlite/core"

# Fetch + verify pinned upstream AND apply patches/*.patch (our unpack_columns
# bounds-check fix lands here), then install cr-sqlite's pinned Rust nightly.
cd "${ROOT}"
bash build/fetch.sh
bash build/setup-rust.sh

# base-builder-rust exports RUSTUP_TOOLCHAIN (nightly-2025-09-05 in the pinned
# image), and that env var outranks every other rustup override — including the
# rust-toolchain.toml cr-sqlite ships next to bundle_static. So setup-rust.sh
# installed cr-sqlite's pinned nightly (rustc 1.75) and cargo then ignored it and
# built with the image's rustc 1.91, which fails at
#   error[E0557]: feature has been removed — #![feature(concat_idents)]
#   (removed in 1.90.0)
# in sqlite3_capi. Unsetting it hands control back to rust-toolchain.toml, so the
# fuzzer is built with the same toolchain as every other platform build here.
unset RUSTUP_TOOLCHAIN

# cr-sqlite core, static feature (no loadable-extension entry; core_init
# auto-registers it into the embedded SQLite).
#
# --target is load-bearing, not cosmetic. ClusterFuzzLite exports
#   RUSTFLAGS=--cfg fuzzing -Zsanitizer=address -Cdebuginfo=1 -Cforce-frame-pointers
# at compile time (it is not set in the image, so inspecting the image shows
# nothing). Without an explicit --target, cargo applies RUSTFLAGS to HOST
# artifacts too, so the num-derive proc-macro is built with AddressSanitizer and
# the uninstrumented rustc process cannot load it:
#   error[E0463]: can't find crate for `num_derive`
# With --target, RUSTFLAGS reach only target artifacts and build scripts and
# proc-macros build clean — which is why cargo-fuzz always passes it. The output
# directory moves under target/<triple>/ accordingly.
#
# -Zbuild-std rebuilds the standard library under the same sanitizer RUSTFLAGS,
# so the whole Rust side is instrumented consistently instead of an instrumented
# crate linked against a prebuilt, uninstrumented std. This mirrors cr-sqlite's
# own recipe rather than inventing one — its Makefile has
#   asan: rs_build_flags=--target x86_64-unknown-linux-gnu -Zbuild-std
# and every Rust target there passes -Zbuild-std. It needs the rust-src component,
# which build/setup-rust.sh already installs.
#
# CRSQLITE_COMMIT_SHA: rs/core/src/sha.rs reads it with core::env!() at compile
# time, and cr-sqlite's Makefile exports it as `git rev-parse HEAD` on every Rust
# library target. This script calls cargo directly and so bypassed that export:
#   error: environment variable `CRSQLITE_COMMIT_SHA` not defined at compile time
# .src/cr-sqlite is a real checkout of the pinned commit (build/fetch.sh), so this
# is the same value the Makefile would produce. It is the only compile-time env!()
# in cr-sqlite's Rust besides OUT_DIR, which cargo sets itself.
RUST_TARGET="x86_64-unknown-linux-gnu"
CRSQLITE_COMMIT_SHA="$(git -C "${ROOT}/.src/cr-sqlite" rev-parse HEAD)"
export CRSQLITE_COMMIT_SHA
( cd "${CORE}/rs/bundle_static" \
    && cargo build --release --target "${RUST_TARGET}" -Zbuild-std \
         --features static,omit_load_extension )
RS_A="${CORE}/rs/bundle_static/target/${RUST_TARGET}/release/libcrsql_bundle_static.a"

# SQLite amalgamation + cr-sqlite's core_init (mirrors the Makefile's
# sqlite3-extra.c), compiled with the fuzzing sanitizer flags.
cat "${CORE}/src/sqlite/sqlite3.c" "${CORE}/src/core_init.c" > "${WORK}/sqlite3-extra.c"

CDEFS=(-DSQLITE_CORE -DSQLITE_EXTRA_INIT=core_init -DSQLITE_OMIT_LOAD_EXTENSION=1
       -DSQLITE_THREADSAFE=0 -DSQLITE_ENABLE_BYTECODE_VTAB -DHAVE_GETHOSTUUID=0)
INCS=(-I"${CORE}/src" -I"${CORE}/src/sqlite")

# Compile C objects with $CC/$CFLAGS; link with $CXX per OSS-Fuzz C guidance.
for c in "${WORK}/sqlite3-extra.c" \
         "${CORE}/src/crsqlite.c" "${CORE}/src/changes-vtab.c" \
         "${CORE}/src/ext-data.c" "${ROOT}/fuzz/crsql_changes_fuzzer.c"; do
  obj="${WORK}/$(basename "${c}").o"
  # shellcheck disable=SC2086
  $CC $CFLAGS "${CDEFS[@]}" "${INCS[@]}" -c "${c}" -o "${obj}"
done

# shellcheck disable=SC2086
$CXX $CXXFLAGS "${WORK}"/*.o "${RS_A}" ${LIB_FUZZING_ENGINE} \
  -o "${OUT}/crsql_changes_fuzzer"

# Seed corpus: OSS-Fuzz picks up <target>_seed_corpus.zip next to the binary.
( cd "${ROOT}/fuzz/corpus" && zip -q -r "${OUT}/crsql_changes_fuzzer_seed_corpus.zip" . )

echo "✅ built crsql_changes_fuzzer"
