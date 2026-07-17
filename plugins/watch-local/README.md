# /watch-local

**Give Claude the ability to watch any video -- fully local, on your own hardware.**

A port of [`bradautomates/claude-video`](https://github.com/bradautomates/claude-video)
that drops the cloud Whisper backends (Groq / OpenAI) and runs everything on the
user's machine, on a self-provisioned portable runtime (no Docker):

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
- All tools (yt-dlp, ffmpeg, deno, Python + faster-whisper) are downloaded
  as pinned portable binaries into the plugin's own state folder -- nothing
  installed on the system, nothing on PATH, no admin rights. **Delete
  `%LOCALAPPDATA%\watch-local\` and every trace is gone.**

**Vibe-coded with Claude for personal use, shared because it's too useful
not to.** Tested seriously (unit suites, real end-to-end runs, CI), but
built primarily for one setup: Claude Code on Windows 11 + NVIDIA GPU.
Pre-release. CPU-only mode and non-Windows hosts (PowerShell 7, CPU mode)
are supported but newer and less tested.

## Prerequisites

- Claude Code (CLI or desktop app)
- Windows 11 (primary; PowerShell 5.1 launcher, ships with Windows) -- or
  Linux x64 / macOS Apple Silicon with PowerShell 7 (`pwsh`), CPU mode.
  **pwsh is NOT preinstalled on Linux/macOS** -- install it first
  (macOS: `brew install powershell`; Linux: Microsoft package repo or
  `sudo snap install powershell --classic`; all methods:
  https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
- NVIDIA GPU **optional**: detected automatically and used for NVDEC decode
  + CUDA whisper; without one, setup configures CPU-only mode (whisper on
  int8, `small` model recommended)
- ~0.5 GB free disk for the runtime on CPU machines (~2 GB on GPU machines,
  CUDA libraries included) + the whisper model (~3 GB `large-v3`, ~500 MB
  `small`)
- Ability to run downloaded executables from your user profile (standard;
  strict AppLocker/WDAC policies may block it)

**No Docker.** You do NOT need yt-dlp, ffmpeg, or Python on the host --
the plugin provisions its own portable copies, hash-verified against
pinned versions.

## Install

Install via the marketplace this plugin ships in (see the repository root
README), then run the onboarding wizard once:

```
/plugin marketplace add <marketplace-path-or-repo>
/plugin install watch-local@watch-local
# restart Claude Code, then:
/watch-setup
```

First-time setup downloads everything it needs and says so upfront:
portable tools (~190 MB), the whisper Python stack (~100 MB CPU / ~1.5 GB
GPU with CUDA libraries), and the model (~3 GB for `large-v3`).

## Commands

| Command | What it does |
|---|---|
| `/watch <url-or-path> [question] [flags]` | The main pipeline: download/read, frames, transcribe, report. |
| `/watch-setup` | Interactive onboarding: provision the portable runtime, detect GPU (or configure CPU mode), warm the model, smoke test. |
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
     - URL   -> passed to the tools worker
     - local -> full host path passed straight through
     - UNC   -> copy to %TEMP%\watch-local-stage\<slug>\ first (fast re-reads)
  3. Disk-space preflight (yt-dlp dry-run size probe for URLs)
  4. tools_run.py on the portable runtime
       (yt-dlp download, ffprobe metadata, ffmpeg frames + audio.mp3,
        caption provenance classification)  -> intermediate.json
       [GPU machines: W_HWACCEL=cuda -> ffmpeg decodes on NVDEC]
  5. whisper_run.py   (ALWAYS, if audio)
       GPU: CUDA/float16 (pip cuBLAS/cuDNN wheels)
       CPU: int8         -> transcript_whisper.json
  6. compare.py                                   (if creator subs)
       -> comparison.json (similarity metrics + significance)
  7. Pick primary transcript per provenance rules
  8. Markdown report with real host paths
   |
   v
Claude Reads each frame path, then answers grounded in frames + transcript.
```

The runtime lives at `%LOCALAPPDATA%\watch-local\runtime\` -- pinned
portable binaries plus a uv-managed CPython venv, hash-verified downloads,
per-process PATH only. See [docs/architecture.md](../../docs/architecture.md).

## Files

```
watch-local/
├── .claude-plugin/plugin.json
├── commands/                     # /watch, /watch-setup, /watch:save-here, /watch:grab-frames
├── hooks/                        # SessionStart marker check (fast)
├── scripts/
│   ├── watch.ps1                 # host orchestrator
│   ├── setup.ps1                 # preflight, install, config, purge tools
│   ├── onboarding.ps1            # /watch-setup wizard
│   ├── save-here.ps1             # promote artifacts
│   ├── grab-frames.ps1           # native stills from an existing job
│   ├── build-zip.ps1             # dist zip builder
│   ├── _lib.ps1                  # shared helpers, exit codes, scope guard
│   ├── _runtime.ps1              # portable runtime: provision + worker invocation
│   ├── runtime-manifest.json     # pinned versions, URLs, sha256 hashes
│   └── worker/                   # python workers (run natively)
├── SKILL.md                      # the contract Claude follows
└── README.md
```

## Limits (honest)

- **Windows 11 + NVIDIA GPU is the battle-tested path.** CPU-only mode and
  Linux/macOS (pwsh, CPU mode) are implemented and unit-tested but have had
  far less real-world use. macOS ffmpeg is an x86_64 build, so Apple
  Silicon needs Rosetta 2 (`softwareupdate --install-rosetta
  --agree-to-license`); setup probes for it and stops with that command
  when it is missing.
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
- **YouTube changes break yt-dlp periodically** -- run
  `setup.ps1 -UpdateYtDlp` (self-update) when downloads start failing.

## Differences vs upstream

| | upstream `/watch` | this `/watch-local` |
|---|---|---|
| Transcription | Groq / OpenAI Whisper API, captions preferred | local faster-whisper ALWAYS + caption comparison |
| Network for transcript | yes (audio uploaded) | none |
| Tools install | host (brew / winget) | self-provisioned portable runtime in the state folder |
| Host OS | macOS / Linux / Windows | Windows (primary); Linux/macOS CPU mode (newer) |
| API keys | required for Whisper fallback | none |
| First-run cost | ~10s (brew install) | ~5-10 min (runtime + model download) |
| Per-call latency | API round trip | local GPU (or CPU) |
| UNC / SMB sources | no | yes (auto-staged) |
| Native-res screenshots | no | yes (`-Screenshots`, `/watch:grab-frames`) |

## License

MIT, mirroring upstream.
