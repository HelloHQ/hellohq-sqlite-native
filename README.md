# hellohq-sqlite-native

Reproducible, security-scanned, multi-platform builds of an encrypted + CRDT
SQLite native layer: **SQLCipher** (transparent encryption) + **cr-sqlite** (CRDT
changesets), for **macOS, Linux, Windows, iOS, Android**.

This repo contains **no upstream source** — only pinned versions
(`upstream.lock`), build scripts, optional `*.patch` files, and CI. Upstream is
fetched and verified (by commit SHA) at build time. Builds run on free GitHub
Actions runners.

> License: Apache-2.0 (this repo's own code). Bundled components keep their own
> licenses — see `THIRD_PARTY_LICENSES` in each release artifact.

## What it produces

Per platform, **two libraries**:

- `libsqlcipher.<dylib|so|dll>` — a SQLCipher build of SQLite (the encryption is
  applied via `PRAGMA key`; `PRAGMA cipher_version` confirms the codec).
- `crsqlite.<dylib|so|dll>` — the cr-sqlite loadable extension (`crsql_*`
  functions, CRDT changesets).

Plus, **on Windows only**, a third library:

- `sqlite3mc.dll` — a [SQLite3 Multiple Ciphers][mc] build of SQLite. This is a
  *different project* from SQLCipher, not a variant of it. It implements a
  SQLCipher-**compatible** cipher that is selected with `PRAGMA cipher =
  'sqlcipher'` + `PRAGMA legacy = 4` **before** `PRAGMA key`. Real SQLCipher
  does not understand those pragmas, and sqlite3mc leaves `PRAGMA
  cipher_version` empty — so the two are **not** drop-in replacements for each
  other. It carries its own crypto, so unlike `libsqlcipher.dll` it needs no
  `libcrypto-*.dll` beside it.

  It exists because the Flutter app's `package:sqlite3` build hook is configured
  `source: sqlite3mc`. Shipping it here lets the app provision it through the
  same SHA-256 + SLSA trust gate as everything else, instead of downloading it
  from a third-party GitHub release while tests are starting.

[mc]: https://github.com/utelle/SQLite3MultipleCiphers

Artifacts are published via GitHub Releases with **SLSA build provenance**
(`actions/attest-build-provenance`) and SHA-256 checksums.

## Using the artifacts

Load the SQLCipher library as your `sqlite3`, then load cr-sqlite **per
connection, after setting the key** (SQLCipher requires the key before any other
DB access; cr-sqlite's init touches the database, so it must run post-key):

1. open the database and run `PRAGMA key = '…'`
2. `sqlite3_enable_load_extension(handle, 1)`
3. `sqlite3_load_extension(handle, "<crsqlite>", "sqlite3_crsqlite_init", NULL)`

`crsqlite` is loaded as a normal loadable extension (function-pointer ABI), so it
is robust across SQLite/SQLCipher versions. Verify a downloaded artifact's
SHA-256 and build attestation before use.

## Upstream pins (`upstream.lock`)

| Component | Source | Pin |
|---|---|---|
| SQLCipher | github.com/sqlcipher/sqlcipher | `v4.16.0` (commit-verified) |
| cr-sqlite | github.com/superfly/cr-sqlite | commit-pinned (fork has no release tags) |
| SQLite3 Multiple Ciphers | github.com/utelle/SQLite3MultipleCiphers | `v2.3.4` (commit-verified, Windows only) |

The sqlite3mc pin must stay in **lockstep** with the amalgamation vendored in the
HelloHQ `sqlite3.dart` fork, which is what the app's Linux builds compile from.
A version skew there would key and format databases differently per platform.
`fetch.sh` only clones it when `SQLITE3MC=1` — no other platform needs it.

Bumping = edit `upstream.lock`; the build + security scan + contract gate runs on
the PR. Crypto/DB bumps require human approval — never auto-merged.

## Build (macOS — verified)

```sh
bash build/fetch.sh                  # fetch + verify pinned upstream into .src/
bash build/build-macos.sh            # host arch -> dist/macos-<arch>/ + contract test
ARCH=x86_64 bash build/build-macos.sh # other slice (native runner; see note)
bash build/lipo-macos.sh             # fuse -> dist/macos/{libsqlcipher,crsqlite}.dylib
```

SQLCipher v4.16.0 uses the autosetup `configure`; required flags:
`--with-tempstore=yes`, `-DSQLITE_HAS_CODEC`,
`-DSQLITE_EXTRA_INIT=sqlcipher_extra_init`,
`-DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown`, plus a crypto provider.

**Crypto provider: CommonCrypto** (`-DSQLCIPHER_CRYPTO_CC` + `-framework
Security`). The result links only system frameworks — `otool -L` shows no
OpenSSL — so the artifact is self-contained and loads on any mac. Builds use
Apple clang via `xcrun` (the PATH `clang` may be Homebrew LLVM, which can't link
the macOS SDK for a non-host arch). cr-sqlite requires a **nightly Rust**
toolchain.

**Universal:** each arch is built natively on its own runner (arm64 on
`macos-14`, x86_64 on `macos-13`) and fused by `build/lipo-macos.sh`. A single
arm64 host can cross-build `libsqlcipher` for x86_64, but **cr-sqlite cannot
cross-compile** (its `build-std` toolchain needs the target's std), so a true
universal `crsqlite.dylib` is produced in CI, not locally.

## Testing

We do not test upstream's source (it has its own suites); we test that **our
build produces a correct artifact**. A per-platform **contract test**
(`test/contract.c`) asserts the capability checklist against the freshly built
libraries: cipher active, key round-trip, **wrong key rejected**, rekey,
cr-sqlite loads, CRR changeset round-trip, version parity. "Coverage" here is
**capability × platform completeness** (the matrix must be all-green), not a
source line-coverage percentage. See `ROADMAP.md`.

On Windows the same checklist runs a second time against `sqlite3mc.dll`:

```sh
contract --sqlite3mc <crsqlite.dll> <db-path>
```

`--sqlite3mc` switches the unlock handshake to `PRAGMA cipher = 'sqlcipher'` +
`PRAGMA legacy = 4` before `PRAGMA key`, and asserts `PRAGMA cipher` really
reports `sqlcipher` — a sqlite3mc that quietly fell back to its own default
cipher would still encrypt, but would write databases the rest of the fleet
cannot open. One checklist for both libraries is what keeps them from drifting.

## Security

Treat published artifacts as build outputs to be **verified, not trusted**:
pin the SHA-256 and verify the SLSA provenance before consuming. Scan stack:
CodeQL (C/Rust), cargo-deny + cargo-audit (cr-sqlite Rust + license gate),
OSV-Scanner, Trivy, StepSecurity Harden-Runner, OSSF Scorecard; Actions pinned
to commit SHAs.
