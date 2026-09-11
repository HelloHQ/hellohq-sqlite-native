# ClusterFuzzLite build image. Reuses the OSS-Fuzz base-builder toolchain
# (clang + libFuzzer + sanitizers) and adds what THIS repo's build needs:
# make/tcl for the SQLite amalgamation, and a rustup that build/setup-rust.sh
# then points at cr-sqlite's pinned nightly (+ rust-src) — the same channel CI
# uses, read from cr-sqlite's own rust-toolchain.toml so it never drifts.
FROM gcr.io/oss-fuzz-base/base-builder:v1

RUN apt-get update && apt-get install -y --no-install-recommends \
      make tcl curl ca-certificates && rm -rf /var/lib/apt/lists/*

# rustup only; setup-rust.sh installs the exact pinned toolchain at build time.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain none --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"

COPY . $SRC/hellohq-sqlite-native
WORKDIR $SRC/hellohq-sqlite-native
COPY .clusterfuzzlite/build.sh $SRC/build.sh
