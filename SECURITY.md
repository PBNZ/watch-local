# Security

watch-local runs entirely on your machine. What it does, and does not do:

- Runs `yt-dlp` (download), `ffmpeg` (frames/audio), and `faster-whisper`
  (transcription) as plugin-private portable tools -- downloaded once by
  setup from pinned, sha256-verified release URLs into
  `%LOCALAPPDATA%\watch-local\runtime\`. Nothing is installed system-wide:
  no PATH changes, no registry entries, no admin rights.
- Network access: setup fetches the pinned tools + the whisper model; per
  run, yt-dlp fetches only the video you asked for. No telemetry, no API
  calls, no keys, no logins, no cookies.
- Writes artifacts to `%LOCALAPPDATA%\watch-local\` (and `%TEMP%` staging for
  UNC sources). Nothing is written into the plugin install directory.
  Deleting `%LOCALAPPDATA%\watch-local\` removes every trace.
- Every destructive operation (purge/cleanup) is preview-first, requires a
  confirmation token, and is scope-guarded to the configured roots
  (`Assert-InsideRoot`, exit 60 on violation). The token is derived from the
  exact target set shown in the preview, so a confirmation can never apply
  to different targets than were previewed.
- The SessionStart hook is a tiny Node script: a marker-file existence
  check plus a "PowerShell 7 missing" warning on Linux/macOS. No child
  processes, no network.

CI runs `claude plugin validate --strict` plus safety scans (invisible
Unicode, prompt-injection phrases, URL host allowlist, private contact info)
on every push -- see `scripts/ci/` and `.github/workflows/validate.yml`.

## Reporting

Open a GitHub issue on this repository. Please do not include exploit
details in public issues for anything sensitive; say so and a private
channel will be arranged.
