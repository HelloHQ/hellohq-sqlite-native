#!/usr/bin/env bash
# setup-rust.sh — install the cr-sqlite-pinned nightly toolchain + rust-src,
# plus any extra targets passed as args.
#
# cr-sqlite builds with `-Zbuild-std`, which rebuilds std from source for the
# target — so the pinned channel MUST have the `rust-src` component. The channel
# is read from cr-sqlite's own rust-toolchain.toml so this never drifts from the
# pin. Run AFTER build/fetch.sh.
#
#   Usage:  bash build/setup-rust.sh [extra-rust-target ...]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tc_file="$(find "${ROOT}/.src/cr-sqlite" -name rust-toolchain.toml \
             -not -path '*/.git/*' | head -1 || true)"
channel="nightly"
if [ -n "${tc_file}" ]; then
  channel="$(grep -E '^[[:space:]]*channel' "${tc_file}" \
             | sed -E 's/.*"([^"]+)".*/\1/' | head -1)"
fi
echo "▸ rust toolchain: ${channel} (+rust-src)"
rustup toolchain install "${channel}" --component rust-src --profile minimal --no-self-update
for t in "$@"; do
  rustup target add --toolchain "${channel}" "${t}"
done
rustc "+${channel}" --version
