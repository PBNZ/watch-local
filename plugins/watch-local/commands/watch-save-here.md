---
description: "Promote a /watch job's artifacts into the current directory under ./watch-local-output/<slug>/. Uses the last /watch run by default. Local/UNC sources get a source-link.txt instead of a copy unless --include-source is set."
argument-hint: "[last|<slug>] [--include-source] [--move] [--remove-canonical]"
allowed-tools: [Bash, AskUserQuestion]
---

Parse $ARGUMENTS:
- First positional token is the slug, or "last" (default if omitted).
- `--include-source` -> add `-IncludeSource` to the call.
- `--move` -> add `-MoveOnSave`.
- `--remove-canonical` -> add `-RemoveCanonical`. IMPORTANT: confirm with the user (AskUserQuestion) before running with this flag -- the script only prompts on interactive hosts; from this non-interactive Bash call it removes the canonical job dir immediately after a successful copy.

Then run:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/save-here.ps1" -Slug <slug> -Cwd "$PWD" [other flags]
```

(On Linux/macOS use `pwsh -NoProfile` instead of `powershell.exe -NoProfile -ExecutionPolicy Bypass`.
If `pwsh` is not on PATH, stop and follow the PowerShell 7 install guidance in
SKILL.md's invocation note.)

The script writes a small markdown report listing the destination path. Surface that path to the user clearly so they can find the artifacts in their current project folder.

For local / UNC source files, the script writes a `source-link.txt` with size + mtime + sha256-of-first-64KB instead of copying the (often large) source file. Mention this to the user when applicable so they know the source stays where it is. If they want the source file copied too, suggest re-running with `--include-source`.
