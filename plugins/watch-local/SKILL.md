---
name: watch-local
description: Watch a video (URL, local path, or SMB/UNC share) fully locally. Downloads with yt-dlp, extracts auto-scaled frames with ffmpeg, ALWAYS transcribes with faster-whisper locally and compares against creator-provided captions when present. Auto-detects an NVIDIA GPU (NVDEC decode + CUDA whisper) and falls back to CPU-only mode without one. All workers run in Docker containers on demand. No cloud API keys.
argument-hint: "<video-url-or-path> [question] [flags]"
allowed-tools: Bash, Read, AskUserQuestion
license: MIT
user-invocable: true
---

# /watch-local -- Claude watches a video using local compute

You don't have a video input; this skill gives you one. A PowerShell launcher
runs Docker containers on demand (`tools` + `whisper`), extracts frames,
ALWAYS transcribes with faster-whisper locally, optionally compares against
creator-uploaded captions, then prints frame paths + transcript. You then
`Read` each frame path to see the images and combine them with the
transcript to answer the user.

**Compute modes (auto-detected at setup, cached in config):** with a usable
NVIDIA GPU, video decode runs on NVDEC and whisper on CUDA. Without one,
everything runs CPU-only (whisper on int8) -- slower but fully functional.
The report's **Compute** line states which mode a run used. After
driver/hardware changes, re-detect with `setup.ps1 -DetectGpu`.

**Invocation note:** examples below use `powershell.exe` (Windows). On
Linux/macOS hosts, replace `powershell.exe -ExecutionPolicy Bypass` with
`pwsh` -- the scripts run on PowerShell 7 on any OS (CPU mode; GPU mode
needs the NVIDIA Container Toolkit).

## Step 0 -- Setup preflight (silent on success)

Run before every `/watch` invocation:

```bash
powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/setup.ps1" -Check
```

Exit 0 = ready. **Emit nothing -- proceed to Step 1 silently.**

On non-zero, follow the table:

| Exit | Meaning | Action |
|------|---------|--------|
| `2` | docker CLI missing | Direct user to https://www.docker.com/products/docker-desktop/ then suggest running `/watch-setup`. |
| `3` | Docker Desktop not running | Ask the user to start Docker Desktop and re-run. |
| `4` | Images not built | Suggest `/watch-setup`. |
| `5` | Setup marker missing | Suggest `/watch-setup`. |

`/watch-setup` is the interactive onboarding wizard. It walks the user
through verification, storage locations, model choice (default
`large-v3`), image build, and a smoke test. First-time setup is slow
(image build ~5-15 min, model pull ~3 GB) -- give the user a clear
heads-up before kicking it off.

## When to use

- URL (YouTube, Vimeo, X, TikTok, Twitch, hundreds of yt-dlp sources)
- Local file (`.mp4`, `.mov`, `.mkv`, `.webm`, ...)
- UNC / SMB share (`\\server\share\video.mp4`) -- auto-staged to `%TEMP%`

## How to invoke

**Step 1 -- parse the user input.** Separate the source from any question.

**Step 2 -- run the launcher.**

```bash
powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/watch.ps1" -Source "<source>" [flags]
```

Optional flags (PowerShell named params -- pass as `-Name Value`):

| Flag | Purpose |
|---|---|
| `-Start T` / `-End T` | Focus a section. `SS`, `MM:SS`, or `HH:MM:SS`. |
| `-MaxFrames N` | Lower the cap (default 80, hard max 100). |
| `-Resolution W` | Survey-frame width (default 768; bump to 1024+ for dense on-screen text). |
| `-MaxHeight P` | Cap downloaded video height in px (e.g. 1080). Default 0 = best available (up to 4K/8K). |
| `-Screenshots "MM:SS,MM:SS"` | After the run, save native-resolution stills of these exact moments into `screenshots/`. |
| `-StillResolution W` | Width for `-Screenshots` stills. Default 0 = native source resolution. |
| `-Fps F` | Override auto-fps (clamped at 2 fps). |
| `-Model name` | `large-v3` (default), `medium`, `small`, `base`, `tiny`. On CPU-only machines prefer `small`/`medium` -- `large-v3` on CPU can approach real-time on long videos (the launcher warns). |
| `-Language en` | Force language; default auto-detect. |
| `-OutDir D` | Per-call override of job-dir location. Exclusive with `-SaveHere`. |
| `-SaveHere` | Promote artifacts into `./watch-local-output/<slug>/` after the run. Exclusive with `-OutDir`. |
| `-IncludeSource` | When `-SaveHere`, copy local/UNC source too (default = source-link.txt only). |
| `-MoveOnSave` | When `-SaveHere`, move the canonical dir instead of copy. |
| `-Cleanup` | Delete the job dir at the end of THIS call. Scope-locked to `jobs_root`. **Transcript-only unless combined with `-SaveHere`:** frames are deleted before you get a turn to Read them. |
| `-NoCompare` | Skip the creator-vs-whisper comparison stage. |
| `-PrimaryOverride creator|whisper` | Force primary transcript. |
| `-DryRun` | Print docker invocations, don't execute. |
| `-VerboseLog` | Extra diagnostics on stderr. |

**Step 3 -- Read every frame the script lists.** Forward-slash Windows
paths (`C:/Users/.../jobs/<slug>/frames/frame_NNNN.jpg`). Read them in
a single message for parallel image rendering.

**`-Cleanup` caveat:** under `-Cleanup` the frames are already deleted by
the time the report reaches you -- the report says so and lists no paths.
Visual analysis and `-Cleanup` in a single call are mutually exclusive.
For zero-footprint + visual analysis, run WITHOUT `-Cleanup`, Read the
frames, then delete the job:

```bash
powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/setup.ps1" -PurgeJob -Slug <slug>
# prints a preview + confirm token, then:
powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/setup.ps1" -PurgeJob -Slug <slug> -JobConfirmToken <token>
```

(`-Cleanup -SaveHere` together also works: the report lists the promoted
copies under `./watch-local-output/<slug>/`, which survive.)

**Step 4 -- answer the user.** Cite timestamps. The report's
**Comparison** line tells you which transcript is primary and the
significance of any divergence. If significance == "major", surface
that to the user as a confidence caveat. When you present a screenshot
or still, always state its full file path in the reply -- the user
needs the path to use the file.

**Step 5 -- if user wants to keep artifacts in their project**:
suggest `/watch:save-here` (or re-running with `-SaveHere`).

## Transcription policy

Local Whisper runs **every time** there is an audio track. When the
source has creator-uploaded captions, the launcher uses those as
primary and emits a comparison metric. When only auto-generated
captions exist (or none), local Whisper is primary and captions (if
any) go into a `<details>` fold as the secondary view.

Comparison stage emits three metrics (length ratio, word Jaccard,
3-gram Jaccard) and a worst-of-three `significance` score
(`match` / `minor` / `major`). Major divergence triggers a `**Note:**`
callout in the report.

Whisper repetition loops (the same line hallucinated many times in a
row) are collapsed to a single segment, and the report flags the
affected timespan(s) in a `**Note:**` callout -- treat Whisper output
near those spans as unreliable and prefer creator captions there.
Surface that callout to the user when it appears.

## Partial failures

When whisper fails after frames succeeded (OOM, model load error,
audio decode glitch), the report still emits with a `**Partial
result**` callout. Frames + any creator captions remain usable.
**Always surface that callout to the user verbatim** so they know
the transcript is incomplete.

## Saving artifacts

Default: artifacts stay under `%LOCALAPPDATA%\watch-local\jobs\<slug>\`
indefinitely. They are NOT cleaned up automatically. User can:

- Add `-SaveHere` to a `/watch` call to promote into the project dir.
- Run `/watch:save-here` after the fact to promote the most recent job.
- Pass `-OutDir <path>` to override the per-call location.
- Pass `-Cleanup` to nuke the job dir at end of call.
- Run `/watch-setup` -> bulk maintenance commands (see `setup.ps1 -ListJobs`).

## Failure modes and handling

- **Setup preflight failed** -> suggest `/watch-setup`.
- **Docker daemon down** -> "Start Docker Desktop."
- **GPU not visible** -> NOT an error: the run proceeds in CPU-only mode
  and says so on its **Compute** line. If the user says the machine has an
  NVIDIA GPU, suggest a driver/WSL2 (or NVIDIA Container Toolkit) fix, then
  `setup.ps1 -DetectGpu` to re-probe.
- **Insufficient disk space (exit 50)** -> show the exact "free vs
  needed" numbers from stderr; suggest `setup.ps1 -SetJobsRoot D:\...`
  or `setup.ps1 -PurgeJobs -OlderThanDays N`.
- **Flag conflict (exit 22)** -> `-OutDir` + `-SaveHere` both set --
  pick one.
- **Long video warning** -> offer `-Start`/`-End`.
- **Download fails** -> yt-dlp stderr forwarded; login-required or
  region-locked -> tell the user, don't retry.

## Token efficiency

Frames dominate token cost. ~80 survey frames at the 768px default are
roughly 2.25x the old 512px baseline (area scales with width^2), so
budget ~110-180k image tokens. Transcript cost is small. `-Resolution
1024+` costs more again; lower to `-Resolution 512` for long videos
where you only need the gist.

The downloaded source video is best-quality by default (uncapped, up to
4K/8K). Survey frames are downscaled to `-Resolution`, but the full-res
pixels stay on disk -- so when the user wants a specific screenshot or
follow-up content derived from a frame, pull that exact moment at native
resolution rather than relying on the survey frame.

If the user asks a follow-up about a video already watched in this
session, do NOT re-run the launcher.

## Security & permissions

What this skill does:
- Runs `yt-dlp` in the tools container to download.
- Runs `ffmpeg` in the tools container to extract frames + mono 16 kHz mp3
  (decode on NVDEC when a GPU was detected, otherwise CPU).
- Runs `faster-whisper` in a local container -- on your GPU when detected,
  on your CPU otherwise. Never in the cloud.
- Writes artifacts to `%LOCALAPPDATA%\watch-local\jobs\<slug>\`.
- Caches the whisper model under `%LOCALAPPDATA%\watch-local\models\`.
- UNC sources are staged to `%TEMP%\watch-local-stage\<slug>\` then
  bind-mounted.

What this skill does NOT do:
- No external API calls for transcription or vision.
- No platform login. No cookies. No posting.
- No deletion of anything outside the configured `jobs_root` /
  `models_root` / `staging_root` -- scope-guarded by `Assert-InsideRoot`.
- Purge commands require an explicit confirmation token (preview-first).

## Bundled scripts

- `scripts/watch.ps1` -- host orchestrator
- `scripts/setup.ps1` -- preflight, install, config, maintenance
- `scripts/onboarding.ps1` -- interactive `/watch-setup`
- `scripts/save-here.ps1` -- promote job to CWD
- `scripts/grab-frames.ps1` -- native-resolution stills from an existing job (`/watch:grab-frames`)
- `scripts/build-zip.ps1` -- dist build for marketplace zip
- `scripts/_lib.ps1` -- shared helpers (exit codes, paths, config, confirm, `Invoke-WLRun`)
- `scripts/worker/tools_run.py` -- in tools image (download + frames + audio + provenance)
- `scripts/worker/whisper_run.py` -- in whisper image
- `scripts/worker/compare.py` -- creator-vs-whisper similarity in tools image
- `scripts/worker/frames.py` -- auto-fps + ffmpeg extraction (+ native stills)
- `scripts/worker/stills.py` -- on-demand native-resolution still extraction
- `scripts/worker/formats.py` -- shared yt-dlp format selector (download + probe)
- `scripts/worker/captions.py` -- VTT parsing + smarter dedupe
- `scripts/worker/disk.py` -- yt-dlp dry-run size probe
- `docker/Dockerfile.tools` -- yt-dlp + ffmpeg image (ffmpeg's cuvid/NVDEC decoders activate when run with GPU access)
- `docker/Dockerfile.whisper` -- CUDA 12.8 + faster-whisper image (GPU machines)
- `docker/Dockerfile.whisper-cpu` -- slim faster-whisper image (CPU-only machines)
- `docker/docker-compose.yml` -- service definitions

Review scripts before first use to verify behavior.
