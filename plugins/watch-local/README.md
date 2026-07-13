# /watch-local

**Give Claude the ability to watch any video -- fully local, on your own hardware.**

A port of [`bradautomates/claude-video`](https://github.com/bradautomates/claude-video)
that drops the cloud Whisper backends (Groq / OpenAI) and runs everything on the
user's machine via Docker:

- Downloads with `yt-dlp` -- public URLs (YouTube, Vimeo, X, TikTok, Twitch, hundreds more)
- Extracts auto-scaled survey frames with `ffmpeg` (768px default), plus
  on-demand **native-resolution** stills (`-Screenshots`, `/watch:grab-frames`)
- **Always transcribes with faster-whisper locally** (when the source has an
  audio track) -- CUDA on a detected NVIDIA GPU, int8 CPU otherwise
- **Auto-detects your NVIDIA GPU** at setup: GPU machines get NVDEC video
  decode for frame extraction AND CUDA whisper; machines without one run a
  fully working CPU-only mode
- When creator-uploaded captions exist, they are primary and Whisper is a
  compared secondary -- the report carries a similarity score and flags major
  divergence
- All workers run in Docker containers via plain `docker run --rm`, on demand --
  nothing stays running between calls

**Vibe-coded with Claude for personal use, shared because it's too useful
not to.** Tested seriously (unit suites, real end-to-end runs, CI), but
built primarily for one setup: Claude Code on Windows 11 + NVIDIA GPU +
Docker Desktop. Pre-release. CPU-only mode and non-Windows hosts
(PowerShell 7 + Docker, CPU mode) are supported but newer and less tested.

## Prerequisites

- Claude Code (CLI or desktop app)
- Windows 11 (primary; PowerShell 5.1 launcher) -- or Linux/macOS with
  PowerShell 7 (`pwsh`), CPU mode
- Docker Desktop with WSL2 backend (Windows) or Docker Engine (Linux)
- NVIDIA GPU **optional**: detected automatically and used for NVDEC decode
  + CUDA whisper; without one, setup configures CPU-only mode (whisper on
  int8, `small` model recommended)
- ~7 GB free disk for images on GPU machines (~2 GB CPU-only) + the whisper
  model (~3 GB `large-v3`, ~500 MB `small`)

You do NOT need yt-dlp or ffmpeg on the host -- both run inside containers.

## Install

Install via the marketplace this plugin ships in (see the repository root
README), then run the onboarding wizard once:

```
/plugin marketplace add <marketplace-path-or-repo>
/plugin install watch-local@watch-local
# restart Claude Code, then:
/watch-setup
```

First-time setup is slow and the wizard says so upfront: tools image build
(~3 min), whisper image build (~5-15 min), model pull (~3 GB for `large-v3`).

## Commands

| Command | What it does |
|---|---|
| `/watch <url-or-path> [question] [flags]` | The main pipeline: download/read, frames, transcribe, report. |
| `/watch-setup` | Interactive onboarding: verify Docker, detect GPU (or configure CPU mode), build images, warm the model, smoke test. |
| `/watch:save-here` | Promote the last (or a named) job's artifacts into `./watch-local-output/<slug>/`. |
| `/watch:grab-frames` | Pull native-resolution stills of exact moments from an already-watched job. |

## Usage

```
/watch https://youtu.be/dQw4w9WgXcQ what happens at the 30 second mark?
/watch C:\Videos\screen-recording.mp4 when does the UI break?
/watch \\fileserver\videos\interview.mkv summarize the first 2 minutes
/watch <url> -Start 2:15 -End 2:45              # focus a section
/watch <url> -Model medium                       # smaller / faster model
/watch <url> -Screenshots "1:00,2:30"            # native-res stills during the run
/watch <url> -MaxHeight 1080                     # cap download quality (default: best)
/watch <url> -SaveHere                           # promote artifacts into the project
```

All flags are PowerShell named params -- see [SKILL.md](./SKILL.md) for the
full reference (defaults, caps, exclusivity rules).

## How it works

```
/watch <source> [opts]
   |
   v  (Claude reads SKILL.md, runs scripts/watch.ps1)
watch.ps1:
  1. Slugify -> per-job dir under %LOCALAPPDATA%\watch-local\jobs\<slug>\
  2. Resolve source:
     - URL   -> passed to the tools container
     - local -> bind-mount parent dir read-only as /input
     - UNC   -> copy to %TEMP%\watch-local-stage\<slug>\, then bind-mount
  3. Disk-space preflight (yt-dlp dry-run size probe for URLs)
  4. docker run --rm watch-local/tools:1
       (yt-dlp download, ffprobe metadata, ffmpeg frames + audio.mp3,
        caption provenance classification)  -> intermediate.json
       [GPU machines: + --gpus all + W_HWACCEL=cuda -> ffmpeg decodes on NVDEC]
  5. docker run --rm watch-local/whisper:*   (ALWAYS, if audio)
       GPU: --gpus all whisper:cu128 (CUDA/float16)
       CPU: whisper:cpu (int8)      -> transcript_whisper.json
  6. docker run --rm watch-local/tools:1 compare.py         (if creator subs)
       -> comparison.json (similarity metrics + significance)
  7. Pick primary transcript per provenance rules
  8. Markdown report; rewrite container paths to host C:/... form
   |
   v
Claude Reads each frame path, then answers grounded in frames + transcript.
```

Per-call workers use plain `docker run --rm` deliberately -- `docker compose
run` intermittently deadlocks at container start on the WSL2 backend (see
CHANGELOG 0.2.2). Image builds still use `docker compose build`.

## Files

```
watch-local/
├── .claude-plugin/plugin.json
├── commands/                     # /watch, /watch-setup, /watch:save-here, /watch:grab-frames
├── hooks/                        # SessionStart marker check (fast, no docker)
├── docker/
│   ├── Dockerfile.tools          # python:3.11-slim + yt-dlp + ffmpeg
│   ├── Dockerfile.whisper        # cuda:12.8 + faster-whisper (GPU machines)
│   ├── Dockerfile.whisper-cpu    # python:3.11-slim + faster-whisper (CPU machines)
│   └── docker-compose.yml        # build manifest (builds only)
├── scripts/
│   ├── watch.ps1                 # host orchestrator
│   ├── setup.ps1                 # preflight, install, config, purge tools
│   ├── onboarding.ps1            # /watch-setup wizard
│   ├── save-here.ps1             # promote artifacts
│   ├── grab-frames.ps1           # native stills from an existing job
│   ├── build-zip.ps1             # dist zip builder
│   ├── _lib.ps1                  # shared helpers, exit codes, scope guard
│   └── worker/                   # python workers that run inside the containers
├── SKILL.md                      # the contract Claude follows
└── README.md
```

## Limits (honest)

- **Windows 11 + NVIDIA GPU is the battle-tested path.** CPU-only mode and
  Linux/macOS (pwsh, CPU mode) are implemented and unit-tested but have had
  far less real-world use. GPU mode on Linux needs the NVIDIA Container
  Toolkit and is untested here.
- **CPU transcription is slow with big models.** `large-v3` on CPU can
  approach real-time on long videos; the launcher warns and the wizard
  recommends `small` on CPU machines.
- **Best accuracy: videos under 10 minutes** (or use `-Start`/`-End`). The
  report warns when frame coverage goes sparse.
- **Hard caps: 100 frames, 2 fps.**
- **No private platforms.** Public URLs and local files only -- yt-dlp does not
  log into anything, no cookies.
- **Caption provenance can't detect translations.** Creator-uploaded
  translations classify as `creator` (see docs/transcript-quality.md).
- **yt-dlp size probe can return nothing** (live streams, some extractors) --
  the disk preflight then assumes a pessimistic 500 MB.
- **Single-GPU systems assumed.** No multi-GPU scheduling.
- Whisper transcribes the full audio track even when `-Start`/`-End` focus is
  set (the report filters the displayed transcript to the focus range).

## Differences vs upstream

| | upstream `/watch` | this `/watch-local` |
|---|---|---|
| Transcription | Groq / OpenAI Whisper API, captions preferred | local faster-whisper ALWAYS + caption comparison |
| Network for transcript | yes (audio uploaded) | none |
| Tools install | host (brew / winget) | inside Docker |
| Host OS | macOS / Linux / Windows | Windows (primary); Linux/macOS CPU mode (newer) |
| API keys | required for Whisper fallback | none |
| First-run cost | ~10s (brew install) | ~10-20 min (image build + model pull) |
| Per-call latency | API round trip | local GPU (or CPU) |
| UNC / SMB sources | no | yes (auto-staged) |
| Native-res screenshots | no | yes (`-Screenshots`, `/watch:grab-frames`) |

## License

MIT, mirroring upstream.
