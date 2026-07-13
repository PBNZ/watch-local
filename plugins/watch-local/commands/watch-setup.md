---
description: One-time interactive setup for /watch-local. Verifies Docker, detects your NVIDIA GPU (or configures CPU-only mode), picks storage locations, builds container images, downloads the whisper model, and runs a smoke test.
argument-hint: "[-Model name] [-Yes]"
allowed-tools: [Bash, AskUserQuestion]
---

Run the onboarding wizard. The wizard is interactive by default; pass `-Yes` for non-interactive defaults (large-v3 model, default locations, skip smoke test).

Command:

```bash
powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/onboarding.ps1" $ARGUMENTS
```

If the user has previously completed setup, re-running is safe: the wizard re-runs the image build and model warm-up, but Docker's layer cache and the cached model make those near-instant (it re-verifies rather than explicitly skipping). Tell the user upfront that the slow steps ON FIRST RUN are: whisper image build (~5-15 min) and whisper model download (~3 GB for large-v3, the default). Pause for confirmation before kicking those off if the user appears time-constrained.

The wizard prompts on stdin, which does not work from a non-interactive shell (including your own shell tool -- it exits 2 with guidance rather than hanging). In that case pass defaults up front instead: `-Yes` accepts every default, plus optional `-Model <name>` / `-SkipSmoke`. For a status probe only, use `scripts/setup.ps1 -Check`.
