# Changelog

## [Unreleased]

### Fixed
- **Disk pre-flight measured the wrong volume on Linux/macOS** (#3).
  `Get-DriveFreeGB` matched every path to the single `/` PSDrive, so the
  free-space check always reported the root filesystem -- rejecting jobs
  when `/` was tight even with terabytes free on the jobs volume, and
  passing when the real target mount was full. Unix now stats the actual
  path (deepest existing ancestor) via POSIX `df -Pk`.
- **Scope guard (`Assert-InsideRoot`) hardening** (#8, #9). Containment is
  now compared case-sensitively (Ordinal) on Linux/macOS, so a sibling
  directory differing from `jobs_root` only by case can no longer be
  purged; Windows keeps OrdinalIgnoreCase. Symlink/junction leaf
  resolution actually works on both engines (the old 3-arg `Join-Path`
  threw on PowerShell 5.1 and mangled absolute targets on 7): rooted link
  targets are used directly, relative ones resolve against the link's
  parent, and a link whose target cannot be determined is refused (fail
  closed). Non-link reparse tags (OneDrive placeholders) pass through
  unchanged. New Pester coverage: sibling-prefix escape, case-distinct
  sibling (Linux), junction-escape (Windows).

## 0.5.0 -- 2026-07-16

Promoted `0.5.0-rc.2` to a stable release. No functional changes since the
release candidate -- see the `0.5.0-rc.1` / `0.5.0-rc.2` entries below for
everything that landed in this line.

## 0.5.0-rc.2 -- 2026-07-15

### Fixed
- **`/watch-setup -Yes` (non-interactive onboarding) failed at Step 1 on
  every machine.** The wizard's child-spawn helper returned the child's
  stdout AND its exit code on one pipeline; `setup.ps1 -DetectGpu` always
  prints a JSON gpu block, so the "exit code" arrived as an array, the
  `-ne 0` guard element-filtered it to a truthy collection, and the wizard
  aborted (with a garbled `exit { ...json... } 0` message) before writing
  the setup marker -- even when detection succeeded, on GPU and CPU
  machines alike. Child spawns now go through `_lib.ps1`'s new
  `Invoke-WLChild`, which sends child stdout to the host and returns only
  a scalar `[int]` exit code (Pester regression tests added).
- **Runtime provisioning died with "`Get-FileHash` is not recognized"
  under `powershell.exe` on hosts with a polluted `PSModulePath`** (PS7
  module dirs listed on the 5.1 path shadow the built-in Utility module
  with the incompatible PS7 copy). Download verification now hashes via
  .NET (`Get-WLFileSHA256`, no module dependency), and `Get-WLPSEngine`
  falls back to `pwsh` for child spawns when 5.1 cannot resolve
  `Get-FileHash` / `Expand-Archive`.
- Silenced the harmless-but-alarming huggingface_hub cache-symlink warning
  (Windows without Developer Mode) via `HF_HUB_DISABLE_SYMLINKS_WARNING=1`
  in the whisper worker env.

### Changed
- All documented launcher invocations (SKILL.md, command docs, smoke
  harness) now pass `-NoProfile` -- user profiles printed noise and
  started background tasks inside captured setup output. New SKILL.md
  troubleshooting entry covers the polluted-`PSModulePath` failure mode
  and `pwsh -NoProfile` as a supported engine on Windows.

## 0.5.0-rc.1 -- 2026-07-14

**BREAKING: Docker removed.** The plugin now provisions its own fully
portable runtime instead of building/running containers. Motivation:
Docker Desktop's licensing makes it unavailable on many work machines,
and containers were only ever a means to "install nothing on the host,
leave nothing behind" -- which the portable runtime does better.

### Changed
- **All workers run natively.** `/watch-setup` downloads pinned portable
  binaries (yt-dlp standalone, gyan.dev/BtbN/evermeet static ffmpeg, deno,
  uv) plus a uv-managed CPython venv with faster-whisper into
  `<state root>\runtime\`. Every download is sha256-verified against
  `scripts/runtime-manifest.json`. Nothing touches system PATH, the
  registry, or Program Files (`uv python install --no-bin --no-registry`;
  `UV_CACHE_DIR`/`DENO_DIR` pinned inside the runtime dir). Deleting the
  state root removes every trace.
- **GPU whisper via pip CUDA wheels.** faster-whisper/CTranslate2 runs
  CUDA/float16 natively using the `nvidia-cublas-cu12` + `nvidia-cudnn-cu12`
  win_amd64 wheels (new `worker/cuda_paths.py` registers the DLL dirs
  before import). Verified on Blackwell sm_120: native GPU transcription
  measured ~26% FASTER than the Docker path on the same audio (73.5s vs
  99.2s wall, 97.4% word overlap on large-v3).
- **GPU detection is native.** `Test-WLGpuNative` probes host `nvidia-smi`
  + an NVDEC decode test through the portable ffmpeg. New gpu-block field
  `cuda_whisper` (venv-level CUDA availability); a GPU whose CUDA wheels
  fail degrades whisper to cpu/int8 instead of failing the run. Docker-era
  configs migrate on their first `/watch`.
- **Path translation removed.** Workers receive the job dir as
  `W_WORK_DIR` (real host path); `ConvertTo-HostPath` and the
  `/work` / `/input` / `/models` mount model are gone.
  `ConvertTo-DockerPath` renamed `ConvertTo-WLSlashPath` (display only).
- **Exit codes renamed:** 10 `DOCKER_MISSING` -> `RUNTIME_MISSING`,
  11 `DOCKER_DOWN` -> `RUNTIME_BROKEN`. `setup.ps1 -Check` codes:
  2 = runtime not provisioned, 4 = runtime incomplete, 5 = marker missing
  (3 retired).
- **grab-frames on UNC-source jobs now works** -- native ffmpeg reads
  `\\server\share` paths directly (Docker could not mount them after the
  staged copy was gone).

### Added
- `scripts/_runtime.ps1` -- provisioning (`Install-WLRuntime`), status
  (`Test-WLRuntime` / `Assert-WLRuntimeReady`), native worker invocation
  (`Invoke-WLWorker` / `Invoke-WLWorkerCapture`), GPU probes.
- `scripts/runtime-manifest.json` -- pinned versions, per-platform URLs
  (win_x64 / linux_x64 / macos_arm64), sha256 hashes.
- `setup.ps1 -UpdateRuntime` (re-converge to manifest pins / repair) and
  `setup.ps1 -UpdateYtDlp` (yt-dlp self-update for YouTube breakage).
- `setup.ps1 -ListJobs` reports the runtime's disk footprint.
- **Both launcher engines + Linux tested.** Child-process tests (Purge,
  GrabFrames, smoke) now spawn the same engine that runs the suite instead
  of hardcoding `powershell.exe`; the whole suite is path/sandbox-portable
  (XDG redirect, forward-slash literals); CI runs the unit layer under
  Windows PowerShell 5.1, pwsh-on-Windows, AND pwsh-on-Linux. New
  `tests/linux/` dev harness (Dockerfile + runner -- build-machine tooling
  only, the plugin still needs no Docker) runs the full suite on Ubuntu
  including REAL cold-install linux_x64 runtime provisioning, integration,
  and a live /watch smoke -- all verified green. Fixes found on the way:
  Pester pinned to 5.x (6.0.0 fails to import on Linux pwsh), python3
  fallback in run-tests.ps1, and a Docker-Desktop-broken-DNS fallback in
  the harness.
- **Clear "PowerShell 7 missing" error on Linux/macOS.** The SessionStart
  hook is now a Node script (`check-setup.mjs`) instead of PowerShell --
  the old `powershell.exe` hook command failed outright on non-Windows
  hosts, and a missing `pwsh` surfaced only as a raw "command not found".
  The hook now tells the user exactly how to install PowerShell 7 (which
  is NOT preinstalled on Linux/macOS); SKILL.md and the command docs carry
  the same preflight guidance for the launcher invocations.

### Removed
- `docker/` (both whisper Dockerfiles, Dockerfile.tools,
  docker-compose.yml), `Assert-DockerReady`, `Invoke-WLDocker`,
  `Invoke-WLCompose`, `Invoke-WLRun`, docker `Test-WLGpu`,
  `Get-WLToolsGpuFlags`, `Get-WLWhisperImage`, `Get-WLWhisperRunFlags`,
  `ConvertTo-HostPath`, image-tag constants. The WSL2
  `docker compose run` deadlock workaround is obsolete along with its
  cause.

## 0.4.0-rc.1 -- 2026-07-14

GPU auto-detection, NVDEC-accelerated decode, and a fully working
CPU-only mode (including non-Windows hosts).

### Added
- **Reliable GPU detection, persisted in config.** Setup (and a new
  `setup.ps1 -DetectGpu` mode) probes the GPU through docker itself --
  `nvidia-smi` for identity (name, VRAM, driver, compute cap) plus a real
  NVDEC decode test (`h264_cuvid` on a generated clip) -- and stores the
  result as the `gpu` block in config.json. Pre-upgrade installs migrate
  automatically: the first `/watch` runs the probe once and persists it.
- **NVDEC video decode for frame extraction.** When the detected GPU has
  working NVDEC, the tools/screenshots/grab-frames containers run with
  `--gpus all` + `NVIDIA_DRIVER_CAPABILITIES=compute,video,utility` and
  ffmpeg decodes on the GPU (`-hwaccel cuda`, decode-only offload -- the
  fps/scale filter chain is unchanged). The Debian ffmpeg in the existing
  tools image already ships every cuvid/NVDEC decoder; no image change.
  If hwaccel init fails at runtime, ffmpeg falls back to software decode
  on its own (verified).
- **CPU-only mode -- the plugin now fully works without an NVIDIA GPU.**
  No GPU detected: setup builds a new slim `watch-local/whisper:cpu`
  image (`Dockerfile.whisper-cpu`, ~1 GB instead of ~8.7 GB CUDA image)
  and whisper runs with `device=cpu` / `compute_type=int8` (the
  documented faster-whisper CPU configuration). The wizard recommends the
  `small` model on CPU; `/watch` warns when `large-v3` is used on CPU.
  A missing GPU is no longer a fatal setup error (exit 12 retired from
  the install path).
- **Non-Windows hosts (CPU mode).** Launcher scripts now run under
  PowerShell 7 on Linux/macOS: platform-aware default dirs
  (`$XDG_DATA_HOME`/`~/.local/share` + system temp instead of
  LOCALAPPDATA/TEMP), no Windows-only path literals, child scripts spawn
  with the running engine (`pwsh` vs `powershell.exe`), and the
  SessionStart hook resolves the marker path on any OS.
- **Report transparency.** Every report now carries a `**Compute:**` line
  (GPU name + NVDEC/CPU decode + whisper device) and the `**Whisper:**`
  line states the device it ran on.

### Changed
- `docker-compose.yml` gains a `whisper-cpu` service; setup builds only
  the whisper variant matching the detected mode. `setup.ps1 -Check` /
  `-Json` accept whichever whisper image matches the configured mode
  (either variant when detection hasn't run yet).
- Onboarding wizard: GPU probe replaced by detection via the tools image
  (no more `nvidia/cuda` base-image pull just for the check), CPU-aware
  model recommendations, engine-aware command hints.

### Tests
- +10 pytest (hwaccel arg injection into extract/stills commands; audio
  extraction never uses hwaccel) and +15 Pester (probe parsing, mode
  selection, tools GPU flags, platform dirs, config gpu round-trip).

## 0.3.0-rc.2 -- 2026-07-06

Fixes from the first real dogfood session's feedback (all five reported
items addressed).

### Fixed
- **`-SaveHere` from watch.ps1 never worked (and could pair with `-Cleanup`
  to delete the only copy).** The promote call passed save-here.ps1 an
  array of `'-Name'` strings, which PS 5.1 splatting bound positionally
  (`A positional parameter cannot be found that accepts argument '-Cwd'`),
  so promotion always failed -- and `-Cleanup` then deleted the canonical
  dir anyway, leaving the report pointing at promoted paths that were never
  created. Now uses hashtable splatting, and `-Cleanup` is skipped (with a
  warning) whenever the promotion did not succeed. Proven by a real
  `-Cleanup -SaveHere` run: promoted frames exist on disk after exit,
  canonical dir removed. (Standalone `/watch:save-here` was never affected
  -- it binds args normally.)
- **Non-interactive purge confirmation was impossible.** The confirm token
  was regenerated randomly on every invocation, so a token printed by a
  preview run could never match the confirm run -- `-JobConfirmToken` /
  `-ConfirmToken` / `-AllConfirmToken` could only ever fail. Tokens are now
  deterministic over the exact purge target set (SHA-256-derived), so the
  two-run flow works: run once for preview + token, re-run with the token to
  proceed. If the target set changed in between, the token changes and the
  purge refuses -- the confirmation stays bound to exactly what was
  previewed. `Request-Confirm` also fails fast with guidance when stdin is
  redirected instead of blocking forever on `ReadLine`. +3 Pester tests
  including the full two-run flow against a sandboxed jobs_root.
- **`-Cleanup` no longer tells the model to Read frames it just deleted.**
  `-Cleanup` deletes the job dir before the caller gets a turn, so visual
  analysis + `-Cleanup` in one call is impossible by construction. The
  report now says so: under `-Cleanup` alone it lists no frame/screenshot
  paths and prints the two-step alternative (run without `-Cleanup`, Read
  frames, then `setup.ps1 -PurgeJob -Slug <slug>` + token). Under
  `-Cleanup -SaveHere` it lists the promoted copies under
  `./watch-local-output/<slug>/`, which survive. SKILL.md documents the
  interaction.
- **Whisper repetition-loop hallucinations are collapsed and flagged.**
  Runs of 3+ consecutive identical segments (e.g. "You put the work in"
  x15) are collapsed to a single segment spanning the run, and the report
  emits a `**Note:**` naming the affected timespan(s) -- localized
  hallucination bursts don't move the global comparison metrics enough to
  flag on their own. Deliberate short repetition ("no, no") is untouched.
  +5 pytest (92 total).
- **Onboarding wizard no longer hangs in non-interactive shells.** It
  detects redirected stdin and exits 2 with the flag-driven alternative
  (`-Yes`, `-Model`, `-SkipSmoke`, or `setup.ps1 -Check`) instead of
  blocking on `Console.ReadLine()`.
- **`/watch-setup` command doc no longer claims idempotent step-skipping.**
  The wizard re-runs the image build and model warm-up; Docker layer cache
  and the cached model make repeats near-instant. Doc now says so.

### Changed
- **Worker containers get meaningful names.** Docker Desktop now shows
  `watch-local-tools-NNNNN`, `watch-local-whisper-NNNNN`,
  `watch-local-compare-…`, `-screenshots-…`, `-grab-frames-…`,
  `-warmup-…`, `-probe-…`, `-gpucheck-…` instead of random names (unique
  suffix keeps concurrent runs collision-free).
- **Stills replies must include the file path.** grab-frames/SKILL
  instructions now require stating each still's full path when presenting
  it -- the script always printed the paths, but replies could describe
  the image without saying where the file landed.
- **Tools image: yt-dlp refreshed + Deno added.** Deno is yt-dlp's
  recommended JavaScript runtime for YouTube's JS challenges (auto-detected
  on PATH; without it yt-dlp warns and some formats go missing). Rebuild
  with `/watch-setup` or `docker compose build --no-cache tools` to pick
  this up.

## 0.3.0-rc.1 -- 2026-07-04

Daily-use hardening + publish-prep release candidate. Stays a pre-release
until the human plugin-UI install test passes (see README / handoff notes).

### Fixed
- **Two slash commands loaded with empty metadata.** The YAML frontmatter of
  `watch-setup.md` and `watch-save-here.md` failed to parse (unquoted values
  starting with `[`), so description/argument-hint/allowed-tools were
  silently dropped at runtime. Caught by `claude plugin validate --strict`,
  which is now the primary CI gate. Values quoted; both manifests validate
  clean.
- **Local-file reports crashed under StrictMode.** `$info.uploader` does not
  exist for local sources (tools_run.py emits per-source-kind info shapes) and
  StrictMode turns a missing property into a terminating error. The report now
  probes properties before reading (`Get-WLInfoProp`). Verified by a real
  local-file run end to end.
- **`/watch:grab-frames` now works on plain local jobs.** watch.ps1 writes a
  per-job `job.json` (same shape as last-job.json), and grab-frames falls back
  to the recorded original path when there is no downloaded video, mounting
  the source's parent dir read-only exactly like watch.ps1 does. UNC or
  missing sources fail with exit 20 and an actionable message (re-run with
  `-Screenshots` / `-SaveHere -IncludeSource`). +5 Pester regression tests.
- **save-here rejects traversal slugs (exit 60).** A slug containing `\`/`..`
  could re-resolve inside jobs_root on the source side while redirecting the
  destination overwrite outside `./watch-local-output/`. Found by the
  pre-publish security review (its only non-informational finding); the review
  verdict was otherwise publishable with all eight audited areas clean.
  +1 Pester regression test (34 total).
- **`RemoteException` stderr noise eliminated.** `Invoke-WLDocker` unwraps
  native-stderr ErrorRecords to plain text on the real stderr stream: worker
  progress stays live, nothing is buffered or swallowed, exit codes remain the
  source of truth. Verified on synthetic (exit 0/7) and real runs.

### Changed
- **SessionStart hook is now a single marker `Test-Path`** (~160 ms, no child
  powershell, no docker probe). SessionStart fires on every
  startup/resume/clear/compact, so it must stay cheap; Docker/image state
  surfaces via the `setup.ps1 -Check` preflight that SKILL.md Step 0 runs
  before every `/watch`.
- **Exit code 32 (compare failed) retired.** The compare stage is non-fatal
  by design (warn + report continues), so no process could ever exit 32.

### Publish-prep
- `scripts/ci/` validators (marketplace + plugin manifest checks, skill
  frontmatter check, prompt-injection / invisible-Unicode / URL-allowlist
  safety scan, no-private-contact scan) and a GitHub Actions workflow running
  `claude plugin validate --strict` (primary gate) plus the python checks.
- `.gitignore` (dist/, caches); SECURITY.md.

### Docs
- Plugin README rewritten to shipped behavior (always-on Whisper + caption
  comparison, `docker run` worker path, all four commands, honest limits:
  Windows-only, full-audio transcription under `-Start`/`-End` focus,
  translation-provenance gap, size-probe fallback).
- architecture.md: `docker run` rationale, corrected exit-code table, job
  layout (job.json, screenshots/), state-location + SessionStart rationale.

### Verified (this release)
- 87 pytest + 33 Pester + integration suite: all pass.
- Real end-to-end runs: captioned YouTube URL with `-Start/-End` +
  `-Screenshots` (25:41 source, 1080p uncapped, 80 focused frames, creator
  primary, comparison=minor, 2/2 native 1920x1080 stills); plain local file
  (whisper primary); UNC path via staged copy; `/watch:grab-frames` on a
  plain local job (2/2 native stills); `/watch:save-here` (source-link.txt);
  short URL with `-Cleanup` (job dir confirmed removed).

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
