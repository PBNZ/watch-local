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

    Backed by worker/stills.py running natively on the portable runtime.

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

if ($video) {
    $srcVideo = $video.FullName
} else {
    # Local/UNC job: no video under download/. Recover the original source
    # path from the job's own job.json (written by watch.ps1), falling back
    # to last-job.json for jobs that predate job.json.
    $origPath = $null
    $jobJson = Join-Path $jobDir 'job.json'
    if (Test-Path -LiteralPath $jobJson) {
        try { $origPath = [string](Read-UTF8 $jobJson | ConvertFrom-Json).original_path } catch { }
    }
    if (-not $origPath -and (Test-Path -LiteralPath $script:WL_LAST_JOB)) {
        try {
            $last = Read-UTF8 $script:WL_LAST_JOB | ConvertFrom-Json
            if ([string]$last.slug -eq $Slug) { $origPath = [string]$last.original_path }
        } catch { }
    }
    # UNC sources work directly now: ffmpeg runs natively on the host and
    # reads \\server\share paths itself, so no staged copy is needed.
    if ($origPath -and (Test-Path -LiteralPath $origPath)) {
        $srcVideo = $origPath
        Write-Stage "reading original source directly ($origPath)"
    } else {
        if ($origPath) {
            Write-Err "this job's original source is no longer at $origPath."
        } else {
            Write-Err "no downloaded source video under $dlDir and no recorded original path."
        }
        Write-Err "grab-frames needs the source video: URL jobs keep it on disk; for"
        Write-Err "local jobs the original file must still exist at its recorded path."
        Write-Err "Re-run /watch with -Screenshots `"MM:SS,...`", or -SaveHere -IncludeSource."
        exit $script:WL_EXIT.SOURCE_BAD
    }
}
#endregion

#region Extract
Assert-WLRuntimeReady

# NVDEC decode when the detected GPU supports it (same env as /watch).
$gpuInfo = Get-WLGpuInfo -Config $config
$toolsGpuEnv = Get-WLToolsWorkerEnv -Gpu $gpuInfo

$shotsDir = Join-Path $jobDir 'screenshots'
New-Item -ItemType Directory -Force -Path $shotsDir | Out-Null

$resLabel = if ($Resolution -gt 0) { "$Resolution px wide" } else { 'native resolution' }
Write-Stage "extracting stills at $resLabel for: $Screenshots"

$stillEnv = $toolsGpuEnv + @{
    W_WORK_DIR  = $jobDir
    W_VIDEO     = $srcVideo
    W_SHOTS     = $Screenshots
    W_OUT_DIR   = $shotsDir
    W_STILL_RES = $Resolution
}
$code = Invoke-WLWorker -Script 'stills.py' -EnvVars $stillEnv -Name 'grab-frames'
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
    Write-Output "- ``$(ConvertTo-WLSlashPath $f.FullName)``"
}
if ($copied.Count -gt 0) {
    Write-Output ""
    Write-Output "Also copied to ``$(ConvertTo-WLSlashPath $OutDir)``."
}
#endregion

exit $script:WL_EXIT.OK
