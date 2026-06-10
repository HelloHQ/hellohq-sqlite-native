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
  local name="$1" url="$2" ref="$3" pinned="$4"  # ref is unused (we pin by SHA)
  local dir="${SRC}/${name}"
  echo "▸ ${name}: ${url} @ ${pinned:0:12}"
  rm -rf "${dir}"
  # Fetch exactly the pinned commit (GitHub allows fetching an arbitrary SHA),
  # then check it out. No fallbacks that could leave us on the wrong commit.
  git init -q "${dir}"
  git -C "${dir}" remote add origin "${url}"
  git -C "${dir}" fetch -q --depth 1 origin "${pinned}"
  git -C "${dir}" checkout -q FETCH_HEAD
  local got; got="$(git -C "${dir}" rev-parse HEAD)"
  if [ "${got}" != "${pinned}" ]; then
    echo "❌ ${name}: commit mismatch — got ${got}, pinned ${pinned}" >&2
    exit 1
  fi
  # Submodules (cr-sqlite → sqlite-rs-embedded → sqlite_nostd). NOT masked: an
  # empty submodule tree must fail the fetch, not silently break the build later.
  # cr-sqlite's .gitmodules use SSH URLs (git@github.com:…) which fail on CI
  # (token/HTTPS only); rewrite to HTTPS. `-c` propagates to every nested clone
  # via GIT_CONFIG_PARAMETERS. Full (non-shallow) so a pinned non-tip commit
  # always resolves.
  git -C "${dir}" \
    -c url."https://github.com/".insteadOf="git@github.com:" \
    -c url."https://github.com/".insteadOf="ssh://git@github.com/" \
    submodule update --init --recursive
  echo "  ✅ verified ${got}"
}

mkdir -p "${SRC}"
clone_verify sqlcipher "$(val sqlcipher source)" "$(val sqlcipher tag)"  "$(val sqlcipher commit)"
clone_verify cr-sqlite "$(val crsqlite source)"  ""                      "$(val crsqlite commit)"

# Clear known RUSTSEC advisories in cr-sqlite's pinned Rust deps (lockfile bump)
# so the security scan AND the shipped artifact are clean. Self-skips with no
# cargo (the SQLCipher-only build, which never compiles cr-sqlite).
bash "${SCRIPT_DIR}/patch-cr-sqlite-deps.sh"

echo "✅ upstream sources fetched + verified into ${SRC}"
