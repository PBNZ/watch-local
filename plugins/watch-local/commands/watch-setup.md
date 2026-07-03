---
description: One-time interactive setup for /watch-local. Verifies Docker + GPU, picks storage locations, builds container images, downloads the whisper model, and runs a smoke test.
argument-hint: [-Model name] [-Yes]
allowed-tools: [Bash, AskUserQuestion]
---

Run the onboarding wizard. The wizard is interactive by default; pass `-Yes` for non-interactive defaults (large-v3 model, default locations, skip smoke test).

Command:

```bash
powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/onboarding.ps1" $ARGUMENTS
```

If the user has previously completed setup, the wizard idempotently re-verifies and skips already-done steps. Tell the user upfront that the slow steps are: whisper image build (~5-15 min) and whisper model download (~3 GB for large-v3, the default). Pause for confirmation before kicking those off if the user appears time-constrained.
