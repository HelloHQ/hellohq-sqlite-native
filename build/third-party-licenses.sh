#!/usr/bin/env bash
# third-party-licenses.sh — assemble THIRD_PARTY_LICENSES from the fetched
# upstream sources. Bundled components keep their own licenses (all permissive,
# no copyleft); this collects them for the release archives. Run after fetch.sh.
#
#   Output: THIRD_PARTY_LICENSES/THIRD_PARTY_LICENSES.txt
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/.src"
OUT="${ROOT}/THIRD_PARTY_LICENSES"
mkdir -p "${OUT}"
F="${OUT}/THIRD_PARTY_LICENSES.txt"

emit_license() { # <title> <glob...>
  local title="$1"; shift
  echo "================ ${title} ================"
  local found=""
  for g in "$@"; do
    for f in ${g}; do
      [ -f "${f}" ] && { cat "${f}"; found=1; echo; }
    done
  done
  [ -n "${found}" ] || echo "(license file not found in source; see project homepage)"
  echo
}

{
  echo "HelloHQ native DB layer — third-party licenses"
  echo "Assembled from pinned upstream (see upstream.lock). This repo's own code"
  echo "is Apache-2.0; the components below keep their own licenses."
  echo

  echo "================ SQLite (public domain) ================"
  echo "SQLite is in the public domain — https://www.sqlite.org/copyright.html"
  echo

  emit_license "SQLCipher (BSD-3-Clause)" \
    "${SRC}/sqlcipher/LICENSE" "${SRC}/sqlcipher/LICENSE.md" "${SRC}/sqlcipher/LICENSE.txt"

  emit_license "cr-sqlite (MIT / Apache-2.0)" \
    "${SRC}/cr-sqlite/LICENSE" "${SRC}/cr-sqlite/LICENSE.md" "${SRC}/cr-sqlite/LICENSE-*"

  # Shipped on Windows only (sqlite3mc.dll). Requires SQLITE3MC=1 on the
  # fetch.sh that precedes this script, or the source tree is absent and this
  # section degrades to the "not found" note.
  emit_license "SQLite3 Multiple Ciphers (MIT)" \
    "${SRC}/sqlite3mc/LICENSE" "${SRC}/sqlite3mc/LICENSE.md" "${SRC}/sqlite3mc/LICENSE.txt"

  echo "================ OpenSSL 3.x (Apache-2.0) ================"
  echo "Linked on Linux / Windows / Android only (statically where possible)."
  echo "Apple platforms use system CommonCrypto and bundle NO OpenSSL."
  echo "https://www.openssl.org/source/license.html"
  echo
} > "${F}"

echo "✅ wrote ${F}"
