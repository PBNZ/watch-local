#!/bin/sh
# SessionStart hook -- one-line nudge if setup never completed, and a clear
# error when PowerShell 7 is missing on Linux/macOS (it is not preinstalled
# there, and the plugin's launchers need it).
#
# SessionStart fires on EVERY Claude Code startup/resume/clear/compact, so
# this must stay cheap: shell builtins and filesystem checks only, no child
# processes. POSIX sh is used (not Node or PowerShell) because it is the one
# interpreter present wherever Claude Code can run hooks at all: /bin/sh on
# Linux/macOS, and Git Bash on Windows (a hard requirement of the Windows
# install). Native Claude Code installs bundle their own runtime and do NOT
# put node on PATH, so a Node hook fails with exit 127 there (issue #39).

# Linux/macOS: the launchers run on PowerShell 7. Surface a missing pwsh
# NOW with instructions (exit 2 => stderr is shown to the user) instead of
# a raw "pwsh: command not found" at the first /watch. `command -v` is a
# shell builtin, so this spawns no process.
if [ "${OS:-}" != "Windows_NT" ]; then
  if ! command -v pwsh >/dev/null 2>&1; then
    printf '%s\n' 'watch-local: PowerShell 7 (pwsh) is required on Linux/macOS and was not found on PATH. Install it first -- macOS: "brew install powershell"; Linux: Microsoft package repo or "sudo snap install powershell --classic". All methods: https://learn.microsoft.com/powershell/scripting/install/installing-powershell' >&2
    exit 2
  fi
fi

# Mirror _lib.ps1's platform dirs WITHOUT invoking it (hook must stay
# cheap): LOCALAPPDATA on Windows, XDG data home elsewhere. Git Bash's
# test builtin accepts Windows-style paths, including backslashes.
if [ -n "${LOCALAPPDATA:-}" ]; then
  base="$LOCALAPPDATA/watch-local"
elif [ -n "${XDG_DATA_HOME:-}" ]; then
  base="$XDG_DATA_HOME/watch-local"
else
  base="$HOME/.local/share/watch-local"
fi

if [ ! -f "$base/.setup-complete" ]; then
  printf '%s\n' '/watch-local: setup never completed. Run /watch-setup before the first /watch.'
fi
exit 0
