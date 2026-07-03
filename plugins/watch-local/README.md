# /watch-local

**Give Claude the ability to watch any video — fully local, on your NVIDIA GPU.**

A port of [`bradautomates/claude-video`](https://github.com/bradautomates/claude-video)
that drops the cloud Whisper backends (Groq / OpenAI) and runs everything on the
user's machine via Docker Desktop:

- Downloads with `yt-dlp` — public URLs (YouTube, Vimeo, X, TikTok, Twitch, hundreds more)
- Extracts auto-scaled frames with `ffmpeg`
- Pulls native captions when available (free, fast)
- Falls back to **faster-whisper large-v3** on your local NVIDIA GPU when no captions exist
- All workers run in Docker containers, on demand — nothing stays running between calls

Beta. Windows-host only for now.

## Prerequisites

- NVIDIA GPU (any modern card, including Blackwell)
- Windows 11 with up-to-date NVIDIA drivers
- Docker Desktop with WSL2 backend + GPU support enabled
- ~7 GB free disk for images + ~3 GB for the whisper model

You do NOT need yt-dlp or ffmpeg on the host — both run inside containers.

## Install (Claude Code, dev / manual)

Until this is published as a marketplace plugin, install by symlink or copy:

```powershell
# From this repo:
$dest = Join-Path $env:USERPROFILE ".claude\plugins\watch-local"
Copy-Item -Recurse -Force "<path-to>\plugin" $dest
```

Then run setup once (long — builds images and downloads the model):

```powershell
powershell.exe -ExecutionPolicy Bypass -File "$dest\scripts\setup.ps1"
```

That:
1. Verifies Docker Desktop is running
2. Verifies GPU is exposed to Docker (`docker run --gpus all ... nvidia-smi`)
3. Builds `watch-local/tools` (~200 MB, CPU)
4. Builds `watch-local/whisper:cu128` (~6 GB, CUDA 12.8 + faster-whisper)
5. Warms the model cache by transcribing a 1-second silent clip — pulls
   large-v3 (~3 GB) so the first real `/watch` doesn't stall
6. Writes `%LOCALAPPDATA%\watch-local\.setup-complete`

Re-run setup whenever you want to update images (e.g., new yt-dlp).

## Usage

```
/watch https://youtu.be/dQw4w9WgXcQ what happens at the 30 second mark?
/watch https://www.tiktok.com/@user/video/123 summarize this
/watch C:\Videos\screen-recording.mp4 when does the UI break?
/watch \\fileserver\videos\interview.mkv summarize the first 2 minutes
/watch https://youtu.be/abc -Start 2:15 -End 2:45
/watch C:\Videos\talk.mp4 -Model medium      # smaller model, faster
/watch C:\Videos\silent.mp4 -NoWhisper       # frames-only
```

All flags are PowerShell named params — see `SKILL.md` or `scripts/watch.ps1`
for the full list.

## How it works

```
/watch <source> [opts]
   │
   ▼  (Claude reads SKILL.md, runs scripts/watch.ps1)
watch.ps1:
  1. Slugify -> per-job dir under %LOCALAPPDATA%\watch-local\jobs\<slug>\
  2. Resolve source:
     - URL  → pass through to container
     - local → bind-mount parent dir read-only as /input
     - UNC  → copy to %TEMP%\watch-local-stage\<slug>\, then bind-mount
  3. docker compose run --rm tools
       (yt-dlp download, ffprobe metadata, ffmpeg frames, VTT, audio.mp3)
       → writes /work/intermediate.json
  4. If no captions and -NoWhisper not set:
     docker compose run --rm whisper       (GPU)
       → writes /work/transcript.json
  5. Build markdown report; rewrite all paths to host C:/... form
  6. Print to stdout
   │
   ▼
Claude reads stdout, then Read each frame, then answer the user.
```

## Files

```
plugin/
├── .claude-plugin/
│   ├── plugin.json
│   └── marketplace.json
├── commands/watch.md
├── hooks/
│   ├── hooks.json
│   └── scripts/check-setup.ps1
├── docker/
│   ├── Dockerfile.tools          # python:3.11-slim + yt-dlp + ffmpeg
│   ├── Dockerfile.whisper        # cuda:12.8 + faster-whisper (verbatim from podcast-to-video)
│   └── docker-compose.yml
├── scripts/
│   ├── watch.ps1                 # host orchestrator (PowerShell)
│   ├── setup.ps1                 # preflight + build + model warm-up
│   └── worker/
│       ├── tools_run.py          # in watch-tools
│       ├── whisper_run.py        # in watch-whisper
│       ├── frames.py             # auto-fps + ffmpeg extraction
│       └── captions.py           # VTT parsing
├── SKILL.md
└── README.md
```

## Limits

- **Best accuracy: under 10 minutes.** Sparse-scan warning past that.
- **Hard caps: 100 frames, 2 fps.**
- **No private platforms.** Public URLs and local files only — yt-dlp doesn't
  log into anything.
- **Windows host only (beta).** PowerShell launcher; Docker Desktop assumed.
- **Single-GPU systems assumed.** No multi-GPU scheduling.

## Differences vs upstream

| | upstream `/watch` | this `/watch-local` |
|---|---|---|
| Transcription | Groq / OpenAI Whisper API | faster-whisper on your GPU |
| Network for transcript | Yes (audio uploaded) | None |
| Tools install | host (brew / winget) | inside Docker |
| Host OS | macOS / Linux / Windows | Windows (beta) |
| API keys | required for Whisper fallback | none |
| First-run cost | ~10s (brew install) | ~10–20 min (image build + model pull) |
| Per-call latency | API round trip | local GPU (faster on long videos once warmed) |
| UNC / SMB sources | no | yes (auto-staged) |

## License

MIT, mirroring upstream.
