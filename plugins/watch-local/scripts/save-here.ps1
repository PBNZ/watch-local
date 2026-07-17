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
    After a successful copy, remove the canonical job dir. Interactive
    hosts are asked to confirm ([y/N]) first; non-interactive hosts
    (redirected stdin, e.g. agent-driven runs) proceed without a prompt.
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
    $Slug = [string](Get-WLObjectProp $last 'slug')
    if (-not $Slug) {
        Write-Err "last-job.json has no slug. Run /watch first, then /watch:save-here."
        exit $script:WL_EXIT.SOURCE_BAD
    }
    Write-Detail "resolved 'last' -> slug $Slug"
}

# Slugs are bare 16-hex dir names. Reject separators / '..' outright: the
# slug is also used to build the DESTINATION dir (which gets overwritten),
# so a traversal slug could redirect the overwrite outside watch-local-output
# even when the source side still resolves inside jobs_root.
if ($Slug -match '[\\/]' -or $Slug -match '\.\.') {
    Write-Err "refused: slug '$Slug' contains path separators or '..'."
    exit $script:WL_EXIT.PURGE_REFUSED
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

# Recover source metadata (is_url / original_path) for ANY slug -- watch.ps1
# always invokes us with the concrete slug, so 'last'-only recovery dropped
# source-link.txt / -IncludeSource on the primary path. The job's own
# job.json is authoritative; last-job.json (when it refers to this slug)
# covers jobs that predate job.json. Every field is read through the
# StrictMode-safe Get-WLObjectProp: older or hand-edited files may lack any
# of them, and that must degrade gracefully, not terminate.
$lastIsUrl = $null
$lastOrig  = $null

function script:Read-WLJobMeta([string]$jsonPath, [string]$requireSlug) {
    if (-not (Test-Path -LiteralPath $jsonPath)) { return }
    try {
        $meta = Read-UTF8 $jsonPath | ConvertFrom-Json
    } catch {
        Write-Detail "unreadable job metadata ${jsonPath}: $($_.Exception.Message)"
        return
    }
    if ($requireSlug -and ([string](Get-WLObjectProp $meta 'slug') -ne $requireSlug)) { return }
    if ($null -eq $script:lastIsUrl) {
        $rawIsUrl = Get-WLObjectProp $meta 'is_url'
        if ($null -ne $rawIsUrl) { $script:lastIsUrl = [bool]$rawIsUrl }
    }
    if (-not $script:lastOrig) {
        $rawOrig = Get-WLObjectProp $meta 'original_path'
        if ($rawOrig) { $script:lastOrig = [string]$rawOrig }
    }
}

Read-WLJobMeta (Join-Path $srcJobDir 'job.json') ''
Read-WLJobMeta $script:WL_LAST_JOB $Slug
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
# The report at the bottom states only what actually happened -- track it.
$sourceLinkWritten = $false
$sourceCopied      = $false
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
            $sourceLinkWritten = $true
            Write-Stage "wrote $linkPath"
            if ($IncludeSource) {
                $copyName = $item.Name
                $copyDest = Join-Path $destDir $copyName
                Copy-Item -LiteralPath $lastOrig -Destination $copyDest -Force
                $sourceCopied = $true
                Write-Stage "included source copy: $copyDest"
            }
        } catch {
            Write-Warn "source-link.txt / source copy failed: $($_.Exception.Message)"
        }
    } else {
        Write-Warn "original source path unknown -- skipping source-link.txt"
    }
}

#endregion

#region RemoveCanonical

# When we copied (not moved), optionally remove the canonical job dir.
# Interactive hosts get the confirmation prompt the docs promise; a
# non-interactive host (the agent-driven path) proceeds directly -- the
# copy above already succeeded, so artifacts exist at the destination.
$canonicalRemoved = $MoveOnSave.IsPresent
if (-not $MoveOnSave -and $RemoveCanonical) {
    $proceed = $true
    if (-not [Console]::IsInputRedirected) {
        [Console]::Error.Write("Remove the canonical job dir $srcJobDir? [y/N]: ")
        $reply = [Console]::ReadLine()
        $proceed = ($null -ne $reply -and $reply.Trim() -match '^[Yy]$')
    }
    if ($proceed) {
        try {
            Assert-InsideRoot -Target $srcJobDir -Root $jobsRoot
            Remove-Item -LiteralPath $srcJobDir -Recurse -Force
            $canonicalRemoved = $true
            Write-Stage "canonical job dir removed."
        } catch {
            Write-Warn "remove-canonical failed: $($_.Exception.Message)"
        }
    } else {
        Write-Stage "canonical job dir kept."
    }
}

#endregion

Write-Output ""
Write-Output "# /watch:save-here -- promoted"
Write-Output ""
Write-Output "- **Slug:** $Slug"
Write-Output "- **Destination:** ``$(ConvertTo-WLSlashPath $destDir)``"
Write-Output "- **Mode:** $(if ($MoveOnSave) { 'move' } else { 'copy' })"
if (-not $wasUrl) {
    if ($sourceLinkWritten) {
        Write-Output "- **Source link:** ``$(ConvertTo-WLSlashPath (Join-Path $destDir 'source-link.txt'))``"
    } else {
        Write-Output "- **Source link:** not written (original source path unknown or unreadable)"
    }
    if ($IncludeSource) {
        Write-Output "- **Source copied:** $(if ($sourceCopied) { 'yes (``-IncludeSource``)' } else { 'NO -- source path unknown or copy failed' })"
    }
}
Write-Output ""
Write-Output "Use the files in ``$(ConvertTo-WLSlashPath $destDir)`` going forward. The canonical copy under jobs_root is $(if ($canonicalRemoved) { 'GONE' } else { 'still present until you purge it' })."

exit $script:WL_EXIT.OK
