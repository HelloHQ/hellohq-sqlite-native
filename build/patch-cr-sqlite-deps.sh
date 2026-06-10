#!/usr/bin/env bash
# patch-cr-sqlite-deps.sh — clear known RUSTSEC advisories in cr-sqlite's pinned
# Rust dependency tree, AFTER fetch and BEFORE scan/build.
#
# cr-sqlite's upstream Cargo.lock carries crates with published advisories. We
# bump them to the patched, semver-compatible versions so BOTH the security scan
# (cargo-audit / cargo-deny) AND the shipped crsqlite artifact are clean:
#
#   RUSTSEC-2026-0007 / CVE-2026-25541  bytes  <1.11.1  integer overflow in
#                                                       BytesMut::reserve → OOB /
#                                                       memory corruption
#   RUSTSEC-2024-0006 / CVE-2024-58266  shlex  <1.3.0   quote/join under-escape →
#                                                       potential cmd injection
#
# Lockfile-only edits (no compile), so we force the default toolchain — the
# bundle pins an old nightly that the scan jobs don't install, and a `.lock`
# rewrite is toolchain-independent. Idempotent: re-running is a no-op.
#
# Invoked from build/fetch.sh. Self-skips (with a warning) when cargo is absent
# — the only such job is the SQLCipher-only build, which never compiles
# cr-sqlite, so the patch is irrelevant there. cargo-audit/cargo-deny remain the
# backstop that fails CI if any crsqlite-building job somehow shipped an
# unpatched lock.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_DIR="${ROOT}/.src/cr-sqlite/core/rs/bundle"
BUNDLE="${BUNDLE_DIR}/Cargo.toml"
LOCK="${BUNDLE_DIR}/Cargo.lock"

if ! command -v cargo >/dev/null 2>&1; then
  echo "⚠️  patch-cr-sqlite-deps: cargo not found — skipping (no Rust build here)" >&2
  exit 0
fi
if [ ! -f "${BUNDLE}" ]; then
  echo "❌ patch-cr-sqlite-deps: ${BUNDLE} missing — run build/fetch.sh first" >&2
  exit 1
fi

# The bundle pins nightly-2023-10-05 via rust-toolchain.toml; override to the
# runner's default toolchain so a lockfile-only update never has to install it.
export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}"

echo "▸ patch-cr-sqlite-deps: clearing RUSTSEC-2026-0007 (bytes), RUSTSEC-2024-0006 (shlex)"

# The runner's stable cargo may rewrite the lock to format v4; the cargo-deny
# action's older bundled cargo only parses v3 (cargo-audit tolerates v4). Capture
# upstream's lockfile format version and restore it after the bump — the dep
# changes are version-agnostic, so re-tagging the format is safe (verified with a
# `--locked` parse on the old toolchain).
orig_ver="$(sed -n 's/^version = \([0-9][0-9]*\)$/\1/p' "${LOCK}" | head -1)"

cargo update --manifest-path "${BUNDLE}" -p bytes --precise 1.11.1
cargo update --manifest-path "${BUNDLE}" -p shlex --precise 1.3.0

new_ver="$(sed -n 's/^version = \([0-9][0-9]*\)$/\1/p' "${LOCK}" | head -1)"
if [ -n "${orig_ver}" ] && [ -n "${new_ver}" ] && [ "${new_ver}" != "${orig_ver}" ]; then
  echo "  ↩ restoring Cargo.lock format version ${new_ver} → ${orig_ver}"
  sed -i.bak "s/^version = ${new_ver}$/version = ${orig_ver}/" "${LOCK}" && rm -f "${LOCK}.bak"
fi
echo "  ✅ bytes→1.11.1, shlex→1.3.0"
