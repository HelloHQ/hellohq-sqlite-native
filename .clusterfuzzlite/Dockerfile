# ClusterFuzzLite build image. base-builder-rust = the OSS-Fuzz base-builder
# toolchain (clang + libFuzzer + sanitizers, $CC/$CXX/$CFLAGS/$LIB_FUZZING_ENGINE)
# plus a preinstalled rustup — so build/setup-rust.sh can add cr-sqlite's pinned
# nightly (+ rust-src) with no curl|sh bootstrap. Pinned by digest.
FROM gcr.io/oss-fuzz-base/base-builder-rust:v1@sha256:433319ea1a6bbea6c1db1915a5d385021908cc62026d9f0efda2270ef6060de3

# make + tcl for the SQLite amalgamation build; the C/Rust toolchains are in the
# base image.
RUN apt-get update && apt-get install -y --no-install-recommends make tcl \
      && rm -rf /var/lib/apt/lists/*

COPY . $SRC/hellohq-sqlite-native
WORKDIR $SRC/hellohq-sqlite-native
COPY .clusterfuzzlite/build.sh $SRC/build.sh
