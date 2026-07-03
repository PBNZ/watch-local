# watch-local marketplace

A Claude Code plugin marketplace containing the **watch-local** plugin --
a fully local, GPU-accelerated port of `bradautomates/claude-video` that
runs faster-whisper on your NVIDIA GPU via Docker Desktop. No cloud
API keys.

> This is a **beta** distribution. Windows host only. Tested on Windows
> 11 with Docker Desktop (WSL2 backend) and an RTX Blackwell GPU.

## What's in the box

- `/watch <url-or-path> [question]` -- main pipeline
- `/watch-setup` -- one-time interactive wizard
- `/watch:save-here` -- promote a job into the current project dir
- Local NVIDIA GPU transcription via `faster-whisper` in Docker
- Caption-provenance-aware transcripts (creator subs + Whisper + comparison)
- SMB / UNC source support (auto-staged)
- Disk-space pre-flight, scope-safe purge tools

## Prerequisites

- NVIDIA GPU (modern, including Blackwell sm_120)
- Windows 11
- Latest NVIDIA Game Ready / Studio driver
- Docker Desktop with WSL2 backend + GPU support enabled
- ~7 GB free disk for images, ~3 GB more for the default whisper model

You do NOT need yt-dlp or ffmpeg installed on the host -- they live in containers.

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
5. Run `/watch-setup` to verify Docker + GPU, build images, and warm
   the whisper model. First-time setup is slow (image build ~5-15 min,
   model pull ~3 GB for `large-v3`). The wizard tells you upfront.

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
/watch <url> -SaveHere                    # save artifacts into ./watch-local-output/<slug>/
/watch:save-here                          # promote the most recent job
/watch:save-here last --include-source    # also copy local/UNC source file
```

See [SKILL.md](./plugins/watch-local/SKILL.md) for the full flag reference.

## How it works (1-paragraph version)

A PowerShell launcher resolves the source, runs the `tools` container
(yt-dlp + ffmpeg) to download + extract frames + extract audio, then
runs the `whisper` container (CUDA 12.8 + faster-whisper) on the local
GPU. If the source has creator-uploaded captions, the launcher emits
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

Defaults:
- `jobs_root`    = `%LOCALAPPDATA%\watch-local\jobs`
- `models_root`  = `%LOCALAPPDATA%\watch-local\models`
- `staging_root` = `%TEMP%\watch-local-stage`
- `default_model` = `large-v3`

## Safety

Destructive operations (purging jobs / models) are tightly gated:

- Every purge previews exactly what will be deleted before doing anything.
- A unique random confirmation token must be typed (or passed via
  `-ConfirmToken`) per invocation.
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
