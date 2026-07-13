# watch-local marketplace

A Claude Code plugin marketplace containing the **watch-local** plugin --
a fully local port of `bradautomates/claude-video` that runs
faster-whisper via Docker. It auto-detects your NVIDIA GPU and uses it
for both video decode (NVDEC) and transcription (CUDA); without one it
runs in a fully working CPU-only mode. No cloud API keys.

> **What this is (read first):** this plugin was **vibe-coded with Claude
> for personal use** -- and turned out too useful not to share. It is
> genuinely tested (real end-to-end runs, CI with the official strict
> plugin validator and safety scans), but it was built primarily for one
> setup: **Claude Code on Windows 11 with an NVIDIA GPU and Docker
> Desktop**. CPU-only mode and non-Windows (PowerShell 7 + Docker) are
> newer and less battle-tested. If your machine matches the prerequisites
> below, it should just work. If it doesn't, expect to get your hands
> dirty -- issues and PRs welcome, support not promised.

## Status

<!-- state:begin keys=overall_status,gpu_support,platform_support -->
| Fact | Value | As of |
|---|---|---|
| Release status | 0.4.0-rc.1 pre-release (release candidate) | 2026-07-14 |
| GPU / compute support | auto-detected -- NVDEC decode + CUDA whisper on NVIDIA GPUs, CPU-only fallback (int8) otherwise | 2026-07-14 |
| Host platform support | Windows 11 (primary, best-tested); Linux/macOS via PowerShell 7, CPU mode (newer, less tested) | 2026-07-14 |
<!-- state:end -->

## What's in the box

- `/watch <url-or-path> [question]` -- main pipeline
- `/watch-setup` -- one-time interactive wizard
- `/watch:save-here` -- promote a job into the current project dir
- `/watch:grab-frames` -- native-resolution stills from an already-watched job
- Local transcription via `faster-whisper` in Docker (always runs) --
  CUDA on a detected NVIDIA GPU, int8 CPU otherwise
- GPU-accelerated video decode (NVDEC) for frame extraction when the
  detected GPU supports it
- Caption-provenance-aware transcripts (creator subs + Whisper + comparison)
- Best-quality-by-default downloads (uncapped; `-MaxHeight` to cap) and
  on-demand native-res screenshots (`-Screenshots`)
- SMB / UNC source support (auto-staged)
- Disk-space pre-flight, scope-safe purge tools

## Prerequisites

Primary (best-tested) setup:

- **Claude Code** (CLI or desktop app) running on the Windows host
- **Windows 11** (PowerShell 5.1 launcher; ships with Windows)
- **Docker Desktop** with WSL2 backend
- **NVIDIA GPU** (optional but recommended; modern, including Blackwell
  sm_120) with the latest Game Ready / Studio driver and Docker GPU
  support enabled -- setup detects it and uses NVDEC + CUDA automatically
- **Disk:** ~7 GB for images on GPU machines (~2 GB CPU-only), plus the
  whisper model (~3 GB for `large-v3`, ~500 MB for `small`)
- Internet access for video downloads (URL sources) and the one-time
  image build / model pull

No NVIDIA GPU? Setup configures **CPU-only mode** automatically:
everything works, transcription is just slower (the wizard recommends the
`small` model there). Linux/macOS hosts with PowerShell 7 (`pwsh`) +
Docker should work in CPU-only mode but are newer and less tested; GPU
mode on Linux additionally needs the NVIDIA Container Toolkit. AMD/Intel
GPUs are used for nothing (CPU mode). You do NOT need yt-dlp or ffmpeg
installed on the host -- they live in containers.

## Install

### From the distribution zip (recommended for end users)

1. Download `watch-local-marketplace-vX.Y.Z.zip` from the release.
2. Extract it into a stable folder, e.g.
   `C:\Users\<you>\plugins\watch-local-marketplace\`.
3. In Claude Code:

   ```
   /plugin marketplace add "C:\Users\<you>\plugins\watch-local-marketplace"
   /plugin install watch-local@watch-local
   ```

4. Restart Claude Code so the SessionStart hook loads.
5. Run `/watch-setup` to verify Docker, detect your GPU (or configure
   CPU-only mode), build images, and warm the whisper model. First-time
   setup is slow (whisper image build ~5-15 min on GPU, ~2-5 min CPU;
   model pull up to ~3 GB). The wizard tells you upfront.

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

A PowerShell launcher resolves the source, runs the `tools` container
(yt-dlp + ffmpeg) to download + extract frames + extract audio -- with
ffmpeg decoding on NVDEC when the detected GPU supports it -- then runs
the whisper container (CUDA 12.8 + faster-whisper on GPU machines, a
slim CPU image with int8 quantization otherwise). GPU detection runs
once at setup (re-probe with `setup.ps1 -DetectGpu`) and is cached in
config. If the source has creator-uploaded captions, the launcher emits
both transcripts side by side with a similarity score; if not, Whisper
is primary. The host launcher rewrites all container paths to host
`C:/...` form so Claude's `Read` tool resolves frames directly.

Full architecture: [`docs/architecture.md`](./docs/architecture.md)

## Configuration

Settings live in `%LOCALAPPDATA%\watch-local\config.json` and can be
inspected / changed via:

```powershell
powershell -File <plugin>\scripts\setup.ps1 -ShowConfig
powershell -File <plugin>\scripts\setup.ps1 -SetJobsRoot D:\watch-jobs
powershell -File <plugin>\scripts\setup.ps1 -SetDefaultModel medium
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
