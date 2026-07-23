# Security Policy

## Scope

`hellohq-sqlite-native` produces reproducible, scanned builds of **SQLCipher**
and **cr-sqlite**. It contains **no upstream source** — only pinned versions
(`upstream.lock`), build scripts, optional `*.patch` files, and CI.

That split determines where a report should go:

| Where the flaw is | Report to |
|---|---|
| Build scripts, CI, release/packaging, the pinning + verification gate | **Here** (see below) |
| A pin that is stale, wrong, or unverified — e.g. we ship a known-vulnerable SQLCipher | **Here** |
| SQLCipher / SQLite itself | [sqlcipher/sqlcipher](https://github.com/sqlcipher/sqlcipher) — then open an issue here so we bump the pin |
| cr-sqlite | [vlcn-io/cr-sqlite](https://github.com/vlcn-io/cr-sqlite) (we build the [superfly](https://github.com/superfly/cr-sqlite) fork) — then tell us to bump |

A vulnerability in upstream that we merely *ship* is still worth telling us
about: the fix on our side is an `upstream.lock` bump, and we would rather hear
it early than at the next scheduled scan.

## Reporting a Vulnerability

**Do not open a public issue for an undisclosed vulnerability.**

Use GitHub's [private vulnerability
reporting](https://github.com/HelloHQ/hellohq-sqlite-native/security/advisories/new)
("Report a vulnerability" on the Security tab). It is private to maintainers and
gives us a coordinated-disclosure workflow.

Please include: affected version/tag or commit, platform, what an attacker
gains, and a reproduction if you have one.

**What to expect:** acknowledgement within 5 working days, an assessment with a
plan or a reasoned rejection within 10. If a fix ships, we will credit you
unless you ask us not to.

Please give us a reasonable window to release before public disclosure. We will
tell you when a fix is out, and we are happy to coordinate timing.

## Supported Versions

Only the **latest release** receives security fixes. Older tags are immutable
build records, not maintained branches — consumers pin by tag *and* verify the
SHA-256 published with each release, so upgrading is the supported remedy.

## How this repo defends itself

The threat this project actually has to answer is **supply chain**: it fetches
third-party crypto and database source and turns it into binaries other people
load.

- **Pinned + verified upstream.** `upstream.lock` pins each source to an
  immutable commit SHA, verified in CI before use. A moved tag does not silently
  change what we build.
- **Crypto/DB bumps need human approval** — never auto-merged.
- **Scanning on every PR and on a schedule** (`.github/workflows/security.yml`):
  `osv-scanner` over the fetched tree, `trivy` (vuln + secret + misconfig),
  `cargo-audit`, `cargo-deny` (advisories + license policy), and CodeQL.
- **CodeQL is scoped to code this repo owns** (`.github/codeql/codeql-config.yml`).
  Upstream in `.src/` is excluded there **because it is covered by the scanners
  built for third-party code** (above) — a static-analysis finding in a vendored
  SQLite amalgamation is not actionable here, whereas a CVE in it is, and that is
  what `osv-scanner`/`trivy` catch. This narrows noise, not coverage.
- **Actions are SHA-pinned** and runs use `step-security/harden-runner`.
- **Releases publish SHA-256 digests**; consumers verify before installing.

If you believe any of the above is weaker than it reads — especially the
verification gate in `build/fetch.sh` — that is exactly the kind of report we
want.
