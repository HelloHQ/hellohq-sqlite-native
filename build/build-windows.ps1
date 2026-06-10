# build-windows.ps1 — build the HelloHQ native DB layer for Windows x64:
#   dist/windows-x64/libsqlcipher.dll   (SQLCipher = the sqlite3 library)
#   dist/windows-x64/crsqlite.dll       (cr-sqlite loadable extension)
#
# Crypto provider: **OpenSSL** (via vcpkg). Windows SQLCipher Community has no
# CommonCrypto; OpenSSL is the supported provider. (CNG is the self-contained
# alternative but is not a stock SQLCipher Community provider — see ROADMAP
# "crypto provider TBD".) The DLL therefore needs libcrypto alongside it; the
# release archive bundles the OpenSSL DLLs next to libsqlcipher.dll.
#
# Toolchain: MSVC (cl/nmake from a Developer prompt), tclsh, vcpkg (openssl),
# nightly Rust for cr-sqlite.
#
# ⚠️ FIRST-DRAFT — Windows MSVC SQLCipher is the least-validated leg. The nmake
#    variable names / OpenSSL wiring below will need CI iteration. Authored from
#    SQLCipher's Makefile.msc conventions; not yet run green.
#
#   Usage (from a VS x64 Developer PowerShell):
#     pwsh build/fetch.sh-equivalent ; pwsh build/build-windows.ps1
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$Src  = Join-Path $Root '.src'
$Out  = Join-Path $Root 'dist/windows-x64'
New-Item -ItemType Directory -Force -Path $Out | Out-Null

# OpenSSL from vcpkg (CI: vcpkg install openssl:x64-windows). Override with env.
$OpenSslRoot = if ($env:OPENSSL_ROOT) { $env:OPENSSL_ROOT }
               else { 'C:/vcpkg/installed/x64-windows' }
$OsslInc = Join-Path $OpenSslRoot 'include'
$OsslLib = Join-Path $OpenSslRoot 'lib'
if (-not (Test-Path $OsslInc)) { throw "OpenSSL not found at $OpenSslRoot (set OPENSSL_ROOT)" }

# ── 1. SQLCipher → libsqlcipher.dll (MSVC nmake + OpenSSL codec) ─────────────
Write-Host '▸ building SQLCipher (MSVC, OpenSSL codec)'
Push-Location (Join-Path $Src 'sqlcipher')
try {
  $opts = @(
    '-DSQLITE_HAS_CODEC',
    '-DSQLCIPHER_CRYPTO_OPENSSL',
    '-DSQLITE_TEMP_STORE=2',
    '-DSQLITE_EXTRA_INIT=sqlcipher_extra_init',
    '-DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown',
    "-I`"$OsslInc`""
  ) -join ' '
  # Build the `dll` phony target (Makefile.msc:1819 → $(SQLITE3DLL)); SQLITE3DLL
  # renames the output. Name it sqlcipher.dll to match the resolver + sqlite3
  # build-hook (`name: sqlcipher` → sqlcipher.dll on Windows). LTLIBPATHS/LTLIBS
  # carry OpenSSL's libcrypto to the linker.
  nmake /f Makefile.msc clean
  nmake /f Makefile.msc dll `
    "OPTS=$opts" `
    "SQLITE3DLL=sqlcipher.dll" `
    "LTLIBPATHS=/LIBPATH:`"$OsslLib`"" `
    "LTLIBS=libcrypto.lib"
  Copy-Item 'sqlcipher.dll' (Join-Path $Out 'sqlcipher.dll') -Force
  if (Test-Path 'sqlcipher.lib') { Copy-Item 'sqlcipher.lib' (Join-Path $Out 'sqlcipher.lib') -Force }
} finally { Pop-Location }

# Bundle the OpenSSL runtime DLL next to ours (consumers load it from the dir).
Get-ChildItem -Path (Join-Path $OpenSslRoot 'bin') -Filter 'libcrypto*.dll' -ErrorAction SilentlyContinue |
  ForEach-Object { Copy-Item $_.FullName $Out -Force }

# cr-sqlite (crsqlite.dll) is built separately by build/build-windows-crsqlite.sh
# on a Linux runner via mingw cross — cr-sqlite's own recipe, since native
# Windows cr-sqlite is unsupported upstream. The `windows` job combines the two
# and runs the contract test.
Write-Host "✅ SQLCipher Windows x64 artifacts in $Out"
Get-ChildItem $Out | Format-Table Name, Length
