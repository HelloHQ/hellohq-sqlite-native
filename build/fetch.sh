#!/usr/bin/env bash
# fetch.sh — fetch pinned upstream sources into .src/ and VERIFY commit SHAs.
#
# No upstream source is committed to this repo; this script materializes it at
# build time from upstream.lock. Both SQLCipher and cr-sqlite are git-only, so
# verification = the resolved commit must equal the pinned immutable SHA.
#
# Usage: bash build/fetch.sh   (sets up .src/sqlcipher and .src/cr-sqlite)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCK="${ROOT}/upstream.lock"
SRC="${ROOT}/.src"

# ── Parse the (simple, fixed-shape) upstream.lock without a YAML dependency ──
val() { # val <top-section> <key>
  python3 - "$LOCK" "$1" "$2" <<'PY'
import sys
lock, section, key = sys.argv[1], sys.argv[2], sys.argv[3]
cur = None
for raw in open(lock):
    line = raw.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    if not line.startswith((" ", "\t")) and line.rstrip().endswith(":"):
        cur = line.strip()[:-1]
        continue
    if cur == section and ":" in line:
        k, _, v = line.strip().partition(":")
        if k.strip() == key:
            print(v.strip())
            break
PY
}

clone_verify() { # clone_verify <name> <url> <ref> <pinned_sha>
  local name="$1" url="$2" ref="$3" pinned="$4"
  local dir="${SRC}/${name}"
  echo "▸ ${name}: ${url} @ ${ref} (pin ${pinned:0:12})"
  rm -rf "${dir}"
  git clone --depth 1 ${ref:+--branch "${ref}"} "${url}" "${dir}" >/dev/null 2>&1 || \
    git clone "${url}" "${dir}" >/dev/null 2>&1
  git -C "${dir}" fetch --depth 1 origin "${pinned}" >/dev/null 2>&1 || true
  git -C "${dir}" checkout -q "${pinned}" 2>/dev/null || true
  local got; got="$(git -C "${dir}" rev-parse HEAD)"
  if [ "${got}" != "${pinned}" ]; then
    echo "❌ ${name}: commit mismatch — got ${got}, pinned ${pinned}" >&2
    exit 1
  fi
  git -C "${dir}" submodule update --init --recursive >/dev/null 2>&1 || true
  echo "  ✅ verified ${got}"
}

mkdir -p "${SRC}"
clone_verify sqlcipher "$(val sqlcipher source)" "$(val sqlcipher tag)"  "$(val sqlcipher commit)"
clone_verify cr-sqlite "$(val crsqlite source)"  ""                      "$(val crsqlite commit)"
echo "✅ upstream sources fetched + verified into ${SRC}"
