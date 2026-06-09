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

Bumping = edit `upstream.lock`; the build + security scan + contract gate runs on
the PR. Crypto/DB bumps require human approval — never auto-merged.

## Build (host, macOS arm64 — verified)

```sh
bash build/fetch.sh        # fetch + verify pinned upstream into .src/
bash build/build-macos.sh  # -> dist/macos/{libsqlcipher,crsqlite}.dylib + contract test
```

SQLCipher v4.16.0 uses the autosetup `configure`; required flags:
`--with-tempstore=yes`, `-DSQLITE_HAS_CODEC`,
`-DSQLITE_EXTRA_INIT=sqlcipher_extra_init`,
`-DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown`, plus a crypto provider.
cr-sqlite requires a **nightly Rust** toolchain.

## Testing

We do not test upstream's source (it has its own suites); we test that **our
build produces a correct artifact**. A per-platform **contract test**
(`test/contract.c`) asserts the capability checklist against the freshly built
libraries: cipher active, key round-trip, **wrong key rejected**, rekey,
cr-sqlite loads, CRR changeset round-trip, version parity. "Coverage" here is
**capability × platform completeness** (the matrix must be all-green), not a
source line-coverage percentage. See `ROADMAP.md`.

## Security

Treat published artifacts as build outputs to be **verified, not trusted**:
pin the SHA-256 and verify the SLSA provenance before consuming. Scan stack:
CodeQL (C/Rust), cargo-deny + cargo-audit (cr-sqlite Rust + license gate),
OSV-Scanner, Trivy, StepSecurity Harden-Runner, OSSF Scorecard; Actions pinned
to commit SHAs.
