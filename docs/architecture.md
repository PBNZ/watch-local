# Architecture

## Components

```
host: Windows (powershell.exe) or Linux/macOS (pwsh) + Claude Code
              |
              v
   /watch <args>  (slash command)
              |
              v
   powershell.exe|pwsh -File watch.ps1 -Source ...
              |
              v
  +---- watch.ps1 orchestrator -----------------------------+
  |   1. resolve config (config.json) + flag overrides      |
  |   2. resolve source (URL / local / UNC -> stage)        |
  |   3. disk-space pre-flight                              |
  |   3b. resolve GPU mode (config `gpu` block; one-time    |
  |       probe-and-persist for pre-upgrade configs)        |
  |   4. run tools worker (native python)                   |
  |        GPU+NVDEC: W_HWACCEL=cuda (decode offload)       |
  |        -> intermediate.json + frames/* + audio.mp3      |
  |   5. run whisper worker (ALWAYS runs)                   |
  |        GPU: cuda/float16 via pip CUDA wheels            |
  |        CPU: cpu/int8                                    |
  |        -> transcript_whisper.json                       |
  |   6. run compare.py worker                              |
  |        -> comparison.json                               |
  |   7. pick primary transcript per provenance rules       |
  |   8. emit markdown report                               |
  |   9. (optional) -SaveHere -> save-here.ps1              |
  |  10. (optional) -Cleanup  -> nuke this job dir          |
  +---------------------------------------------------------+
```

## Portable runtime (no Docker)

There are no containers. All workers are plain Python scripts
(`scripts/worker/*.py`) executed by a self-provisioned, fully portable
runtime that `/watch-setup` downloads into the state root:

```
<state root>\runtime\
  manifest.json            # what is actually installed (versions, date)
  bin\
    uv[.exe]               # single-binary python manager
    yt-dlp[.exe]           # official standalone binary (self-updates: setup.ps1 -UpdateYtDlp)
    deno[.exe]             # yt-dlp's JS-challenge runtime
    ffmpeg\bin\ffmpeg[.exe], ffprobe[.exe]   # static build (NVDEC-capable)
  python\                  # uv-managed CPython (pinned minor version)
  venvs\whisper\           # faster-whisper + ctranslate2
                           #   + nvidia cuBLAS/cuDNN pip wheels iff GPU detected
  uv-cache\                # uv download cache (kept inside the root on purpose)
  deno-cache\              # DENO_DIR (same reason)
```

Pinned versions, per-platform download URLs (immutable versioned release
assets), and sha256 hashes live in `scripts/runtime-manifest.json`;
`_runtime.ps1` verifies each of the four binary downloads against its
hash. The CPython interpreter and pip wheels are version-pinned only,
installed via uv (see SECURITY.md "Download integrity" for the exact
trust boundary). Supported platforms: `win_x64`, `linux_x64`,
`macos_arm64` (evermeet ffmpeg is x86_64 and runs under Rosetta 2;
setup probes for it).

Containment rules, enforced by `_runtime.ps1`:

- Nothing is added to the system PATH, registry, or Program Files. Each
  worker process gets a per-process PATH with `runtime\bin` +
  `runtime\bin\ffmpeg\bin` prepended (workers find tools via
  `shutil.which`).
- `uv python install` runs with `--no-bin --no-registry` and
  `UV_PYTHON_INSTALL_DIR`/`UV_CACHE_DIR` inside the runtime dir, so the
  interpreter leaves no trace in `~/.local/bin` or the Windows registry.
- `DENO_DIR` points inside the runtime dir (deno would otherwise cache in
  the user profile).

Deleting the state root therefore removes every trace of the plugin's
tooling. One Python serves all workers: the tools-side workers are
stdlib-only, so they run on the whisper venv's interpreter too.

Worker invocation is `Invoke-WLWorker` (env-var contract `W_*`, stdout
streamed, exit code returned) and `Invoke-WLWorkerCapture` (stdout
captured -- disk.py probe, stills JSON). Workers receive the job dir as
`W_WORK_DIR` (a real host path) -- there is no path translation layer.

## GPU detection

`Test-WLGpuNative` (in `_runtime.ps1`) probes the host directly:

1. `nvidia-smi --query-gpu=name,driver_version,memory.total,compute_cap`
   (found on PATH, System32, or the legacy NVSMI dir) -- presence +
   identity.
2. A 1-second h264 clip is generated with the portable ffmpeg and decoded
   with the explicit `h264_cuvid` decoder -- a hard end-to-end NVDEC test.

A third, whisper-specific signal is probed after the venv exists:
`ctranslate2.get_cuda_device_count()` through the pip CUDA wheels
(`Test-WLCudaWhisper`), persisted as `gpu.cuda_whisper`. Whisper runs on
cuda/float16 only when that passed; a GPU whose CUDA wheels don't load
degrades to cpu/int8 instead of failing the run. On Windows the wheel
DLL dirs (`site-packages/nvidia/*/bin`) are registered by
`worker/cuda_paths.py` before ctranslate2 is imported.

The result (`present`, `name`, `driver`, `vram_mb`, `compute_cap`,
`nvdec`, `cuda_whisper`, `checked_at`) is persisted as the `gpu` block in
config.json by setup, and re-probed on demand with `setup.ps1 -DetectGpu`.
Configs from older versions migrate on their first `/watch` (probe once,
persist). No GPU is never fatal: it selects CPU-only mode.

NVDEC decode is decode-only offload: decoded frames return to system
memory and the existing `fps=...,scale=...` filter chain runs unchanged on
CPU. When hwaccel init fails at runtime despite detection (driver hiccup),
ffmpeg logs a warning and falls back to software decode on its own.

## Default paths

```
%LOCALAPPDATA%\watch-local\
  config.json              # user config (persistent)
  .setup-complete          # setup marker
  last-job.json            # registry for /watch:save-here last-job lookup
  runtime\                 # portable tools + python (see above)
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
On Linux/macOS the defaults are `$XDG_DATA_HOME/watch-local` (fallback
`~/.local/share/watch-local`) and `<system-temp>/watch-local-stage`.

State deliberately lives OUTSIDE the plugin install dir: `${CLAUDE_PLUGIN_ROOT}`
is replaced on every plugin update, so anything persistent stored there (model
caches, jobs, config, the runtime) would silently vanish. `%LOCALAPPDATA%\watch-local\`
is Windows' conventional per-user app-data location (XDG data home is the
equivalent elsewhere), survives plugin updates and reinstalls, and keeps
multi-GB artifacts out of `~/.claude`. The scripts never write runtime state
into the plugin directory. **Uninstall = remove the plugin + delete this one
folder.**

The plugin's SessionStart hook is a tiny Node script (`hooks/scripts/
check-setup.mjs`): a marker-file existence check, plus -- on Linux/macOS --
a clear "install PowerShell 7" error when `pwsh` is missing (pwsh is not
preinstalled there; Node always exists because Claude Code runs on it).
Fast by design -- SessionStart fires on every startup/resume/clear/compact.
The full runtime preflight runs via `setup.ps1 -Check` in SKILL.md Step 0
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

## Safety: scope invariant

Every destructive function takes a "scope" parameter and uses
`Assert-InsideRoot` to verify the target path is a strict descendant
of the configured root. Symlinks are resolved before the check. A
violation exits with code 60 ("purge refused") and emits an error to
stderr. No silent failures.

This is enforced both at the per-call level (`-Cleanup`) and at the
bulk-maintenance level (`-PurgeJobs`, `-PurgeJob`, `-PurgeAllJobs`,
`-PurgeStaging`, `-RemoveModel`).

## Exit codes

Documented in `scripts/_lib.ps1`:

| Code | Meaning |
|---|---|
| 0 | success |
| 10 | runtime not provisioned (run /watch-setup) |
| 11 | runtime provisioned but incomplete (setup.ps1 -UpdateRuntime) |
| 12 | retired (0.4.0): GPU absence now selects CPU mode instead of failing |
| 20 | source not found / unreachable |
| 21 | UNC stage copy failed |
| 22 | incompatible flags (-OutDir + -SaveHere etc.) |
| 30 | tools worker / still extraction failed |
| 31 | whisper setup failure (setup). During /watch a whisper failure is non-fatal: partial report, exit 0 |
| 40 | save-here transfer failed |
| 50 | insufficient disk space |
| 60 | purge refused (outside safe roots, missing confirmation, etc.) |
