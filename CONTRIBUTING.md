# Contributing to watch-local

Issues and PRs are welcome. A few things that keep review fast:

## Before you open a PR

- **Run the unit suite on BOTH engines when launcher scripts change**
  (`plugins/watch-local/scripts/*.ps1`) -- child processes follow the
  invoking engine, so 5.1 and 7 are genuinely different paths:

  ```powershell
  powershell -File tests\run-tests.ps1 -Unit   # Windows PowerShell 5.1
  pwsh -File tests\run-tests.ps1 -Unit         # PowerShell 7
  ```

  Python-only changes: `python -m pytest` from `tests/python/` is enough.
  The `-Integration` / `-Smoke` layers need the provisioned portable
  runtime (`/watch-setup`); see `docs/testing.md`.

- **Living docs move together.** `docs/STATE.json` is the single source
  for volatile facts (statuses, dates, counts). If your change alters
  anything a doc states, update `docs/STATE.json` in the same commit and
  run `pwsh scripts/check-docs.ps1` (CI enforces it). See `AGENTS.md`.

- **Conventional Commits** (`fix:`, `feat:`, `docs:`, `test:`, ...), one
  concern per PR, and a `CHANGELOG.md` entry under `## [Unreleased]` for
  user-visible changes (`plugins/watch-local/CHANGELOG.md`).

## Ground rules for changes

- Destructive operations must stay preview-first + token-confirmed and
  scope-guarded by `Assert-InsideRoot` (see `docs/architecture.md`,
  "Safety: scope invariant").
- Runtime downloads must be pinned in
  `plugins/watch-local/scripts/runtime-manifest.json` (sha256 for
  binaries) -- see SECURITY.md for the trust model.
- New prompt-facing Markdown is scanned by
  `scripts/ci/check_skill_safety.py` (URL prefix allowlist, injection
  phrases, invisible Unicode); run it locally with `python scripts/ci/check_skill_safety.py`.

## Reporting bugs

Use the bug-report issue template. The single most useful thing you can
attach is the output of:

```powershell
powershell -File plugins/watch-local/scripts/setup.ps1 -Json
```

(it captures OS/engine, runtime state, and GPU-vs-CPU mode).
