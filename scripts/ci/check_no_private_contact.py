#!/usr/bin/env python3
"""Fail the build if private contact info (email-like strings) slips into
any git-tracked file. Belt-and-braces check on top of review.

Scans exactly what git tracks (plus staged-but-uncommitted new files), so
.git internals, dist/, and ignored files are never scanned.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")


def tracked_files() -> list[Path]:
    out = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return [REPO_ROOT / line for line in out.splitlines() if line]


def main() -> None:
    failures: list[tuple[str, int, str]] = []

    for path in tracked_files():
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue  # binary

        rel = path.relative_to(REPO_ROOT).as_posix()
        for lineno, line in enumerate(text.splitlines(), start=1):
            for match in EMAIL.finditer(line):
                failures.append((rel, lineno, match.group(0)))

    if failures:
        for rel, lineno, addr in failures:
            print(
                f"::error file={rel},line={lineno}::"
                f"email-like string found: {addr!r} — remove it",
                file=sys.stderr,
            )
        sys.exit(1)

    print("OK  no private contact info detected")


if __name__ == "__main__":
    main()
