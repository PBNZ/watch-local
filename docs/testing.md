# Running the test suite

## Layers

| Layer | Tool | Scope | Speed |
|---|---|---|---|
| Python unit | pytest | `worker/frames.py`, `worker/captions.py`, `worker/compare.py` | <1 s |
| PowerShell unit | Pester 5 | `_lib.ps1` helpers + scope-invariant + purge-confirm gates | ~10 s |
| Integration | Pester 5 + provisioned runtime | tools + whisper + compare against a synthesized tiny mp4 | ~30 s |
| Smoke | Pester 5 + provisioned runtime + internet | real `/watch` vs a public URL | ~60 s |

## Requirements

- Python 3.11+ with `pytest` installed.
- PowerShell 5.1+ with Pester 5+ (`Install-Module Pester -Force -SkipPublisherCheck`).
- The portable runtime provisioned (run `/watch-setup` first) for
  integration + smoke.

## Engine coverage (PowerShell 5.1 vs 7)

The suite runs on whichever engine invokes it, and child-process tests
(Purge, GrabFrames, the Assert-InsideRoot subshell, smoke) spawn the SAME
engine -- so one invocation covers one engine end to end:

```powershell
powershell -File tests\run-tests.ps1 -Unit   # Windows PowerShell 5.1
pwsh -File tests\run-tests.ps1 -Unit         # PowerShell 7 (also the Linux/macOS engine)
```

CI runs the unit layer on **both** engines (windows-latest matrix in
`validate.yml`). Run both locally before a release when launcher scripts
changed. The integration layer runs in CI on a weekly schedule
(`integration.yml`: provisions the CPU runtime on ubuntu, then
`run-tests.ps1 -Integration`); trigger it manually via workflow_dispatch
after runtime-provisioning changes.

## Linux runs from a Windows build machine (Docker)

`tests/linux/` holds a dev-only container harness (the plugin itself needs
no Docker -- this is build-machine tooling). It runs the suite under pwsh
on Ubuntu, including REAL `linux_x64` runtime provisioning from the pinned
manifest:

```powershell
pwsh -File tests/linux/run-linux-tests.ps1                        # unit only
pwsh -File tests/linux/run-linux-tests.ps1 -Integration           # + provisions the linux runtime
pwsh -File tests/linux/run-linux-tests.ps1 -Integration -Smoke -FreshState   # full cold-install run
```

Runtime + model persist in the `watch-local-linux-state` docker volume;
`-FreshState` deletes it first for a true cold install. The harness
auto-falls back to `--dns 8.8.8.8` when Docker Desktop's container DNS is
broken. Note: Pester is pinned to the 5.x line everywhere -- 6.0.0 fails
to import on Linux pwsh.

## Run everything

```powershell
# unit only (fast, no runtime required):
powershell -File tests\run-tests.ps1 -Unit

# unit + integration (requires provisioned runtime):
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
