---
description: Promote a /watch job's artifacts into the current directory under ./watch-local-output/<slug>/. Uses the last /watch run by default. Local/UNC sources get a source-link.txt instead of a copy unless --include-source is set.
argument-hint: [last|<slug>] [--include-source] [--move] [--remove-canonical]
allowed-tools: [Bash, AskUserQuestion]
---

Parse $ARGUMENTS:
- First positional token is the slug, or "last" (default if omitted).
- `--include-source` -> add `-IncludeSource` to the call.
- `--move` -> add `-MoveOnSave`.
- `--remove-canonical` -> add `-RemoveCanonical` (prompts user inside the script unless interactive prompts have already run).

Then run:

```bash
powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/save-here.ps1" -Slug <slug> -Cwd "$PWD" [other flags]
```

The script writes a small markdown report listing the destination path. Surface that path to the user clearly so they can find the artifacts in their current project folder.

For local / UNC source files, the script writes a `source-link.txt` with size + mtime + sha256-of-first-64KB instead of copying the (often large) source file. Mention this to the user when applicable so they know the source stays where it is. If they want the source file copied too, suggest re-running with `--include-source`.
