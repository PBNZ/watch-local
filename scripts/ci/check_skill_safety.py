#!/usr/bin/env python3
"""Scan prompt-facing Markdown for prompt-injection risks.

Scope: root README.md, plugins/*/SKILL.md, plugins/*/README.md,
plugins/*/commands/*.md (the files a model actually reads).

Three classes of finding, each a hard failure:
1. Dangerous invisible / bidi / steganographic Unicode.
2. Imperative prompt-injection phrases ("ignore previous instructions", ...).
3. URLs whose host is not in the inline allowlist below.

Output is GitHub Actions-compatible (::error file=...,line=...::...).
"""
from __future__ import annotations

import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]

SCAN_GLOBS = (
    "README.md",
    "plugins/*/SKILL.md",
    "plugins/*/README.md",
    "plugins/*/commands/*.md",
    "plugins/*/skills/*/SKILL.md",
)

# Hosts these files legitimately reference. Subdomains are allowed
# (www.docker.com matches docker.com). Anything else fails the build.
ALLOWED_HOSTS = {
    "docker.com",     # Docker Desktop install link in SKILL.md
    "github.com",     # upstream project credit (bradautomates/claude-video)
    "youtube.com",    # example video links
    "youtu.be",       # example video links
    "tiktok.com",     # example yt-dlp-supported link in plugin README
}

# ---------------------------------------------------------------------------
# 1. Dangerous characters
# ---------------------------------------------------------------------------

DANGEROUS_CHARS: dict[str, str] = {
    "\u200b": "ZERO WIDTH SPACE (U+200B)",
    "\u200c": "ZERO WIDTH NON-JOINER (U+200C)",
    "\u200d": "ZERO WIDTH JOINER (U+200D)",
    "\u2060": "WORD JOINER (U+2060)",
    "\u180e": "MONGOLIAN VOWEL SEPARATOR (U+180E)",
    "\xad": "SOFT HYPHEN (U+00AD)",
    "\ufeff": "ZERO WIDTH NO-BREAK SPACE / BOM (U+FEFF)",
    "\u202a": "LEFT-TO-RIGHT EMBEDDING (U+202A)",
    "\u202b": "RIGHT-TO-LEFT EMBEDDING (U+202B)",
    "\u202c": "POP DIRECTIONAL FORMATTING (U+202C)",
    "\u202d": "LEFT-TO-RIGHT OVERRIDE (U+202D)",
    "\u202e": "RIGHT-TO-LEFT OVERRIDE (U+202E)",
    "\u2066": "LEFT-TO-RIGHT ISOLATE (U+2066)",
    "\u2067": "RIGHT-TO-LEFT ISOLATE (U+2067)",
    "\u2068": "FIRST STRONG ISOLATE (U+2068)",
    "\u2069": "POP DIRECTIONAL ISOLATE (U+2069)",
}


def _is_stegano(ch: str) -> str | None:
    cp = ord(ch)
    if 0xFE00 <= cp <= 0xFE0F:
        return f"VARIATION SELECTOR (U+{cp:04X})"
    if 0xE0000 <= cp <= 0xE007F:
        return f"TAG CHARACTER (U+{cp:05X})"
    return None


# ---------------------------------------------------------------------------
# 2. Injection phrases
# ---------------------------------------------------------------------------

INJECTION_PATTERNS = [
    r"ignore\s+(all\s+)?previous\s+instructions?",
    r"ignore\s+(all\s+)?prior\s+instructions?",
    r"disregard\s+(all\s+)?previous\s+instructions?",
    r"disregard\s+the\s+above",
    r"forget\s+(all\s+)?your\s+instructions?",
    r"forget\s+everything\s+above",
    r"forget\s+(all\s+)?previous\s+instructions?",
    r"you\s+are\s+now\s+in\s+developer\s+mode",
    r"dan\s+mode\s+activated",
    r"do\s+anything\s+now",
    r"jailbreak\s+mode",
]

_COMPILED_INJECTION = [re.compile(p, re.IGNORECASE) for p in INJECTION_PATTERNS]

# ---------------------------------------------------------------------------
# 3. URLs
# ---------------------------------------------------------------------------

URL_RE = re.compile(r"https?://([^/\s\)\]\>\"]+)", re.IGNORECASE)


def _normalise_host(host: str) -> str:
    host = host.strip().lower().rstrip(".,;:!?\"'")
    return host.split(":", 1)[0]


def _host_allowed(host: str) -> bool:
    return host in ALLOWED_HOSTS or any(
        host.endswith("." + allowed) for allowed in ALLOWED_HOSTS
    )


# ---------------------------------------------------------------------------
# Scanning
# ---------------------------------------------------------------------------

def scan_file(path: pathlib.Path) -> list[str]:
    errors: list[str] = []
    rel = path.relative_to(REPO_ROOT).as_posix()
    text = path.read_text(encoding="utf-8")

    def line_of(index: int) -> int:
        return 1 + text.count("\n", 0, index)

    for idx, ch in enumerate(text):
        if ch in DANGEROUS_CHARS:
            errors.append(
                f"::error file={rel},line={line_of(idx)}::"
                f"Dangerous invisible character: {DANGEROUS_CHARS[ch]}"
            )
            continue
        label = _is_stegano(ch)
        if label is not None:
            errors.append(
                f"::error file={rel},line={line_of(idx)}::"
                f"Suspicious steganographic character: {label}"
            )

    for pattern in _COMPILED_INJECTION:
        for match in pattern.finditer(text):
            errors.append(
                f"::error file={rel},line={line_of(match.start())}::"
                f"Prompt-injection phrase detected: {match.group(0)!r}"
            )

    for match in URL_RE.finditer(text):
        host = _normalise_host(match.group(1))
        if not _host_allowed(host):
            errors.append(
                f"::error file={rel},line={line_of(match.start())}::"
                f"URL host not in allowlist: {host} "
                f"(add to ALLOWED_HOSTS in scripts/ci/check_skill_safety.py if intentional)"
            )

    return errors


def main() -> int:
    files = sorted({p for g in SCAN_GLOBS for p in REPO_ROOT.glob(g)})
    if not files:
        print("::error::no prompt-facing Markdown files found", file=sys.stderr)
        return 1

    all_errors: list[str] = []
    for path in files:
        all_errors.extend(scan_file(path))

    if all_errors:
        for line in all_errors:
            print(line)
        print(
            f"FAIL  check_skill_safety.py — {len(all_errors)} issue(s) "
            f"across {len(files)} file(s)",
            file=sys.stderr,
        )
        return 1

    print(f"OK  check_skill_safety.py — {len(files)} file(s) clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
