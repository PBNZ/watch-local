# Running the test suite

## Layers

| Layer | Tool | Scope | Speed |
|---|---|---|---|
| Python unit | pytest | `worker/frames.py`, `worker/captions.py`, `worker/compare.py` | <1 s |
| PowerShell unit | Pester 5 | `_lib.ps1` helpers + scope-invariant + purge-confirm gates | ~10 s |
| Integration | Pester 5 + docker | tools + whisper + compare against a synthesized tiny mp4 | ~30 s |
| Smoke | Pester 5 + docker + GPU + internet | real `/watch` vs a public URL | ~60 s |

## Requirements

- Python 3.11+ with `pytest` installed.
- PowerShell 5.1+ with Pester 5+ (`Install-Module Pester -Force -SkipPublisherCheck`).
- Docker Desktop running with GPU access (for integration + smoke).
- The watch-local images built (run `/watch-setup` first).

## Run everything

```powershell
# unit only (fast, no docker required):
powershell -File tests\run-tests.ps1 -Unit

# unit + integration (requires images):
powershell -File tests\run-tests.ps1 -Unit -Integration

# everything including a real /watch run:
powershell -File tests\run-tests.ps1 -Unit -Integration -Smoke
```

## Run a specific layer

```powershell
# Python only
cd tests\python && python -m pytest -v

# PowerShell unit only
Import-Module Pester -MinimumVersion 5.0
Invoke-Pester tests\pester
```

## What the purge tests verify

`tests/pester/Purge.Tests.ps1` is the highest-value file in the suite.
Destructive bugs are unforgiving, so each scenario runs setup.ps1 in
a sandboxed `jobs_root` (under `%TEMP%`) and checks invariants:

- Refuses purge when scope-limiting flag (`-OlderThanDays`) omitted.
- `-DryRun` never mutates the filesystem.
- A wrong / missing confirmation token does not delete anything.
- `-PurgeAllJobs` refused without both `-Confirm` AND the
  `WATCH_LOCAL_I_REALLY_MEAN_IT=1` env var.
- Sentinel files outside the sandbox survive every test.
- Path-traversal slugs (`..\..\Windows`) are rejected.

If you add new destructive operations, add corresponding tests here.
