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
#   GHSA-c827-hfw6-qwvm (6.5)           rustix <0.38.19 Errno::from_io_error
#                                                       mis-derives an errno from
#                                                       a synthetic io::Error
#
# rustix was found ONLY in bundle_static — i.e. only in the crate that ships —
# and only after osv-scanner stopped skipping .src/ via .gitignore. It is the
# concrete example of why that blind spot mattered: cargo-audit/cargo-deny were
# pointed at `bundle`, which does not carry it.
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
RS="${ROOT}/.src/cr-sqlite/core/rs"

# WHICH CRATES TO PATCH — get this list wrong and the patch is cosmetic.
#
# `bundle_static` is what ACTUALLY SHIPS. cr-sqlite's core/Makefile defaults to
# `bundle=bundle_static` (line ~72), and every platform script here runs
# `make loadable`, whose rule is `cd ./rs/$(bundle) && cargo build --release
# --features loadable_extension`. So linux/macOS/iOS/Android/Windows all compile
# rs/bundle_static — each of these crate dirs carries its OWN Cargo.lock, so the
# lock next to the crate being built is the one that governs.
#
# This script previously patched ONLY `bundle`, which the Makefile never selects
# (its overrides go to `integration_check`, never to `bundle`). The result: the
# shipped extension carried bytes 1.5.0 / shlex 1.2.0 while cargo-audit and
# cargo-deny — also pointed at `bundle` — reported clean. osv-scanner would have
# caught it, but it was skipping the whole tree via .gitignore until --no-ignore
# was added. Keep `bundle` in the list too: it costs nothing and keeps the
# scanners that still reference it honest.
CRATES="bundle_static bundle"

if ! command -v cargo >/dev/null 2>&1; then
  echo "⚠️  patch-cr-sqlite-deps: cargo not found — skipping (no Rust build here)" >&2
  exit 0
fi

echo "▸ patch-cr-sqlite-deps: clearing RUSTSEC-2026-0007 (bytes), RUSTSEC-2024-0006 (shlex), GHSA-c827-hfw6-qwvm (rustix)"

# The bundle pins nightly-2023-10-05 via rust-toolchain.toml; override to the
# runner's default toolchain so a lockfile-only update never has to install it.
export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}"

patched=0
for crate in ${CRATES}; do
  manifest="${RS}/${crate}/Cargo.toml"
  lock="${RS}/${crate}/Cargo.lock"

  if [ ! -f "${manifest}" ]; then
    # bundle_static missing would mean the shipped crate vanished upstream —
    # that must fail loudly, not silently ship an unpatched lock.
    if [ "${crate}" = "bundle_static" ]; then
      echo "❌ patch-cr-sqlite-deps: ${manifest} missing — run build/fetch.sh first" >&2
      exit 1
    fi
    echo "  – ${crate}: absent, skipping"
    continue
  fi

  # The runner's stable cargo may rewrite the lock to format v4; the cargo-deny
  # action's older bundled cargo only parses v3 (cargo-audit tolerates v4).
  # Capture upstream's lockfile format version and restore it after the bump —
  # the dep changes are version-agnostic, so re-tagging the format is safe
  # (verified with a `--locked` parse on the old toolchain).
  orig_ver="$(sed -n 's/^version = \([0-9][0-9]*\)$/\1/p' "${lock}" | head -1)"

  # Bump only what this lock actually contains. The crates differ: rustix is in
  # bundle_static and NOT in bundle, and `cargo update -p <absent>` errors out —
  # under `set -e` that would abort the whole patch and silently leave the
  # shipped lock unpatched. Grep the lock first, and report anything skipped so
  # a package quietly disappearing upstream is visible rather than assumed.
  bumped=""
  for pin in bytes:1.11.1 shlex:1.3.0 rustix:0.38.19; do
    pkg="${pin%%:*}"; want="${pin##*:}"
    if grep -q "^name = \"${pkg}\"$" "${lock}"; then
      cargo update --manifest-path "${manifest}" -p "${pkg}" --precise "${want}"
      bumped="${bumped} ${pkg}→${want}"
    else
      echo "  – ${crate}: ${pkg} not in this lock, nothing to bump"
    fi
  done

  new_ver="$(sed -n 's/^version = \([0-9][0-9]*\)$/\1/p' "${lock}" | head -1)"
  if [ -n "${orig_ver}" ] && [ -n "${new_ver}" ] && [ "${new_ver}" != "${orig_ver}" ]; then
    echo "  ↩ ${crate}: restoring Cargo.lock format version ${new_ver} → ${orig_ver}"
    sed -i.bak "s/^version = ${new_ver}$/version = ${orig_ver}/" "${lock}" && rm -f "${lock}.bak"
  fi
  echo "  ✅ ${crate}:${bumped:- nothing to bump}"
  patched=$((patched + 1))
done

if [ "${patched}" -eq 0 ]; then
  echo "❌ patch-cr-sqlite-deps: patched nothing — the crate layout moved" >&2
  exit 1
fi
