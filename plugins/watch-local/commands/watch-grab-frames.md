---
description: Pull native-resolution screenshots of specific moments from an already-watched /watch job. Use when the user wants a crisp screenshot, or frames to build follow-up content from. Defaults to the last /watch run.
argument-hint: <MM:SS[,MM:SS,...]> [slug|last] [--width N]
allowed-tools: [Bash, Read]
---

The survey frames from `/watch` are downscaled to the `-Resolution` width, but
the best-quality source video stays on disk. Use this command to extract exact
moments at **native resolution** (or a chosen width) for screenshots or
follow-up content.

Parse $ARGUMENTS:
- The list of timestamps (comma-separated, each `SS`, `MM:SS`, or `HH:MM:SS`)
  is **required**. Example: `10:00,22:40,34:05`.
- An optional slug, or `last` (default if omitted) selects which job.
- `--width N` sets the output width in px; omit for native resolution.

Then run:

```bash
powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/grab-frames.ps1" -Slug <slug-or-last> -Screenshots "<timestamps>" [-Resolution <N>]
```

(On Linux/macOS use `pwsh` instead of `powershell.exe -ExecutionPolicy Bypass`.
If `pwsh` is not on PATH, stop and follow the PowerShell 7 install guidance in
SKILL.md's invocation note.)

The script writes the stills into `<job>\screenshots\` and prints their paths.
**Read each printed path** to view the screenshots, then present them to the
user (or use them as the basis for whatever follow-up content was requested).

**Always state each still's full file path in your reply** (e.g.
``C:/Users/.../jobs/<slug>/screenshots/still_00_10.jpg``) -- the user needs
the path to actually use the file; describing the image without it leaves
them hunting for where it landed.

Notes:
- Works on URL jobs (the downloaded video is kept on disk). For local/UNC
  source jobs the original file is not copied by default, so grab-frames can
  only run if the source is still reachable or `/watch` was run with
  `-IncludeSource`.
- To capture screenshots **during** a watch instead of after, pass
  `-Screenshots "MM:SS,MM:SS"` directly to `/watch`.
