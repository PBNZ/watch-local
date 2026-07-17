#!/usr/bin/env python3
"""Scan repo Markdown for prompt-injection risks.

Scope: EVERY .md file in the repository (excluding build/output dirs) --
prompt-facing files (SKILL.md, commands/*.md, READMEs) are what a model
actually reads, but agents operating in the repo also read AGENTS.md,
docs/*.md, SECURITY.md, and the shipped CHANGELOG, so everything is
scanned and exceptions are allowlisted rather than the reverse.

Four classes of finding, each a hard failure:
1. Dangerous invisible / bidi / steganographic Unicode.
2. Imperative prompt-injection phrases ("ignore previous instructions",
   ...), matched against NFKC-normalized text. The phrase list is
   best-effort by nature -- it catches known-literal patterns, not
   paraphrases.
3. Mixed-script words (Latin letters mixed with Cyrillic/Greek/... in one
   word) -- the classic homoglyph evasion for check #2.
4. URLs not matching the inline PREFIX allowlist below. Prefixes, not
   bare hosts: whole-platform hosts (github.com) would otherwise pass
   attacker-controlled repos.

Output is GitHub Actions-compatible (::error file=...,line=...::...).
"""
from __future__ import annotations

import pathlib
import re
import sys
import unicodedata

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]

# Directories whose Markdown is not ours to vouch for / not shipped.
EXCLUDE_DIR_PARTS = {".git", "node_modules", "dist", "watch-local-output", "__pycache__"}

# URL prefixes these files legitimately reference. Platform hosts are
# scoped to a path prefix (github.com/<org>/) -- never allowlist a whole
# code/content platform. Anything else fails the build.
ALLOWED_URL_PREFIXES = (
    "https://github.com/pbnz/",             # this project + sibling repos
    "https://github.com/bradautomates/",    # upstream project credit
    "https://learn.microsoft.com/",         # PowerShell install instructions
    "https://docs.pytest.org/",             # testing docs reference
    "https://www.contributor-covenant.org/", # code of conduct reference
    "https://docs.docker.com/",             # legacy Docker-era CHANGELOG history
    "https://www.docker.com/",              # legacy Docker-era CHANGELOG history
    "https://www.youtube.com/watch",        # example video links
    "https://youtube.com/watch",            # example video links
    "https://youtu.be/",                    # example video links
    "https://www.tiktok.com/",              # example yt-dlp-supported link
)

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
# 2. Injection phrases (best-effort literal patterns)
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
# 3. Mixed-script words (homoglyph evasion)
# ---------------------------------------------------------------------------

# Scripts with Latin-confusable letters. A single word mixing two of these
# (e.g. 'Ignore' with a Cyrillic U+043E as its 'o') defeats the literal patterns above
# while rendering identically -- flag it outright.
_CONFUSABLE_SCRIPTS = ("LATIN", "CYRILLIC", "GREEK", "ARMENIAN", "COPTIC", "CHEROKEE")

_WORD_RE = re.compile(r"[^\W\d_]+", re.UNICODE)


def _letter_script(ch: str) -> str | None:
    try:
        name = unicodedata.name(ch)
    except ValueError:
        return None
    first = name.split(" ", 1)[0]
    return first if first in _CONFUSABLE_SCRIPTS else None


def _mixed_scripts(word: str) -> set[str]:
    scripts = {s for s in (_letter_script(c) for c in word) if s}
    return scripts if len(scripts) > 1 else set()


# ---------------------------------------------------------------------------
# 4. URLs (prefix allowlist)
# ---------------------------------------------------------------------------

URL_RE = re.compile(r"https?://[^\s\)\]\>\"'`]+", re.IGNORECASE)


def _normalise_url(url: str) -> str:
    return url.strip().rstrip(".,;:!?").lower()


def _url_allowed(url: str) -> bool:
    return any(url.startswith(prefix) for prefix in ALLOWED_URL_PREFIXES)


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

    # Line-based passes so NFKC normalization (which shifts offsets) still
    # reports accurate line numbers.
    for lineno, line in enumerate(text.splitlines(), start=1):
        norm = unicodedata.normalize("NFKC", line)

        for pattern in _COMPILED_INJECTION:
            for match in pattern.finditer(norm):
                errors.append(
                    f"::error file={rel},line={lineno}::"
                    f"Prompt-injection phrase detected: {match.group(0)!r}"
                )

        for match in _WORD_RE.finditer(line):
            scripts = _mixed_scripts(match.group(0))
            if scripts:
                errors.append(
                    f"::error file={rel},line={lineno}::"
                    f"Mixed-script word (homoglyph evasion risk): "
                    f"{ascii(match.group(0))} mixes {' + '.join(sorted(scripts))}"
                )

        for match in URL_RE.finditer(line):
            url = _normalise_url(match.group(0))
            if not _url_allowed(url):
                errors.append(
                    f"::error file={rel},line={lineno}::"
                    f"URL not in prefix allowlist: {url} "
                    f"(add to ALLOWED_URL_PREFIXES in scripts/ci/check_skill_safety.py if intentional)"
                )

    return errors


def _discover_files() -> list[pathlib.Path]:
    return sorted(
        p for p in REPO_ROOT.rglob("*.md")
        if not (set(p.relative_to(REPO_ROOT).parts[:-1]) & EXCLUDE_DIR_PARTS)
    )


def main() -> int:
    # Findings can quote non-ASCII content; Windows consoles default to a
    # legacy codepage that would crash the report itself.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="replace")

    files = _discover_files()
    if not files:
        print("::error::no Markdown files found", file=sys.stderr)
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
