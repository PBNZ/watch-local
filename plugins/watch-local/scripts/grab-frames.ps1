#requires -Version 5.1
<#
.SYNOPSIS
    Pull native-resolution still screenshots from an already-watched job.

.DESCRIPTION
    The survey frames produced by /watch are downscaled to -Resolution, but
    the best-quality source video is kept on disk. When you want a specific
    moment as a crisp screenshot -- or frames to build follow-up content from
    -- this extracts those exact timestamps at native resolution (or a width
    you choose) from the job's downloaded source.

    Backed by worker/stills.py running in the tools image via `docker run`.

.PARAMETER Slug
    Job slug (folder under jobs_root). Default "last" -> read from
    %LOCALAPPDATA%\watch-local\last-job.json.

.PARAMETER Screenshots
    Comma-separated timestamps. Each may be SS, MM:SS, or HH:MM:SS.
    Example: "10:00,22:40,34:05"

.PARAMETER Resolution
    Output width in px. 0 (default) = native source resolution.

.PARAMETER OutDir
    Optional host dir to ALSO copy the stills into (e.g. a project folder).
    Stills are always written to <job>\screenshots\ first.
#>

#region Params
[CmdletBinding()]
param(
    [string]$Slug = 'last',
    [Parameter(Mandatory)][string]$Screenshots,
    [int]$Resolution = 0,
    [string]$OutDir = '',
    [switch]$VerboseLog
)
#endregion

#region Init
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\_lib.ps1"
if ($VerboseLog) { Enable-VerboseLog }

$workerDir = $PSScriptRoot + '\worker'
$config    = Get-WLConfig
$jobsRoot  = [string]$config.jobs_root
#endregion

#region ResolveJob
if ($Slug -eq 'last') {
    if (-not (Test-Path -LiteralPath $script:WL_LAST_JOB)) {
        Write-Err "no last-job recorded. Run /watch first, then /watch:grab-frames."
        exit $script:WL_EXIT.SOURCE_BAD
    }
    $last = Read-UTF8 $script:WL_LAST_JOB | ConvertFrom-Json
    $Slug = [string]$last.slug
    Write-Detail "resolved 'last' -> slug $Slug"
}

$jobDir = Join-Path $jobsRoot $Slug
try {
    Assert-InsideRoot -Target $jobDir -Root $jobsRoot
} catch {
    Write-Err "refused: slug '$Slug' does not resolve inside jobs_root."
    exit $script:WL_EXIT.PURGE_REFUSED
}
if (-not (Test-Path -LiteralPath $jobDir)) {
    Write-Err "job dir not found: $jobDir"
    exit $script:WL_EXIT.SOURCE_BAD
}
#endregion

#region FindSource
$dlDir = Join-Path $jobDir 'download'
$video = $null
if (Test-Path -LiteralPath $dlDir) {
    $video = Get-ChildItem -LiteralPath $dlDir -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Extension -match '^\.(mp4|mkv|webm|mov|m4v|avi|flv|wmv)$' } |
             Select-Object -First 1
}
if (-not $video) {
    Write-Err "no downloaded source video found under $dlDir."
    Write-Err "grab-frames works on URL jobs (video kept on disk). For local/UNC"
    Write-Err "sources the original file is not copied -- re-run /watch with -IncludeSource,"
    Write-Err "or point grab-frames at a job that downloaded its source."
    exit $script:WL_EXIT.SOURCE_BAD
}
$containerVideo = "/work/download/$($video.Name)"
#endregion

#region Extract
Assert-DockerReady

$shotsDir = Join-Path $jobDir 'screenshots'
New-Item -ItemType Directory -Force -Path $shotsDir | Out-Null

$resLabel = if ($Resolution -gt 0) { "$Resolution px wide" } else { 'native resolution' }
Write-Stage "extracting stills at $resLabel for: $Screenshots"

$runArgs = @(
    '-e', "W_VIDEO=$containerVideo",
    '-e', "W_SHOTS=$Screenshots",
    '-e', 'W_OUT_DIR=/work/screenshots',
    '-e', "W_STILL_RES=$Resolution",
    '-v', "$(ConvertTo-DockerPath $jobDir):/work",
    '-v', "$(ConvertTo-DockerPath $workerDir):/app:ro",
    $script:WL_IMG_TOOLS, 'python3', '/app/stills.py'
)
$code = Invoke-WLRun $runArgs
if ($code -ne 0) {
    Write-Err "still extraction failed (exit $code)."
    exit $script:WL_EXIT.TOOLS_FAILED
}

# @() forces array shape so .Count works even for a single still (StrictMode).
$produced = @(Get-ChildItem -LiteralPath $shotsDir -File -ErrorAction SilentlyContinue |
              Where-Object { $_.Extension -eq '.jpg' } | Sort-Object Name)
#endregion

#region CopyOut
$copied = @()
if ($OutDir) {
    try {
        $destRoot = (Resolve-ConfigPath $OutDir)
        foreach ($f in $produced) {
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $destRoot $f.Name) -Force
            $copied += (Join-Path $destRoot $f.Name)
        }
    } catch {
        Write-Warn "could not copy to -OutDir '$OutDir': $($_.Exception.Message)"
    }
}
#endregion

#region Report
Write-Output ""
Write-Output "# /watch:grab-frames -- native stills"
Write-Output ""
Write-Output "- **Slug:** $Slug"
Write-Output "- **Resolution:** $resLabel"
Write-Output "- **Count:** $($produced.Count)"
Write-Output ""
Write-Output "Stills (Read these paths to view):"
foreach ($f in $produced) {
    Write-Output "- ``$(ConvertTo-DockerPath $f.FullName)``"
}
if ($copied.Count -gt 0) {
    Write-Output ""
    Write-Output "Also copied to ``$(ConvertTo-DockerPath $OutDir)``."
}
#endregion

exit $script:WL_EXIT.OK
