#!/usr/bin/env node
// SessionStart hook -- one-line nudge if setup never completed, and a clear
// error when PowerShell 7 is missing on Linux/macOS (it is not preinstalled
// there, and the plugin's launchers need it).
//
// SessionStart fires on EVERY Claude Code startup/resume/clear/compact, so
// this must stay cheap: filesystem checks only, no child processes. Node is
// used (not PowerShell) precisely so this hook can run -- and explain the
// fix -- on machines that don't have pwsh yet; Claude Code itself runs on
// Node, so it is always present.

import { existsSync } from 'node:fs';
import { join, delimiter } from 'node:path';
import { homedir } from 'node:os';
import process from 'node:process';

const isWindows = process.platform === 'win32';

// Linux/macOS: the launchers run on PowerShell 7. Surface a missing pwsh
// NOW with instructions (exit 2 => stderr is shown to the user) instead of
// a raw "pwsh: command not found" at the first /watch.
if (!isWindows) {
  const hasPwsh = (process.env.PATH || '')
    .split(delimiter)
    .filter(Boolean)
    .some((dir) => existsSync(join(dir, 'pwsh')));
  if (!hasPwsh) {
    process.stderr.write(
      'watch-local: PowerShell 7 (pwsh) is required on Linux/macOS and was not found on PATH. ' +
      'Install it first -- macOS: "brew install powershell"; Linux: Microsoft package repo or ' +
      '"sudo snap install powershell --classic". All methods: ' +
      'https://learn.microsoft.com/powershell/scripting/install/installing-powershell\n',
    );
    process.exit(2);
  }
}

// Mirror _lib.ps1's platform dirs WITHOUT invoking it (hook must stay
// cheap): LOCALAPPDATA on Windows, XDG data home elsewhere.
const base = process.env.LOCALAPPDATA
  ? join(process.env.LOCALAPPDATA, 'watch-local')
  : process.env.XDG_DATA_HOME
    ? join(process.env.XDG_DATA_HOME, 'watch-local')
    : join(homedir(), '.local', 'share', 'watch-local');

if (!existsSync(join(base, '.setup-complete'))) {
  process.stdout.write('/watch-local: setup never completed. Run /watch-setup before the first /watch.\n');
}
process.exit(0);
