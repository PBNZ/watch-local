#!/usr/bin/env python3
"""Validate SKILL.md frontmatter for every plugin.

watch-local keeps its skill at the plugin root (plugins/<plugin>/SKILL.md),
so this checks that layout plus the conventional plugins/*/skills/*/SKILL.md.

Checks:
- File starts with YAML frontmatter delimited by '---'.
- Frontmatter is valid YAML.
- Required fields: name, description (non-empty strings).
- 'name' matches the owning directory name (plugin dir or skill dir).
- Body after frontmatter is non-empty.
"""
from __future__ import annotations

import sys
from pathlib import Path

import yaml  # type: ignore[import-untyped]

REPO_ROOT = Path(__file__).resolve().parents[2]
PLUGINS_DIR = REPO_ROOT / "plugins"


def fail(path: Path, msg: str) -> None:
    print(f"::error file={path.relative_to(REPO_ROOT).as_posix()}::{msg}", file=sys.stderr)
    sys.exit(1)


def extract_frontmatter(text: str) -> tuple[str, str]:
    """Return (frontmatter_yaml, body). Raises ValueError if no frontmatter."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        raise ValueError("first line must be exactly '---'")

    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            return "\n".join(lines[1:i]), "\n".join(lines[i + 1 :])

    raise ValueError("no closing '---' for frontmatter block")


def main() -> None:
    skill_files = sorted(PLUGINS_DIR.glob("*/SKILL.md")) + sorted(
        PLUGINS_DIR.glob("*/skills/*/SKILL.md")
    )
    if not skill_files:
        print("::error::no SKILL.md files found under plugins/", file=sys.stderr)
        sys.exit(1)

    for skill_path in skill_files:
        owner_dir_name = skill_path.parent.name
        text = skill_path.read_text(encoding="utf-8")

        try:
            fm_yaml, body = extract_frontmatter(text)
        except ValueError as exc:
            fail(skill_path, f"frontmatter error: {exc}")

        try:
            fm = yaml.safe_load(fm_yaml)
        except yaml.YAMLError as exc:
            fail(skill_path, f"invalid YAML frontmatter: {exc}")

        if not isinstance(fm, dict):
            fail(skill_path, "frontmatter must be a YAML mapping")

        name = fm.get("name")
        if not isinstance(name, str) or not name.strip():
            fail(skill_path, "missing or empty 'name' in frontmatter")

        if name != owner_dir_name:
            fail(
                skill_path,
                f"frontmatter 'name' ({name!r}) does not match directory name "
                f"({owner_dir_name!r})",
            )

        description = fm.get("description")
        if not isinstance(description, str) or not description.strip():
            fail(skill_path, "missing or empty 'description' in frontmatter")

        if not body.strip():
            fail(skill_path, "SKILL.md has no body content after frontmatter")

        print(f"OK  {skill_path.relative_to(REPO_ROOT).as_posix()}")


if __name__ == "__main__":
    main()
