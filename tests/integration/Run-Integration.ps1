#requires -Version 5.1
<#
.SYNOPSIS
    Docker-backed integration tests against a synthesized tiny video.

.DESCRIPTION
    1. Build a 10-second silent test mp4 inside the tools container.
    2. Run tools_run.py against it -> expect intermediate.json with N frames.
    3. Run whisper_run.py -> expect transcript_whisper.json (probably empty for silence).
    4. Run compare.py with no creator VTT -> expect significance == null.
    5. Run compare.py with synthesized creator VTT == whisper transcript
       -> expect significance == match.

    Requires: docker, watch-local/tools:1 image, watch-local/whisper:cu128 image.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ComposeFile,
    [Parameter(Mandatory)][string]$WorkerDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $WorkerDir) '_lib.ps1')

# Native docker stderr otherwise becomes a terminating error under PS 7's
# StrictMode+Stop combo. Wrap every docker invocation in this helper which
# lowers EAP to Continue for the duration of the call. Pipe output through
# Out-Host so the function's pipeline carries ONLY the exit code -- a bare
# `return $LASTEXITCODE` would otherwise interleave docker's stdout in the
# caller's $code, breaking `$code -ne 0` comparisons.
function _Docker {
    param([string[]]$ArgList)
    $orig = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker @ArgList 2>&1 | Out-Host
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $orig
    }
}

$tmpRoot = Join-Path $env:TEMP ('wl-int-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$workDir = Join-Path $tmpRoot 'work'
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

$failed = @()
function _Fail([string]$msg) { Write-Host "FAIL: $msg" -ForegroundColor Red; $script:failed += $msg }
function _Pass([string]$msg) { Write-Host "PASS: $msg" -ForegroundColor Green }

try {
    # 1. Build silent test video.
    # All stages use plain `docker run` with image tags -- compose run
    # deadlocks at container-start on WSL2 (see Invoke-WLRun in _lib.ps1).
    Write-Host 'building tiny silent test mp4...'
    $code = _Docker @('run','--rm',
        '-v',"$(ConvertTo-DockerPath $workDir):/work",
        $script:WL_IMG_TOOLS,'ffmpeg','-hide_banner','-loglevel','error','-y',
        '-f','lavfi','-i','color=c=black:s=320x240:r=10',
        '-f','lavfi','-i','anullsrc=cl=mono:r=16000',
        '-t','10','-shortest','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac','/work/tiny.mp4')
    if ($code -ne 0) { _Fail "tiny.mp4 build failed (exit $code)"; exit 1 }
    _Pass 'tiny.mp4 built'

    # 2. Run tools_run.py on tiny.mp4 as a local file.
    Write-Host 'tools_run.py against tiny.mp4...'
    $code = _Docker @('run','--rm',
        '-e','W_SOURCE=/input/tiny.mp4',
        '-e','W_IS_URL=0',
        '-e','W_MAX_FRAMES=4',
        '-e','W_RESOLUTION=320',
        '-v',"$(ConvertTo-DockerPath $workDir):/work",
        '-v',"$(ConvertTo-DockerPath $workDir):/input:ro",
        '-v',"$(ConvertTo-DockerPath $WorkerDir):/app:ro",
        $script:WL_IMG_TOOLS,'python3','/app/tools_run.py')
    if ($code -ne 0) { _Fail "tools_run.py failed (exit $code)"; exit 1 }
    $intermediate = Get-Content -LiteralPath (Join-Path $workDir 'intermediate.json') -Raw | ConvertFrom-Json
    if ($intermediate.frames.Count -lt 1) { _Fail "no frames produced"; exit 1 }
    if (-not $intermediate.audio_extracted) { _Fail 'audio not extracted'; exit 1 }
    _Pass "tools_run produced $($intermediate.frames.Count) frames + audio.mp3"

    # 3. Run whisper.
    Write-Host 'whisper_run.py on silent audio...'
    $code = _Docker (@('run','--rm') + $script:WL_WHISPER_RUN_FLAGS + @(
        '-e','W_MODEL=tiny',
        '-v',"$(ConvertTo-DockerPath $workDir):/work",
        '-v',"$(ConvertTo-DockerPath (Join-Path $env:LOCALAPPDATA 'watch-local\models')):/models",
        '-v',"$(ConvertTo-DockerPath $WorkerDir):/app:ro",
        $script:WL_IMG_WHISPER,'python3','/app/whisper_run.py'))
    if ($code -ne 0) { _Fail "whisper_run failed (exit $code)"; exit 1 }
    $tr = Get-Content -LiteralPath (Join-Path $workDir 'transcript_whisper.json') -Raw | ConvertFrom-Json
    _Pass "whisper produced $($tr.segments.Count) segments (silent audio expected ~0)"

    # 4. compare.py with no creator VTT.
    Write-Host 'compare.py whisper-only...'
    $code = _Docker @('run','--rm',
        '-e','W_WHISPER_JSON=/work/transcript_whisper.json',
        '-e','W_OUT_JSON=/work/comparison.json',
        '-v',"$(ConvertTo-DockerPath $workDir):/work",
        '-v',"$(ConvertTo-DockerPath $WorkerDir):/app:ro",
        $script:WL_IMG_TOOLS,'python3','/app/compare.py')
    if ($code -ne 0) { _Fail "compare.py (whisper-only) failed (exit $code)"; exit 1 }
    $cmp = Get-Content -LiteralPath (Join-Path $workDir 'comparison.json') -Raw | ConvertFrom-Json
    if ($null -ne $cmp.significance) { _Fail "expected null significance, got $($cmp.significance)"; exit 1 }
    _Pass 'compare.py whisper-only path OK'

} finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed.Count -eq 0) {
    Write-Host 'INTEGRATION: ALL PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host "INTEGRATION: $($failed.Count) failures" -ForegroundColor Red
    exit 1
}
