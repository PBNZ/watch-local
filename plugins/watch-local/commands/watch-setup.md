---
description: One-time interactive setup for /watch-local. Downloads the portable runtime (yt-dlp, ffmpeg, deno, Python -- no Docker, no admin), detects your NVIDIA GPU (or configures CPU-only mode), picks storage locations, downloads the whisper model, and runs a smoke test.
argument-hint: "[-Model name] [-Yes]"
allowed-tools: [Bash, AskUserQuestion]
---

Run the onboarding wizard. The wizard is interactive by default; pass `-Yes` for non-interactive defaults (large-v3 model, default locations, skip smoke test).

Command:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/onboarding.ps1" $ARGUMENTS
```

(On Linux/macOS use `pwsh -NoProfile` instead of `powershell.exe -NoProfile -ExecutionPolicy Bypass`.
PowerShell 7 is NOT preinstalled there -- if `pwsh` is not on PATH, stop and
tell the user to install it first: macOS `brew install powershell`; Linux via
the Microsoft package repo or `sudo snap install powershell --classic`; all
methods at https://learn.microsoft.com/powershell/scripting/install/installing-powershell.)

If the user has previously completed setup, re-running is safe: already-downloaded tools and the cached model are re-verified rather than re-fetched. Tell the user upfront what downloads ON FIRST RUN: portable tools (~190 MB), the whisper Python stack (~100 MB CPU / ~1.5 GB with CUDA libraries on GPU machines), and the whisper model (~3 GB for large-v3, the default). Pause for confirmation before kicking those off if the user appears time-constrained.

The wizard prompts on stdin, which does not work from a non-interactive shell (including your own shell tool -- it exits 2 with guidance rather than hanging). In that case pass defaults up front instead: `-Yes` accepts every default, plus optional `-Model <name>` / `-SkipSmoke`. For a status probe only, use `scripts/setup.ps1 -Check`.
