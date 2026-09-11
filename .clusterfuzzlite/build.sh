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

# cr-sqlite core, static feature (no loadable-extension entry; core_init
# auto-registers it into the embedded SQLite).
( cd "${CORE}/rs/bundle_static" \
    && cargo build --release --features static,omit_load_extension )
RS_A="${CORE}/rs/bundle_static/target/release/libcrsql_bundle_static.a"

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
