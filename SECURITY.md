# Security

watch-local runs entirely on your machine. What it does, and does not do:

- Runs `yt-dlp` (download) and `ffmpeg` (frames/audio) in a CPU container,
  and `faster-whisper` in a GPU container -- all via `docker run --rm`.
- Network access happens only inside the tools container, only to fetch the
  video you asked for. No telemetry, no API calls, no keys, no logins, no
  cookies.
- Writes artifacts to `%LOCALAPPDATA%\watch-local\` (and `%TEMP%` staging for
  UNC sources). Nothing is written into the plugin install directory.
- Every destructive operation (purge/cleanup) is preview-first, requires a
  confirmation token, and is scope-guarded to the configured roots
  (`Assert-InsideRoot`, exit 60 on violation). The token is derived from the
  exact target set shown in the preview, so a confirmation can never apply
  to different targets than were previewed.
- The SessionStart hook is a single `Test-Path` on a marker file.

CI runs `claude plugin validate --strict` plus safety scans (invisible
Unicode, prompt-injection phrases, URL host allowlist, private contact info)
on every push -- see `scripts/ci/` and `.github/workflows/validate.yml`.

## Reporting

Open a GitHub issue on this repository. Please do not include exploit
details in public issues for anything sensitive; say so and a private
channel will be arranged.
