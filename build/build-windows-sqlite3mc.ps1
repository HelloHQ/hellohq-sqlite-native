# build-windows-sqlite3mc.ps1 — build SQLite3 Multiple Ciphers for Windows x64:
#   dist/windows-x64/sqlite3mc.dll   (the sqlite3 library, MC ciphers built in)
#   dist/windows-x64/sqlite3mc.lib   (import lib, for the contract test link)
#   dist/windows-x64/sqlite3mc.h     (public headers, for the contract test)
#   dist/windows-x64/sqlite3mc-sqlite3.h
#
# This is a SEPARATE library from libsqlcipher.dll (build-windows.ps1). We ship
# both: SQLCipher for consumers on the SQLCipher-proper API, sqlite3mc for the
# Flutter app, whose `package:sqlite3` hook is configured `source: sqlite3mc`
# and whose hellohq_db issues `PRAGMA cipher = 'sqlcipher'` + `PRAGMA legacy = 4`
# — sqlite3mc-only pragmas that real SQLCipher rejects. See HelloHQ/hellohq#1074.
#
# Crypto provider: NONE external. sqlite3mc carries its own AES/SHA/PBKDF2
# implementations, so unlike libsqlcipher.dll this DLL needs no libcrypto
# alongside it — it is self-contained and drops in beside flutter_tester.
#
# Toolchain: MSVC (from a VS x64 Developer prompt) + CMake. No Rust, no OpenSSL.
#
#   Usage (from a VS x64 Developer PowerShell):
#     SQLITE3MC=1 bash build/fetch.sh ; pwsh build/build-windows-sqlite3mc.ps1
$ErrorActionPreference = 'Stop'

$Root  = Split-Path -Parent $PSScriptRoot
$Src   = Join-Path $Root '.src/sqlite3mc'
$Bld   = Join-Path $Root '.build/sqlite3mc-windows-x64'
$Out   = Join-Path $Root 'dist/windows-x64'

if (-not (Test-Path $Src)) {
  throw "sqlite3mc source missing at $Src — run: SQLITE3MC=1 bash build/fetch.sh"
}
New-Item -ItemType Directory -Force -Path $Out | Out-Null

# ── 1. Configure ─────────────────────────────────────────────────────────────
# SHELL=OFF: we ship a library, not the sqlite3mc CLI.
# STATIC=OFF: SQLITE3MC_TARGET becomes `sqlite3mc` (shared) → sqlite3mc.dll,
# which is exactly the filename package:sqlite3's hook resolves for
# `name_windows: sqlite3mc`. Do not rename the output.
Write-Host '▸ configuring sqlite3mc (MSVC, x64, Release)'
cmake -S $Src -B $Bld -A x64 `
  -DCMAKE_BUILD_TYPE=Release `
  -DSQLITE3MC_STATIC=OFF `
  -DSQLITE3MC_BUILD_SHELL=OFF
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed ($LASTEXITCODE)" }

# ── 2. Build ─────────────────────────────────────────────────────────────────
Write-Host '▸ building sqlite3mc'
cmake --build $Bld --config Release --target sqlite3mc
if ($LASTEXITCODE -ne 0) { throw "cmake build failed ($LASTEXITCODE)" }

# ── 3. Collect ───────────────────────────────────────────────────────────────
# The VS generator emits into <build>/Release/. Search rather than hard-code the
# path so a generator change doesn't silently produce an empty artifact.
$dll = Get-ChildItem -Path $Bld -Recurse -Filter 'sqlite3mc.dll' | Select-Object -First 1
if (-not $dll) { throw "sqlite3mc.dll not produced under $Bld" }
Copy-Item $dll.FullName (Join-Path $Out 'sqlite3mc.dll') -Force

$lib = Get-ChildItem -Path $Bld -Recurse -Filter 'sqlite3mc.lib' | Select-Object -First 1
if ($lib) { Copy-Item $lib.FullName (Join-Path $Out 'sqlite3mc.lib') -Force }

# Headers for the contract test. sqlite3mc's own sqlite3.h has the same name as
# the one SQLCipher ships into this same dist dir, so keep it in a subdirectory
# — the contract test then compiles unchanged against either library by picking
# the include dir (/I), not by editing its #include.
$Inc = Join-Path $Out 'sqlite3mc-include'
New-Item -ItemType Directory -Force -Path $Inc | Out-Null
foreach ($h in @('sqlite3.h', 'sqlite3ext.h', 'sqlite3mc.h', 'sqlite3mc_version.h')) {
  Copy-Item (Join-Path $Src "src/$h") (Join-Path $Inc $h) -Force
}

# ── 4. Verify exports ────────────────────────────────────────────────────────
# cr-sqlite is registered per-connection via sqlite3_load_extension AFTER the
# key pragma. If the DLL's export table lacks those symbols the Flutter app
# cannot load cr-sqlite at all — this is precisely the failure the Linux leg
# hit with the upstream prebuilt, so gate on it here rather than at runtime.
Write-Host '▸ verifying export table'
$exports = & dumpbin /exports (Join-Path $Out 'sqlite3mc.dll') 2>$null
if ($LASTEXITCODE -ne 0) { throw "dumpbin failed — is this a VS Developer prompt?" }
$missing = @()
foreach ($sym in @('sqlite3_open', 'sqlite3_key', 'sqlite3_rekey',
                   'sqlite3_enable_load_extension', 'sqlite3_load_extension')) {
  # $exports is an ARRAY of lines, and -match/-notmatch on an array FILTER it
  # rather than returning a bool — `if ($exports -notmatch $sym)` would be truthy
  # for every symbol. Test emptiness of the matching set instead.
  # \b keeps sqlite3_open from being satisfied by sqlite3_open_v2 ('_' is a word
  # character, so there is no boundary between "open" and "_v2").
  if (-not ($exports -match "\b$sym\b")) { $missing += $sym }
}
if ($missing.Count -gt 0) {
  throw "sqlite3mc.dll is missing required exports: $($missing -join ', ')"
}

Write-Host "✅ sqlite3mc Windows x64 artifacts in $Out"
Get-ChildItem $Out -Filter 'sqlite3mc*' | Format-Table Name, Length
