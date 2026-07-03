# Architecture

## Components

```
host: Windows + PowerShell + Claude Code
              |
              v
   /watch <args>  (slash command)
              |
              v
   powershell.exe -File watch.ps1 -Source ...
              |
              v
  +---- watch.ps1 orchestrator -----------------------------+
  |   1. resolve config (config.json) + flag overrides     |
  |   2. resolve source (URL / local / UNC -> stage)        |
  |   3. disk-space pre-flight                              |
  |   4. spawn 'tools' container  (CPU)                     |
  |        -> intermediate.json + frames/* + audio.mp3      |
  |   5. spawn 'whisper' container (GPU, ALWAYS runs)       |
  |        -> transcript_whisper.json                       |
  |   6. spawn 'tools' container again for compare.py       |
  |        -> comparison.json                               |
  |   7. pick primary transcript per provenance rules       |
  |   8. emit markdown report (paths rewritten to host)     |
  |   9. (optional) -SaveHere -> save-here.ps1              |
  |  10. (optional) -Cleanup  -> nuke this job dir          |
  +---------------------------------------------------------+
```

## Containers

Two Docker images, both built locally on first `/watch-setup`:

| Image | Base | Size | Purpose |
|---|---|---|---|
| `watch-local/tools:1` | `python:3.11-slim` | ~900 MB | yt-dlp + ffmpeg + Python workers. CPU-only. |
| `watch-local/whisper:cu128` | `nvidia/cuda:12.8.0-cudnn-runtime-ubuntu22.04` | ~9 GB | faster-whisper. GPU. |

Per-call workers run via plain `docker run --rm` (`Invoke-WLRun`) -- they
exist only for the lifetime of the call; nothing is `up -d`. Image builds
still go through `docker compose build` (`docker-compose.yml` is the build
manifest). `docker compose run` is deliberately NOT used: on the Docker
Desktop WSL2 backend it intermittently deadlocks at container start (the
v0.2.0 blocker -- see CHANGELOG 0.2.2).

## Default paths

```
%LOCALAPPDATA%\watch-local\
  config.json              # user config (persistent)
  .setup-complete          # setup marker
  last-job.json            # registry for /watch:save-here last-job lookup
  jobs\<slug>\             # per-call artifacts
    download\              # downloaded video + info.json + VTTs (URL only)
    frames\frame_NNNN.jpg
    screenshots\           # native-res stills (-Screenshots / grab-frames)
    audio.mp3
    intermediate.json
    transcript_whisper.json
    comparison.json
    job.json               # per-job source record (grab-frames uses this)
  models\hf-cache\hub\...  # faster-whisper Hugging Face cache

%TEMP%\watch-local-stage\<slug>\
  <name>.<ext>             # UNC source stage. Removed at end of run.
```

All three roots are configurable via `setup.ps1 -SetJobsRoot / -SetModelsRoot / -SetStagingRoot`.

State deliberately lives OUTSIDE the plugin install dir: `${CLAUDE_PLUGIN_ROOT}`
is replaced on every plugin update, so anything persistent stored there (model
caches, jobs, config) would silently vanish. `%LOCALAPPDATA%\watch-local\` is
Windows' conventional per-user app-data location, survives plugin updates and
reinstalls, and keeps multi-GB artifacts out of `~/.claude`. The scripts never
write runtime state into the plugin directory.

The plugin's SessionStart hook is a single `Test-Path` on the setup marker
(fast by design -- SessionStart fires on every startup/resume/clear/compact).
The full Docker/image preflight runs via `setup.ps1 -Check` in SKILL.md Step 0
before each `/watch`.

## Transcript policy (always run Whisper)

Local Whisper transcribes **every** run (when there is an audio track).
The launcher then picks a primary transcript using this rule:

1. If yt-dlp's `info.json` shows creator-uploaded subs in the language
   filter -> **creator captions = primary**, Whisper = secondary.
2. Otherwise -> **Whisper = primary**, captions (if any) = secondary
   (auto-captions are lower quality than local large-v3).

Both transcripts are surfaced in the report. `compare.py` computes a
similarity score (length ratio, word Jaccard, 3-gram Jaccard) and
emits a worst-of-three significance (`match` / `minor` / `major`).
Major divergence triggers a callout in the report.

See [transcript-quality.md](./transcript-quality.md) for details.

## Path translation

Containers see `/work`, `/input`, `/models`. The host launcher
rewrites these back to Windows forward-slash form (e.g.
`C:/Users/Peter/AppData/Local/watch-local/jobs/abc/frames/frame_0001.jpg`)
before printing. Claude's `Read` tool accepts that form natively.

## Safety: scope invariant

Every destructive function takes a "scope" parameter and uses
`Assert-InsideRoot` to verify the target path is a strict descendant
of the configured root. Symlinks are resolved before the check. A
violation exits with code 60 ("purge refused") and emits an error to
stderr. No silent failures.

This is enforced both at the per-call level (`-Cleanup`) and at the
bulk-maintenance level (`-PurgeJobs`, `-PurgeJob`, `-PurgeAllJobs`,
`-RemoveModel`).

## Exit codes

Documented in `scripts/_lib.ps1`:

| Code | Meaning |
|---|---|
| 0 | success |
| 10 | docker CLI missing |
| 11 | docker daemon down |
| 12 | GPU not visible to docker |
| 20 | source not found / unreachable |
| 21 | UNC stage copy failed |
| 22 | incompatible flags (-OutDir + -SaveHere etc.) |
| 30 | tools container / still extraction failed |
| 31 | whisper image build failed (setup). During /watch a whisper failure is non-fatal: partial report, exit 0 |
| 40 | save-here transfer failed |
| 50 | insufficient disk space |
| 60 | purge refused (outside safe roots, missing confirmation, etc.) |
