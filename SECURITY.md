# Security

watch-local runs entirely on your machine. What it does, and does not do:

- Runs `yt-dlp` (download), `ffmpeg` (frames/audio), and `faster-whisper`
  (transcription) as plugin-private portable tools, downloaded once by
  setup into `%LOCALAPPDATA%\watch-local\runtime\`. Nothing is installed
  system-wide: no PATH changes, no registry entries, no admin rights.
  Download integrity is layered -- see "Download integrity" below.
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

## Download integrity (the sha256-pin trust boundary)

What the sha256 pins do and do not cover:

- **sha256-pinned (verified by watch-local itself):** the four portable
  binaries -- yt-dlp, ffmpeg/ffprobe, deno, uv -- against
  `scripts/runtime-manifest.json`. A mismatch deletes the download and
  aborts setup (covered by tests).
- **Version-pinned only (integrity delegated to uv/PyPI):** the
  uv-managed CPython interpreter and the pip layer (`faster-whisper`,
  `ctranslate2`, and on GPU machines the ~1.3 GB NVIDIA cuBLAS/cuDNN
  wheels). These are exact-version pins installed over TLS with uv's own
  wheel-hash checking against the PyPI index, but watch-local does not
  hold its own hashes for them.
- **Deliberate carve-out:** `setup.ps1 -UpdateYtDlp` (opt-in, for
  YouTube breakage fixes) runs yt-dlp's built-in self-updater, which
  fetches and verifies its own binary from yt-dlp's GitHub releases --
  the updated binary is no longer the manifest-pinned one until the next
  `-UpdateRuntime` re-converge.

## Untrusted video content (prompt injection)

The whole point of `/watch` is to feed third-party video content (title,
uploader, captions, whisper transcript, frame imagery) to an agent that
holds Bash + Read tools -- an inherent prompt-injection surface. Mitigations:

- The report frames all video-derived fields as untrusted data (explicit
  banner + per-field labels), and SKILL.md / the command docs instruct the
  agent to never follow instructions found inside them and to flag
  suspected injection attempts to the user.
- Title/uploader/repetition text is neutralized before it hits bare
  markdown (control chars, backticks, and angle brackets stripped; length
  capped), and transcript blocks strip backticks so they cannot break out
  of their code fences.

This reduces, but cannot eliminate, the risk: instruction-following by the
model is probabilistic, and text visible *inside* video frames cannot be
sanitized. Treat reports from adversarial sources accordingly.

## Reporting

Open a GitHub issue on this repository. Please do not include exploit
details in public issues for anything sensitive; say so and a private
channel will be arranged.
