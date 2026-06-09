# hellohq-sqlite-native — Roadmap

Public build repo for an encrypted + CRDT SQLite native layer: **SQLCipher**
(encryption) + **cr-sqlite** (CRDT), for macOS · Linux · Windows · iOS · Android.
Consumers load `libsqlcipher` as their `sqlite3` and load `crsqlite` per
connection after `PRAGMA key` (see README).

## Validated (host, macOS arm64)
- SQLCipher v4.16.0 builds via autosetup `configure` (+ `SQLITE_EXTRA_INIT`),
  **CommonCrypto codec** — the shipped `libsqlcipher.dylib` links only system
  frameworks (Security, CoreFoundation, libz, libSystem); **no OpenSSL**, so it
  loads on any mac. (`-DSQLCIPHER_CRYPTO_CC`; verified with `otool -L`.)
- superfly cr-sqlite builds (`make loadable`); requires **nightly Rust**.
- Combined on an encrypted DB: cipher active, key round-trip, wrong-key rejected,
  rekey, cr-sqlite loads, CRR changeset round-trip (9/9 in `test/contract.c`).
- **Universal**: `libsqlcipher` cross-builds arm64+x86_64 and lipos clean; the
  cr-sqlite x86_64 slice needs a **native x86_64 runner** (its `build-std`
  toolchain can't cross-compile) — produced in CI on `macos-13`.

## Artifact contract (loadable path)
Per platform, two libraries:
- `libsqlcipher.<dylib|so|dll>` — the SQLCipher build of SQLite.
- `crsqlite.<dylib|so|dll>` — cr-sqlite loadable extension, loaded per-connection
  after the key via `sqlite3_load_extension`.

## Testing approach
This repo does **not** unit-test upstream source (SQLCipher and cr-sqlite carry
their own suites). It tests that **our build produces a correct artifact**:
- **`test/contract.c`** — a C harness compiled against the freshly built
  `libsqlcipher`, dynamically loading `crsqlite`, asserting the capability
  checklist: cipher active · key round-trip · **wrong key rejected** · rekey ·
  cr-sqlite loads · CRR changeset round-trip · version parity (loaded cr-sqlite
  == pinned).
- **Coverage = capability × platform completeness** — the checklist must pass on
  all 5 platforms in CI, with no silent skips. Source line-coverage is not a
  meaningful metric for code we don't author.
- **Optional deeper tier** (nightly): run upstream's own suites against our build
  — SQLCipher TCL tests + cr-sqlite `make test` — as a "didn't break upstream"
  gate.

## Milestone 1 — Formalize the host build  ◀ done
- [x] `upstream.lock` with commit-SHA verification (SQLCipher v4.16.0, superfly cr-sqlite)
- [x] `build/fetch.sh` — fetch + verify pinned upstream into `.src/`
- [x] `build/build-macos.sh` — per-arch recipe → `dist/macos-<arch>/{libsqlcipher,crsqlite}.dylib`
- [x] `test/contract.c` — capability checklist, run after the macOS build (9/9 green)
- [x] crypto provider: **CommonCrypto** — self-contained `libsqlcipher` (no OpenSSL)
- [x] universal via lipo: `build/lipo-macos.sh` fuses the per-arch dirs →
      `dist/macos/{libsqlcipher,crsqlite}.dylib`. `libsqlcipher` verified universal
      (`x86_64 arm64`) + contract green against the fused artifact. The cr-sqlite
      x86_64 slice is produced by CI's native `macos-13` leg (no local cross-build).

## Milestone 2 — All 5 platforms
- [ ] Linux x64 (+ arm64): OpenSSL, nightly Rust
- [ ] Windows x64: MSVC SQLCipher + cr-sqlite — **hardest; crypto provider TBD (OpenSSL vs CNG)**
- [ ] Android arm64-v8a / armeabi-v7a / x86_64 (NDK)
- [ ] iOS device arm64 + sim → xcframework (CommonCrypto)
- [ ] pin `rust-toolchain.toml` (nightly) for cr-sqlite everywhere

## Milestone 3 — CI + supply chain (public repo → free runners)
- [ ] `.github/workflows/build.yml` — 5-platform matrix → fetch+build → `test/contract.c` → artifacts
- [ ] Scans: CodeQL (C/Rust), cargo-deny + cargo-audit (+ license gate), OSV-Scanner, Trivy, Harden-Runner, OSSF Scorecard; pin Actions to SHA
- [ ] SLSA build provenance (attest-build-provenance) + sha256 checksums + SBOM (syft)
- [ ] assemble `THIRD_PARTY_LICENSES` at build

## Milestone 4 — Release + currency
- [ ] tagged Releases: per-platform archives (`libsqlcipher.*` + `crsqlite.*` + checksums + attestation + licenses)
- [ ] upstream-tracking cron: weekly check → PR bumping `upstream.lock` → build+scan+contract gate → **human approval** (crypto/DB bumps never auto-merge)

## Open decisions
1. Windows SQLCipher crypto provider: bundle OpenSSL vs system CNG.
2. Linux/Android ABIs to ship (x64-only first, or arm64 too).
3. Apple crypto: migrate to CommonCrypto (no bundled OpenSSL) — validate.
