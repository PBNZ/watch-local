# watch-local -- a Claude Code plugin

**Claude can't watch videos. This plugin fixes that: `/watch` any URL,
local file, or network share and Claude answers from real frames + a
local Whisper transcript -- 100% on your own hardware, zero cloud keys.**

**watch-local** is a fully local port of `bradautomates/claude-video`
that runs faster-whisper natively on a self-contained portable runtime
(no Docker).
It auto-detects your NVIDIA GPU and uses it for both video decode (NVDEC)
and transcription (CUDA); without one it runs in a fully working CPU-only
mode. No cloud API keys, no admin rights, nothing installed on the system
-- delete one folder and every trace is gone.

> **What this is (read first):** this plugin was **vibe-coded with Claude
> for personal use** -- and turned out too useful not to share. It is
> genuinely tested (real end-to-end runs, CI with the official strict
> plugin validator and safety scans), but it was built primarily for one
> setup: **Claude Code on Windows 11 with an NVIDIA GPU**. CPU-only mode
> and non-Windows hosts (PowerShell 7) are newer and less battle-tested.
> If your machine matches the prerequisites below, it should just work.
> If it doesn't, expect to get your hands dirty -- issues and PRs
> welcome, support not promised.

## Status

<!-- state:begin keys=overall_status,gpu_support,platform_support -->
| Fact | Value | As of |
|---|---|---|
| Release status | 0.5.0-rc.2 pre-release (release candidate) | 2026-07-15 |
| GPU / compute support | auto-detected -- NVDEC decode + CUDA whisper on NVIDIA GPUs, CPU-only fallback (int8) otherwise | 2026-07-14 |
| Host platform support | Windows 11 (primary, best-tested); Linux x64 / macOS arm64 via PowerShell 7, CPU mode (newer, less tested) | 2026-07-14 |
<!-- state:end -->

## What's in the box

- `/watch <url-or-path> [question]` -- main pipeline
- `/watch-setup` -- one-time interactive wizard
- `/watch:save-here` -- promote a job into the current project dir
- `/watch:grab-frames` -- native-resolution stills from an already-watched job
- Local transcription via `faster-whisper` (always runs) -- CUDA on a
  detected NVIDIA GPU, int8 CPU otherwise
- GPU-accelerated video decode (NVDEC) for frame extraction when the
  detected GPU supports it
- Caption-provenance-aware transcripts (creator subs + Whisper + comparison)
- Best-quality-by-default downloads (uncapped; `-MaxHeight` to cap) and
  on-demand native-res screenshots (`-Screenshots`)
- SMB / UNC source support (auto-staged)
- Disk-space pre-flight, scope-safe purge tools

## Prerequisites

Primary (best-tested) setup:

- **Claude Code** (CLI or desktop app) running on the host
- **Windows 11** (PowerShell 5.1 launcher; ships with Windows)
- **NVIDIA GPU** (optional but recommended; modern, including Blackwell
  sm_120) with a current Game Ready / Studio driver -- setup detects it
  and uses NVDEC + CUDA automatically
- **Disk:** ~0.5 GB runtime on CPU machines, ~2 GB on GPU machines
  (CUDA libraries), plus the whisper model (~3 GB for `large-v3`,
  ~500 MB for `small`)
- Internet access for video downloads (URL sources) and the one-time
  runtime + model download
- The ability to run downloaded executables from your user profile
  (standard on most machines; strict AppLocker/WDAC policies may block it)

**No Docker.** No admin rights. Nothing is installed system-wide: setup
downloads pinned portable binaries (yt-dlp, ffmpeg, deno, uv) and a
self-contained Python into `%LOCALAPPDATA%\watch-local\runtime\`, verified
against sha256 pins. Nothing touches PATH, the registry, or Program
Files. **Deleting `%LOCALAPPDATA%\watch-local\` removes everything.**

No NVIDIA GPU? Setup configures **CPU-only mode** automatically:
everything works, transcription is just slower (the wizard recommends the
`small` model there). Linux x64 and macOS (Apple Silicon) hosts with
PowerShell 7 (`pwsh`) work in CPU mode but are newer and less tested.
Note that **pwsh is not preinstalled on Linux/macOS** -- install it first
(macOS: `brew install powershell`; Linux: Microsoft package repo or snap;
see https://learn.microsoft.com/powershell/scripting/install/installing-powershell).
AMD/Intel GPUs are used for nothing (CPU mode). You do NOT need yt-dlp,
ffmpeg, or Python installed on the host -- the plugin brings its own.

## Install

### From GitHub (easiest)

```
/plugin marketplace add PBNZ/watch-local
/plugin install watch-local@watch-local
```

Then continue at step 4 below. watch-local is also listed as a reference
entry in the [`PBNZ/pbnz-skills`](https://github.com/PBNZ/pbnz-skills)
marketplace -- `/plugin marketplace add PBNZ/pbnz-skills` surfaces all
PBNZ plugins at once, and `/plugin install watch-local@pbnz-skills`
installs the same canonical plugin from this repo.

### From the distribution zip (offline / pinned-version installs)

1. Download `watch-local-marketplace-vX.Y.Z.zip` from the release.
2. Extract it into a stable folder, e.g.
   `C:\Users\<you>\plugins\watch-local-marketplace\`.
3. In Claude Code:

   ```
   /plugin marketplace add "C:\Users\<you>\plugins\watch-local-marketplace"
   /plugin install watch-local@watch-local
   ```

4. Restart Claude Code so the SessionStart hook loads.
5. Run `/watch-setup` to download the portable runtime, detect your GPU
   (or configure CPU-only mode), and warm the whisper model. Downloads:
   ~190 MB of tools, +~1.5 GB CUDA libraries on GPU machines, plus the
   model (up to ~3 GB). The wizard tells you upfront.

### From source (developers)

```powershell
# clone or fetch the repo, then point /plugin marketplace at the repo root:
/plugin marketplace add "C:\path\to\watch-local-marketplace"
/plugin install watch-local@watch-local
```

## Usage

```
/watch https://youtu.be/dQw4w9WgXcQ what happens at the 30 second mark?
/watch C:\Videos\screen-recording.mp4 when does the UI break?
/watch \\fileserver\videos\interview.mkv summarize the first 2 minutes
/watch <url> -Start 2:15 -End 2:45        # focus a section
/watch <url> -Model medium                # smaller / faster model
/watch <url> -Screenshots "1:00,2:30"     # native-res stills during the run
/watch <url> -SaveHere                    # save artifacts into ./watch-local-output/<slug>/
/watch:save-here                          # promote the most recent job
/watch:save-here last --include-source    # also copy local/UNC source file
/watch:grab-frames 10:00,22:40            # native-res stills from the last job
```

See [SKILL.md](./plugins/watch-local/SKILL.md) for the full flag reference.

## How it works (1-paragraph version)

A PowerShell launcher resolves the source, then runs plain Python workers
on a portable runtime the plugin provisioned for itself: yt-dlp + ffmpeg
download the video, extract frames (ffmpeg decoding on NVDEC when the
detected GPU supports it), and extract audio; faster-whisper then
transcribes -- CUDA/float16 through pip cuBLAS/cuDNN wheels on GPU
machines, int8 on CPU. GPU detection runs once at setup (re-probe with
`setup.ps1 -DetectGpu`) and is cached in config. If the source has
creator-uploaded captions, the launcher emits both transcripts side by
side with a similarity score; if not, Whisper is primary. All reported
paths are real host paths, so Claude's `Read` tool resolves frames
directly.

Full architecture: [`docs/architecture.md`](./docs/architecture.md)

## Configuration

Settings live in `%LOCALAPPDATA%\watch-local\config.json` and can be
inspected / changed via:

```powershell
powershell -File <plugin>\scripts\setup.ps1 -ShowConfig
powershell -File <plugin>\scripts\setup.ps1 -SetJobsRoot D:\watch-jobs
powershell -File <plugin>\scripts\setup.ps1 -SetDefaultModel medium
powershell -File <plugin>\scripts\setup.ps1 -UpdateYtDlp    # YouTube broke? update yt-dlp
powershell -File <plugin>\scripts\setup.ps1 -UpdateRuntime  # re-converge to pinned versions
```

Defaults (Windows; on Linux/macOS the base is `$XDG_DATA_HOME` or
`~/.local/share` and the system temp dir):
- `jobs_root`    = `%LOCALAPPDATA%\watch-local\jobs`
- `models_root`  = `%LOCALAPPDATA%\watch-local\models`
- `staging_root` = `%TEMP%\watch-local-stage`
- `default_model` = `large-v3`
- `gpu`          = detection result (`setup.ps1 -DetectGpu` re-probes)

## Safety

Destructive operations (purging jobs / models) are tightly gated:

- Every purge previews exactly what will be deleted before doing anything.
- A confirmation token must be typed (or passed via `-ConfirmToken`). The
  token is derived from the exact target set shown in the preview, so a
  confirmation can never apply to different targets than were previewed.
- Scope invariant: deletion only targets paths *strictly inside* the
  configured `jobs_root` / `models_root` / `staging_root`. Anything
  outside those (including `./watch-local-output/`, your CWD, `$HOME`,
  drive roots) is refused with exit code 60.
- `-PurgeAllJobs` additionally requires `-Confirm` AND the env var
  `WATCH_LOCAL_I_REALLY_MEAN_IT=1`.
- No auto-deletion. `auto_cleanup_days = N` only WARNS at the start of
  the next `/watch` -- the user runs the purge command explicitly.

## License

MIT. See [LICENSE](./LICENSE).

Ported from [`bradautomates/claude-video`](https://github.com/bradautomates/claude-video).
