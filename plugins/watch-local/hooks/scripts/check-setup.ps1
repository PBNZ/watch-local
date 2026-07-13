#requires -Version 5.1
<#
.SYNOPSIS
    SessionStart hook -- one-line nudge if setup never completed; silent otherwise.

.DESCRIPTION
    SessionStart fires on EVERY Claude Code startup/resume/clear/compact, so
    this must stay cheap: a single Test-Path on the setup marker, no child
    processes, no docker calls. Docker CLI/daemon/image state is checked by
    the real preflight (setup.ps1 -Check) that SKILL.md Step 0 runs before
    every /watch -- that is where "Docker Desktop not running" etc. surfaces,
    exactly when it matters.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

# Mirror _lib.ps1's platform dirs WITHOUT dot-sourcing it (hook must stay
# cheap): LOCALAPPDATA on Windows, XDG data home elsewhere.
$base = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'watch-local' }
        elseif ($env:XDG_DATA_HOME) { Join-Path $env:XDG_DATA_HOME 'watch-local' }
        else { Join-Path (Join-Path (Join-Path $HOME '.local') 'share') 'watch-local' }
$marker = Join-Path $base '.setup-complete'
if (-not (Test-Path -LiteralPath $marker)) {
    Write-Output "/watch-local: setup never completed. Run /watch-setup before the first /watch."
}
exit 0
