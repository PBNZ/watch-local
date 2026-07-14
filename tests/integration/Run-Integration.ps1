#requires -Version 5.1
<#
.SYNOPSIS
    Integration tests against a synthesized tiny video, run on the
    provisioned portable runtime (no Docker).

.DESCRIPTION
    1. Build a 10-second silent test mp4 with the portable ffmpeg.
    2. Run tools_run.py against it -> expect intermediate.json with N frames.
    3. Run whisper_run.py (tiny model, forced cpu/int8 for host parity)
       -> expect transcript_whisper.json (probably empty for silence).
    4. Run compare.py with no creator VTT -> expect significance == null.

    Requires: the portable runtime provisioned (/watch-setup) and the tiny
    whisper model cached (first run downloads ~75 MB).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkerDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $WorkerDir) '_lib.ps1')

$status = Test-WLRuntime
if (-not $status.ok) {
    Write-Host 'SKIP-FAIL: portable runtime not provisioned -- run /watch-setup first.' -ForegroundColor Red
    exit 1
}

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wl-int-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$workDir = Join-Path $tmpRoot 'work'
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

$failed = @()
function _Fail([string]$msg) { Write-Host "FAIL: $msg" -ForegroundColor Red; $script:failed += $msg }
function _Pass([string]$msg) { Write-Host "PASS: $msg" -ForegroundColor Green }

try {
    # 1. Build silent test video with the portable ffmpeg.
    Write-Host 'building tiny silent test mp4...'
    $ffmpeg = Get-WLFfmpegBin
    $tiny = Join-Path $workDir 'tiny.mp4'
    $orig = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $ffmpeg -hide_banner -loglevel error -y `
            -f lavfi -i 'color=c=black:s=320x240:r=10' `
            -f lavfi -i 'anullsrc=cl=mono:r=16000' `
            -t 10 -shortest -c:v libx264 -pix_fmt yuv420p -c:a aac $tiny 2>&1 | Out-Host
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $orig }
    if ($code -ne 0) { _Fail "tiny.mp4 build failed (exit $code)"; exit 1 }
    _Pass 'tiny.mp4 built'

    # 2. Run tools_run.py on tiny.mp4 as a local file.
    Write-Host 'tools_run.py against tiny.mp4...'
    $code = Invoke-WLWorker -Script 'tools_run.py' -Name 'int-tools' -EnvVars @{
        W_WORK_DIR   = $workDir
        W_SOURCE     = $tiny
        W_IS_URL     = '0'
        W_MAX_FRAMES = '4'
        W_RESOLUTION = '320'
    }
    if ($code -ne 0) { _Fail "tools_run.py failed (exit $code)"; exit 1 }
    $intermediate = Get-Content -LiteralPath (Join-Path $workDir 'intermediate.json') -Raw | ConvertFrom-Json
    if ($intermediate.frames.Count -lt 1) { _Fail "no frames produced"; exit 1 }
    if (-not $intermediate.audio_extracted) { _Fail 'audio not extracted'; exit 1 }
    _Pass "tools_run produced $($intermediate.frames.Count) frames + audio.mp3"

    # 3. Run whisper. Forced cpu/int8 so the layer passes identically on
    # GPU and CPU hosts; GPU whisper is covered by the smoke layer.
    Write-Host 'whisper_run.py on silent audio (tiny, cpu/int8)...'
    $modelsRoot = [string](Get-WLConfig).models_root
    $code = Invoke-WLWorker -Script 'whisper_run.py' -Name 'int-whisper' -EnvVars @{
        W_WORK_DIR = $workDir
        W_MODEL    = 'tiny'
        W_DEVICE   = 'cpu'
        W_COMPUTE  = 'int8'
        HF_HOME    = (Join-Path $modelsRoot 'hf-cache')
    }
    if ($code -ne 0) { _Fail "whisper_run failed (exit $code)"; exit 1 }
    $tr = Get-Content -LiteralPath (Join-Path $workDir 'transcript_whisper.json') -Raw | ConvertFrom-Json
    _Pass "whisper produced $($tr.segments.Count) segments (silent audio expected ~0)"

    # 4. compare.py with no creator VTT.
    Write-Host 'compare.py whisper-only...'
    $code = Invoke-WLWorker -Script 'compare.py' -Name 'int-compare' -EnvVars @{
        W_WORK_DIR     = $workDir
        W_WHISPER_JSON = (Join-Path $workDir 'transcript_whisper.json')
        W_OUT_JSON     = (Join-Path $workDir 'comparison.json')
    }
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
