# ClusterFuzzLite build image. base-builder-rust = the OSS-Fuzz base-builder
# toolchain (clang + libFuzzer + sanitizers, $CC/$CXX/$CFLAGS/$LIB_FUZZING_ENGINE)
# plus a preinstalled rustup — so build/setup-rust.sh can add cr-sqlite's pinned
# nightly (+ rust-src) with no curl|sh bootstrap. Pinned by digest.
FROM gcr.io/oss-fuzz-base/base-builder-rust:v1@sha256:433319ea1a6bbea6c1db1915a5d385021908cc62026d9f0efda2270ef6060de3

# make + tcl for the SQLite amalgamation build; the C/Rust toolchains are in the
# base image.
#
# libclang-dev is NOT optional. cr-sqlite's sqlite3_capi crate generates its FFI
# with bindgen, and bindgen dlopen()s libclang.so at build-script runtime to parse
# the SQLite headers. The base image ships OSS-Fuzz's source-built clang 22 but
# not libclang.so — only the libclang_rt.* sanitizer runtimes — so without this
# every fuzz build died in sqlite3_capi's build script with
#   Unable to find libclang: "couldn't find any valid shared libraries matching:
#   ['libclang.so', 'libclang-*.so', 'libclang.so.*', 'libclang-*.so.*']"
# and the fuzzers never built, let alone ran.
#
# Ubuntu 20.04 provides clang 10's libclang. That is only used to PARSE headers
# into Rust declarations; the fuzzer itself is still compiled by the image's
# clang 22 with the sanitizer flags, so the version gap does not reach the binary.
RUN apt-get update && apt-get install -y --no-install-recommends make tcl libclang-dev \
      && rm -rf /var/lib/apt/lists/*

# Point clang-sys at it explicitly. It checks LIBCLANG_PATH before `llvm-config`,
# and the llvm-config on PATH here belongs to OSS-Fuzz's clang 22, whose lib dir
# has no libclang.so — relying on the search would find the wrong toolchain first.
ENV LIBCLANG_PATH=/usr/lib/llvm-10/lib

COPY . $SRC/hellohq-sqlite-native
WORKDIR $SRC/hellohq-sqlite-native
COPY .clusterfuzzlite/build.sh $SRC/build.sh
