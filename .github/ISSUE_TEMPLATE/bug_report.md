---
name: Bug report
about: Something in /watch, /watch-setup, or the maintenance commands misbehaved
labels: bug
---

## What happened

<!-- What you ran (the exact /watch or script invocation), what you expected, what you got. -->

## Environment

- OS: <!-- e.g. Windows 11 / Ubuntu 24.04 / macOS 15 (Apple Silicon) -->
- PowerShell engine: <!-- powershell.exe 5.1 or pwsh 7.x (pwsh -v) -->
- GPU or CPU mode: <!-- from the report's "Compute:" line, or setup output -->

## Status snapshot

<!-- Paste the output of:
powershell -File plugins/watch-local/scripts/setup.ps1 -Json
(pwsh on Linux/macOS). It contains no personal data beyond local paths. -->

```json

```

## Log output

<!-- The [watch] stderr lines around the failure, and the exit code if known. -->
