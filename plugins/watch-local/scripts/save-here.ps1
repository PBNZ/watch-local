#requires -Version 5.1
<#
.SYNOPSIS
    Promote a watch-local job's artifacts into the current directory.

.DESCRIPTION
    Copies (or moves) a job dir from jobs_root into ./watch-local-output/<slug>/.
    For local / UNC sources, the original video is NOT copied -- instead a
    source-link.txt is written with path + size + mtime + partial sha256.
    Pass -IncludeSource to copy the source too.

    Can be invoked from /watch (via -SaveHere on watch.ps1) OR directly as
    /watch:save-here. The slash command resolves "last" via last-job.json.

.PARAMETER Slug
    Job slug (folder under jobs_root). Defaults to "last" -- read from
    %LOCALAPPDATA%\watch-local\last-job.json.

.PARAMETER Cwd
    Directory to promote into. Defaults to $PWD.

.PARAMETER IncludeSource
    Copy the local/UNC source file into the output. Default is link-only.

.PARAMETER MoveOnSave
    Move the canonical job dir rather than copy. Original under jobs_root
    is removed after the move.

.PARAMETER RemoveCanonical
    After a successful copy, prompt to remove the canonical job dir.
    Non-interactive form: pass -RemoveCanonical:$true.
#>

#region Params
[CmdletBinding()]
param(
    [string]$Slug = 'last',
    [string]$Cwd  = '',
    [switch]$IncludeSource,
    [switch]$MoveOnSave,
    [switch]$RemoveCanonical
)
#endregion

#region Init
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\_lib.ps1"

$config   = Get-WLConfig
$jobsRoot = [string]$config.jobs_root

if (-not $Cwd) { $Cwd = $PWD.Path }
if (-not (Test-Path -LiteralPath $Cwd)) {
    Write-Err "current directory does not exist: $Cwd"
    exit $script:WL_EXIT.SOURCE_BAD
}
#endregion

#region ResolveJob

if ($Slug -eq 'last') {
    if (-not (Test-Path -LiteralPath $script:WL_LAST_JOB)) {
        Write-Err "no last-job recorded. Run /watch first, then /watch:save-here."
        exit $script:WL_EXIT.SOURCE_BAD
    }
    $last = Read-UTF8 $script:WL_LAST_JOB | ConvertFrom-Json
    $Slug = [string]$last.slug
    Write-Detail "resolved 'last' -> slug $Slug"
    $lastSource = [string]$last.source
    $lastIsUrl  = [bool]$last.is_url
    $lastOrig   = $null
    if ($last.PSObject.Properties.Match('original_path').Count -gt 0) {
        $lastOrig = [string]$last.original_path
    }
} else {
    $lastSource = $null
    $lastIsUrl  = $null
    $lastOrig   = $null
}

$srcJobDir = Join-Path $jobsRoot $Slug
try {
    Assert-InsideRoot -Target $srcJobDir -Root $jobsRoot
} catch {
    Write-Err "refused: slug '$Slug' does not resolve inside jobs_root."
    exit $script:WL_EXIT.PURGE_REFUSED
}
if (-not (Test-Path -LiteralPath $srcJobDir)) {
    Write-Err "job dir not found: $srcJobDir"
    exit $script:WL_EXIT.SOURCE_BAD
}
#endregion

#region Plan

$destRoot = Join-Path $Cwd 'watch-local-output'
$destDir  = Join-Path $destRoot $Slug
New-Item -ItemType Directory -Force -Path $destRoot | Out-Null

if (Test-Path -LiteralPath $destDir) {
    Write-Warn "destination already exists: $destDir -- contents will be overwritten."
}

Write-Stage "promoting $Slug -> $destDir"
Write-Stage ("mode: " + $(if ($MoveOnSave) { 'MOVE' } else { 'COPY' }))

#endregion

#region SourceClassification

# Was this run a URL job (downloaded video lives under download/) or a
# local/UNC job (video not in job dir)?
$srcVideoInJob = $null
$dlDir = Join-Path $srcJobDir 'download'
if (Test-Path -LiteralPath $dlDir) {
    $cand = Get-ChildItem -LiteralPath $dlDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -match '^\.(mp4|mkv|webm|mov|m4v|avi|flv|wmv)$' } |
            Select-Object -First 1
    if ($cand) { $srcVideoInJob = $cand.FullName }
}

$wasUrl = $false
if ($null -ne $lastIsUrl) {
    $wasUrl = $lastIsUrl
} elseif ($srcVideoInJob) {
    $wasUrl = $true
}

#endregion

#region Transfer

try {
    if ($MoveOnSave) {
        if (Test-Path -LiteralPath $destDir) { Remove-Item -LiteralPath $destDir -Recurse -Force }
        Move-Item -LiteralPath $srcJobDir -Destination $destDir
    } else {
        if (Test-Path -LiteralPath $destDir) { Remove-Item -LiteralPath $destDir -Recurse -Force }
        Copy-Item -LiteralPath $srcJobDir -Destination $destDir -Recurse -Force
    }
} catch {
    Write-Err "transfer failed: $($_.Exception.Message)"
    exit $script:WL_EXIT.REPORT_FAILED
}

#endregion

#region SourceLink

# For local/UNC sources, drop a source-link.txt next to the artifacts.
# For URL jobs, the video lives in destDir/download/ and no link is needed.
if (-not $wasUrl) {
    $linkPath = Join-Path $destDir 'source-link.txt'
    if ($lastOrig -and (Test-Path -LiteralPath $lastOrig)) {
        try {
            $item = Get-Item -LiteralPath $lastOrig
            $type = if ($lastOrig.StartsWith('\\')) { 'unc' } else { 'local' }
            $hash = Get-PartialSHA256 -path $lastOrig -bytes 65536
            $lines = @(
                "type: $type"
                "path: $lastOrig"
                "size_bytes: $($item.Length)"
                "mtime_utc: $($item.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
                "sha256_first_64kb: $hash"
                "note: Source file left in place. Re-run with -IncludeSource to copy."
            )
            $lines | Set-Content -LiteralPath $linkPath -Encoding utf8
            Write-Stage "wrote $linkPath"
            if ($IncludeSource) {
                $copyName = $item.Name
                $copyDest = Join-Path $destDir $copyName
                Copy-Item -LiteralPath $lastOrig -Destination $copyDest -Force
                Write-Stage "included source copy: $copyDest"
            }
        } catch {
            Write-Warn "source-link.txt write failed: $($_.Exception.Message)"
        }
    } else {
        Write-Warn "original source path unknown -- skipping source-link.txt"
    }
}

#endregion

#region RemoveCanonical

# When we copied (not moved), optionally remove the canonical job dir.
if (-not $MoveOnSave -and $RemoveCanonical) {
    try {
        Assert-InsideRoot -Target $srcJobDir -Root $jobsRoot
        Remove-Item -LiteralPath $srcJobDir -Recurse -Force
        Write-Stage "canonical job dir removed."
    } catch {
        Write-Warn "remove-canonical failed: $($_.Exception.Message)"
    }
}

#endregion

Write-Output ""
Write-Output "# /watch:save-here -- promoted"
Write-Output ""
Write-Output "- **Slug:** $Slug"
Write-Output "- **Destination:** ``$(ConvertTo-DockerPath $destDir)``"
Write-Output "- **Mode:** $(if ($MoveOnSave) { 'move' } else { 'copy' })"
if (-not $wasUrl) {
    Write-Output "- **Source link:** ``$(ConvertTo-DockerPath (Join-Path $destDir 'source-link.txt'))``"
    if ($IncludeSource) { Write-Output "- **Source copied:** yes (`-IncludeSource`)" }
}
Write-Output ""
Write-Output "Use the files in ``$(ConvertTo-DockerPath $destDir)`` going forward. The canonical copy under jobs_root is $(if ($MoveOnSave -or $RemoveCanonical) { 'GONE' } else { 'still present until you purge it' })."

exit $script:WL_EXIT.OK
