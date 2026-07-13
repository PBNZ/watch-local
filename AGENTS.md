# Agent ground rules for this repo

- **Docs move together (living docs).** `docs/STATE.json` is the single source for volatile
  shared facts (statuses, live resources, counts, as-of dates). A commit that changes anything a
  doc states updates `docs/STATE.json` in the same commit; run
  `pwsh scripts/check-docs.ps1 -Update` and include the re-rendered blocks. CI (`docs.yml`)
  fails otherwise.
- **`docs/RUNBOOK.md` is current-state-only.** Replace outdated text instead of annotating it --
  git keeps the history. Dated journal entries go to `CHANGELOG.md`, never the runbook. See the
  `repo-standard` skill: `standard/living-docs.md` and `standard/doc-style.md`.
  (This repo has no runbook yet; the rule applies if one is added.)
- **Plugin code lives under `plugins/watch-local/`**; its user-facing contract is
  `plugins/watch-local/SKILL.md`. Tests: `tests/run-tests.ps1` (pytest + Pester; -Integration
  and -Smoke layers need Docker). CI: `.github/workflows/validate.yml` (strict plugin
  validation + Python validators) and `.github/workflows/docs.yml` (living-docs check).
