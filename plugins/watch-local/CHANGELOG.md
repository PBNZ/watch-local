# Changelog

## 0.2.2-beta -- 2026-06-05

Fixes the long-standing intermittent `docker compose run` hang (the v0.2.0
blocker) and adds best-quality-by-default capture.

### Fixed -- docker compose run hang (the v0.2.0 blocker)
- **Symptom (observed, reproduced this session):** invoking a worker via
  `docker compose run --rm` intermittently DEADLOCKED at container start --
  the container was created but never transitioned to `Running` (wedged in
  `Created`). Once wedged, `docker rm -f` AND even `docker inspect` on that
  container also hung; only restarting the Docker Desktop / WSL2 engine
  cleared it. It reproduced on real download + whisper workloads even though
  a trivial `docker compose run ... echo hi` succeeded (which had masked it).
- **Mechanism:** not fully root-caused. Because `docker inspect` on the
  wedged container hung, its state/network could not be read. We therefore
  describe the behaviour, not a confirmed cause. (Earlier notes guessed a
  WSL2 per-project-network deadlock; that remains unconfirmed.)
- **Fix:** every per-call worker invocation now uses plain `docker run`
  (`Invoke-WLRun` in `_lib.ps1`) instead of `docker compose run`. Converted
  sites: `watch.ps1` (disk probe, tools, whisper, compare), `setup.ps1`
  (model warm-up), `tests/integration/Run-Integration.ps1` (all stages).
  Plain `docker run` uses the default bridge network and did not exhibit the
  hang in testing (the GPU preflight has always used `docker run --gpus all`
  and never hung). The whisper container's compose service config (GPU +
  `HF_HOME`) is replicated via `$WL_WHISPER_RUN_FLAGS`.
- **`docker compose build` retained** (`Invoke-WLCompose`, used only by
  `setup.ps1`): build runs BuildKit steps and does not start a long-lived
  service container, so it is not subject to this hang.
- **Validation:** unit + integration suites green on the new path; a real
  `/watch` against a 48-min YouTube video completed end-to-end (download +
  100 frames + large-v3 + compare + report); and a second real `/watch`
  succeeded from a freshly-restarted (clean) Docker engine -- the true
  first-time-user state.

### New -- best quality by default
- **Uncapped best video download.** Default `yt-dlp` selector is now best
  video + best audio (was capped at 720p). New shared `worker/formats.py`
  builds the selector and is imported by BOTH `tools_run.py` (the real
  download) and `disk.py` (the size probe) so the pre-flight estimate can
  never drift from the actual download. New `-MaxHeight <px>` flag on
  `watch.ps1` (env `W_MAX_HEIGHT`) caps height when bandwidth matters; 0 /
  unset = uncapped best. (Verified: a 1080p source now downloads at 1080p.)
- **Default survey-frame width raised 512 -> 768px** (`watch.ps1`
  `-Resolution`, `tools_run.py`, `frames.py`). Sharper on-screen text by
  default at ~2.25x the image-token cost; lower with `-Resolution 512` for
  long videos, raise with `-Resolution 1024+` for dense UI text.
- Because the source is now best-quality and kept on disk, specific moments
  can be re-extracted at native resolution on demand for screenshots /
  follow-up content (see `-Screenshots` / `/watch:grab-frames`).

### Tests
- `tests/python/test_formats.py` -- 8 tests locking the shared selector
  (uncapped default, height cap, env-string + edge-case inputs). Total
  unit suite now 87 pytest + 28 Pester.

## 0.2.1-beta -- 2026-05-14

PowerShell 7 compatibility + report-render fixes. v0.2.0-beta `/watch` and
`/watch-setup` were silently broken on PS 7 hosts because native command
stderr from `docker compose run` was being converted into a terminating
`RemoteException` under StrictMode + `$ErrorActionPreference = 'Stop'`.
Real-world test that shipped v0.2.0-beta exercised `docker run` directly
and never hit the orchestrator scripts via PS 7 end-to-end. This release
fixes the full install + watch path.

### Fixed (PS 7 compatibility)
- `Invoke-WLDocker` / `Invoke-WLCompose` helpers in `_lib.ps1`. All
  per-call docker compose invocations in `watch.ps1`, `setup.ps1`, and
  the integration test runner now lower `$ErrorActionPreference` to
  `Continue` for the docker call and pipe output through `Out-Host` so
  the function returns ONLY the exit code (the prior `& docker compose
  ... ; if ($LASTEXITCODE -ne 0)` pattern leaked docker stdout into the
  caller's `$code` and broke `$code -ne 0` comparisons).
- `onboarding.ps1` child `powershell.exe` spawns for setup + smoke test
  wrap in a `Continue` block so child stderr doesn't terminate the
  parent wizard.
- `tests/pester/Lib.Tests.ps1` `Assert-InsideRoot` subshell tests use
  an `Invoke-AssertSubshell` helper that suppresses
  child-stderr-as-terminating-error. (Three tests were false-failing
  even though the function was rejecting correctly.)

### Fixed (zip distribution)
- `build-zip.ps1` now uses `.NET ZipArchive` + `CreateEntryFromFile`
  with explicit forward-slash entry names. PowerShell 5.1's
  `Compress-Archive` writes Windows-style backslash paths inside the
  zip, which the claude.ai plugin uploader rejects with "Zip file
  contains path with invalid characters". Spec-compliant zips MUST use
  forward slashes (PKWARE APPNOTE 4.4.17.1).

### Fixed (watch.ps1 report rendering)
- `Read-CreatorVTT` suffix-merge: `IndexOutOfRangeException` when the
  current cue was fully contained as a suffix of the previous cue
  (`$cc[$k..($cc.Length-1)]` is an invalid reverse-range when
  `$k == $cc.Length`). Guarded with an `@()` fallback.
- `"_Source: $primaryLabel. $headerNote_"` interpolation: PS parsed
  trailing `_` as part of the variable name, throwing `VariableIsUndefined`
  for `$headerNote_` under StrictMode. Rewrote with `-f` operator.
- `$primarySegments` / `$secondarySegments`: ternary if-expression assignment
  could yield a non-array shape, so `.Count` access throws
  `PropertyNotFoundStrict`. Force-array via `@($x | Where-Object {$null -ne $_})`
  before use.

### Verified
- 107/107 unit tests green (79 pytest + 28 Pester).
- Integration suite green (`tools_run.py`, `whisper_run.py`, `compare.py`
  end-to-end against a synthesized silent 10s mp4).
- Cold install verified end-to-end: `docker image rm` watch-local tags +
  purge `%LOCALAPPDATA%\watch-local` + run `setup.ps1 -Model tiny` (cold
  rebuild of both images + tiny model pull) + run `watch.ps1` on a
  captioned YouTube URL (frames + whisper transcribe + creator-vs-whisper
  compare significance=match + report renders cleanly).
- `/watch:save-here` (via `save-here.ps1 -Cwd <scratch>`) promotes
  last-job artifacts to `./watch-local-output/<slug>/` with canonical
  retained.

## 0.2.0-beta -- 2026-05-12

Production-readiness pass.

### New
- Marketplace-shaped distribution. Install via `/plugin marketplace add <path>` + `/plugin install watch-local@watch-local`.
- `/watch-setup` slash command + `scripts/onboarding.ps1` wizard.
- `/watch:save-here` slash command + `-SaveHere` flag on `/watch` to promote artifacts into CWD.
- Persistent config at `%LOCALAPPDATA%\watch-local\config.json`. Manage via `setup.ps1 -Set*` switches.
- `-OutDir <path>` per-call override.
- Always-on Whisper + comparison stage (`compare.py`). Major divergence between creator captions and local Whisper triggers a report callout.
- Caption-provenance classifier (`creator` / `auto` / null) read from yt-dlp's info.json.
- Disk-space pre-flight via `worker/disk.py` (yt-dlp dry-run probe) + drive free-space check on `jobs_root` / `staging_root` / `models_root`.
- Bulk maintenance commands on `setup.ps1`: `-ListJobs`, `-ListModels`, `-PurgeJobs`, `-PurgeJob`, `-PurgeAllJobs`, `-RemoveModel`. Preview-first; random confirmation token required.
- `-DryRun` switch on `watch.ps1`.
- Last-job registry at `last-job.json` so `/watch:save-here` can resolve "last".

### Safety
- Scope invariant (`Assert-InsideRoot`) on every destructive op. Refuses anything outside the configured roots with exit 60.
- `-PurgeAllJobs` requires `-Confirm` AND env var `WATCH_LOCAL_I_REALLY_MEAN_IT=1`.
- Auto-cleanup reversed: `auto_cleanup_days` only WARNS, never auto-deletes.
- Source-link (sha256-first-64KB) for local/UNC promote -- no copies by default.

### Hardening
- All PowerShell scripts: `Set-StrictMode Latest`, `$ErrorActionPreference = 'Stop'`, `#region`/`#endregion` blocks with short labels for VS Code minimap, try/catch on every external invocation.
- Documented exit codes (`_lib.ps1 $script:WL_EXIT`).
- BOM-safe VTT reading (`utf-8-sig`).
- Smarter caption dedupe: exact dup + prefix-extend + suffix-overlap merge.

### Tests
- 79 pytest unit tests (`worker/frames.py`, `worker/captions.py`, `worker/compare.py`).
- 28 Pester unit tests (helpers + scope-invariant + purge confirmation gates).
- Integration runner (`tests/integration/Run-Integration.ps1`) for docker-backed worker checks against a synthesized tiny mp4.
- Smoke runner (`tests/integration/Run-Smoke.ps1`) for a real `/watch` run.
- Combined `tests/run-tests.ps1` orchestrator with `-Unit`, `-Integration`, `-Smoke` flags.

### Documentation
- Top-level README aimed at first-time users.
- `docs/architecture.md` -- pipeline diagram + decisions.
- `docs/transcript-quality.md` -- provenance rules + override flags.
- `docs/output-locations.md` -- jobs_root, -OutDir, -SaveHere, source-link.txt.
- `docs/testing.md` -- how to run the suite.

### Known beta gaps
- Windows host only.
- yt-dlp dry-run probe sometimes returns null (live streams, paywalled extractors) -- launcher falls back to pessimistic 500 MB.

## 0.1.0-beta -- 2026-05-05

Initial beta. Port of `bradautomates/claude-video` v0.1.2 to a fully local,
GPU-accelerated implementation. See git history for details.
