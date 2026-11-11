#!/usr/bin/env python3
"""tree-sha256.py: a SHA-256 over the content of a fetched git tree.

Git names commits, trees and blobs by SHA-1, so a commit pin alone rests on
SHA-1. This hashes the BYTES of every file in HEAD's tree with SHA-256, so a
source whose content differs from what was pinned fails even if its SHA-1 ids
match (HelloHQ/hellohq-sqlite-native#20).

Content is read from git's object store (`git cat-file`), not from the working
tree, so line-ending conversion (core.autocrlf on the Windows runners) and file
modes on disk do not change the result. The same commit gives the same hash on
macOS, Linux and Windows.

The digest is SHA-256 over a manifest sorted by path (bytes), one record per
entry:

    <mode> SP <sha256 of content, hex> SP <path> NUL     (files and symlinks)
    160000 SP <commit id> SP <path> NUL                   (submodule, not recursed)

With --submodules, each submodule must be checked out at the commit its
gitlink records, and its files are hashed as if they were in the parent tree
(paths prefixed with the submodule's path). Use it for sources whose
submodules are compiled (cr-sqlite). Without it, a gitlink contributes only its
commit id: for sources whose submodules are never fetched or built (OpenSSL's
test and fuzz submodules).

Usage: tree-sha256.py [--submodules] <checkout-dir>
"""

from __future__ import annotations

import hashlib
import os
import subprocess
import sys
import threading

GITLINK = b"160000"


def _git(repo: str, *args: str) -> bytes:
    return subprocess.run(
        ["git", "-C", repo, *args], check=True, stdout=subprocess.PIPE
    ).stdout


def _ls_tree(repo: str) -> list[tuple[bytes, bytes, bytes, bytes]]:
    out = _git(repo, "ls-tree", "-r", "-z", "--full-tree", "HEAD")
    entries = []
    for rec in out.split(b"\0"):
        if not rec:
            continue
        meta, _, path = rec.partition(b"\t")
        mode, typ, oid = meta.split(b" ")
        entries.append((mode, typ, oid, path))
    return entries


def _blob_sha256(repo: str, oids: list[bytes]) -> dict[bytes, str]:
    """SHA-256 of each blob's content, streamed through one `git cat-file`."""
    proc = subprocess.Popen(
        ["git", "-C", repo, "cat-file", "--batch"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
    )
    assert proc.stdin is not None and proc.stdout is not None

    def feed() -> None:
        for oid in oids:
            proc.stdin.write(oid + b"\n")
        proc.stdin.close()

    writer = threading.Thread(target=feed, daemon=True)
    writer.start()
    digests: dict[bytes, str] = {}
    for oid in oids:
        header = proc.stdout.readline().rstrip(b"\n").split(b" ")
        if len(header) != 3 or header[0] != oid or header[1] != b"blob":
            raise SystemExit(f"tree-sha256: bad cat-file answer for {oid!r}: {header!r}")
        size = int(header[2])
        h = hashlib.sha256()
        left = size
        while left:
            chunk = proc.stdout.read(min(left, 1 << 20))
            if not chunk:
                raise SystemExit(f"tree-sha256: short read for {oid!r}")
            h.update(chunk)
            left -= len(chunk)
        proc.stdout.read(1)  # the newline after each object
        digests[oid] = h.hexdigest()
    writer.join()
    if proc.wait() != 0:
        raise SystemExit("tree-sha256: git cat-file failed")
    return digests


def _records(repo: str, prefix: bytes, submodules: bool) -> list[tuple[bytes, bytes]]:
    entries = _ls_tree(repo)
    blobs = sorted({oid for mode, typ, oid, _ in entries if typ == b"blob"})
    digests = _blob_sha256(repo, blobs)
    records: list[tuple[bytes, bytes]] = []
    for mode, typ, oid, path in entries:
        full = prefix + path
        if typ == b"blob":
            records.append((full, mode + b" " + digests[oid].encode() + b" " + full + b"\0"))
        elif typ == b"commit" and mode == GITLINK:
            if not submodules:
                records.append((full, GITLINK + b" " + oid + b" " + full + b"\0"))
                continue
            sub = os.path.join(repo, os.fsdecode(path))
            if not os.path.exists(os.path.join(sub, ".git")):
                raise SystemExit(f"tree-sha256: submodule {os.fsdecode(full)} is not checked out")
            head = _git(sub, "rev-parse", "HEAD").strip()
            if head != oid:
                raise SystemExit(
                    f"tree-sha256: submodule {os.fsdecode(full)} is at {head.decode()}, "
                    f"its gitlink says {oid.decode()}"
                )
            records.extend(_records(sub, full + b"/", submodules))
        else:
            raise SystemExit(f"tree-sha256: unexpected entry {typ!r} at {os.fsdecode(full)}")
    return records


def tree_sha256(repo: str, submodules: bool) -> str:
    h = hashlib.sha256()
    for _, rec in sorted(_records(repo, b"", submodules)):
        h.update(rec)
    return h.hexdigest()


def main(argv: list[str]) -> int:
    args = argv[1:]
    submodules = "--submodules" in args
    rest = [a for a in args if a != "--submodules"]
    if len(rest) != 1:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    print(tree_sha256(rest[0], submodules))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
