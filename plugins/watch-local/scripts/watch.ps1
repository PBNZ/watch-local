#requires -Version 5.1
<#
.SYNOPSIS
    /watch host orchestrator -- runs the tools + whisper + compare pipeline.

.DESCRIPTION
    Pipeline:
        1. Slugify source -> per-job dir under jobs_root.
        2. Resolve source (URL / local / UNC -> stage).
        3. Disk-space pre-flight against jobs_root + staging_root.
        4. tools container: download, frames, audio, classify subs.
        5. whisper container: transcribe audio (ALWAYS).
        6. tools container: compare creator subs vs whisper transcript.
        7. Pick primary transcript per provenance rules.
        8. Emit markdown report. Translate paths to host C:/... form.
        9. Optional: promote to CWD via -SaveHere. Cleanup if asked.

    Exit codes documented in _lib.ps1 ($WL_EXIT).

.EXAMPLE
    watch.ps1 -Source "https://www.youtube.com/watch?v=abc"
.EXAMPLE
    watch.ps1 -Source "C:/Videos/recording.mp4" -Start 0:30 -End 1:30
.EXAMPLE
    watch.ps1 -Source "\\nas\share\talk.mkv" -SaveHere -Model medium
#>

#region Params
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [int]$MaxFrames = 80,
    [int]$Resolution = 768,
    [int]$MaxHeight = 0,
    [string]$Screenshots = '',
    [int]$StillResolution = 0,
    [Nullable[double]]$Fps,
    [string]$Start,
    [string]$End,
    [ValidateSet('large-v3','medium','small','base','tiny')]
    [string]$Model,
    [string]$Language,
    [string]$OutDir,
    [switch]$SaveHere,
    [switch]$IncludeSource,
    [switch]$MoveOnSave,
    [switch]$Cleanup,
    [switch]$NoCompare,
    [ValidateSet('creator','whisper')]
    [string]$PrimaryOverride,
    [switch]$DryRun,
    [switch]$VerboseLog
)
#endregion

#region Init

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\_lib.ps1"
if ($VerboseLog) { Enable-VerboseLog }

if ($OutDir -and $SaveHere) {
    Write-Err "-OutDir and -SaveHere are mutually exclusive."
    exit $script:WL_EXIT.FLAG_CONFLICT
}

$config = Get-WLConfig
if (-not $Model)    { $Model    = [string]$config.default_model }
if (-not $Language) { $Language = [string]$config.default_language }

$jobsRoot       = [string]$config.jobs_root
$modelsDir      = [string]$config.models_root
$stagingRoot    = [string]$config.staging_root
$minFreeJobs    = [double]$config.min_free_gb_jobs
$minFreeStaging = [double]$config.min_free_gb_staging
$minFreeModels  = [double]$config.min_free_gb_models

$pluginRoot  = Split-Path -Parent $PSScriptRoot
$dockerDir   = Join-Path $pluginRoot 'docker'
$composeFile = Join-Path $dockerDir 'docker-compose.yml'
$workerDir   = $PSScriptRoot + '\worker'

foreach ($p in @($jobsRoot, $modelsDir, $stagingRoot)) {
    if (-not (Test-Path -LiteralPath $p)) {
        New-Item -ItemType Directory -Force -Path $p | Out-Null
    }
}

if ($null -ne $config.auto_cleanup_days) {
    try {
        $cutoff = (Get-Date).AddDays(-[int]$config.auto_cleanup_days)
        $oldJobs = @(Get-ChildItem -LiteralPath $jobsRoot -Directory -ErrorAction SilentlyContinue |
                     Where-Object { $_.LastWriteTime -lt $cutoff })
        if ($oldJobs.Count -gt 0) {
            Write-Warn ("{0} job dir(s) older than {1} days under {2}. To clean: powershell -File `"{3}\setup.ps1`" -PurgeJobs -OlderThanDays {1}" -f `
                $oldJobs.Count, [int]$config.auto_cleanup_days, $jobsRoot, $PSScriptRoot)
        }
    } catch {
        Write-Detail "auto_cleanup warning skipped: $($_.Exception.Message)"
    }
}

#endregion

#region Resolve

$slug = New-JobSlug -source $Source

if ($OutDir) {
    try {
        $workDir = (Resolve-ConfigPath $OutDir)
    } catch {
        Write-Err "cannot use -OutDir '$OutDir': $($_.Exception.Message)"
        exit $script:WL_EXIT.SOURCE_BAD
    }
} else {
    $workDir = Join-Path $jobsRoot $slug
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
}
Write-Detail "work dir: $workDir"

$isUrl = $false
$inputMountHost = $null
$inputMountContainer = '/input'
$containerSource = $Source
$stagedDir = $null
$stagedFile = $null
$originalSourcePath = $null

if ($Source -match '^https?://') {
    $isUrl = $true
    Write-Stage "source is URL"
} elseif ($Source.StartsWith('\\')) {
    Write-Stage "source is UNC -- staging locally first"
    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Err "UNC source not reachable: $Source"
        exit $script:WL_EXIT.SOURCE_BAD
    }
    try {
        $jobStage = Join-Path $stagingRoot $slug
        New-Item -ItemType Directory -Force -Path $jobStage | Out-Null
        $fname = Split-Path -Leaf $Source
        $stagedDir = $jobStage
        $stagedFile = Join-Path $jobStage $fname
        $srcItem = Get-Item -LiteralPath $Source
        $sizeMB = [math]::Round(($srcItem.Length / 1MB), 1)
        if ($sizeMB -gt 1024) { Write-Warn "source is $sizeMB MB -- copy may take a while" }
        Copy-Item -LiteralPath $Source -Destination $stagedFile -Force
        $inputMountHost = $jobStage
        $containerSource = "$inputMountContainer/$fname"
        $originalSourcePath = $Source
    } catch {
        Write-Err "UNC stage failed: $($_.Exception.Message)"
        exit $script:WL_EXIT.UNC_COPY_FAILED
    }
} else {
    try {
        $resolved = Resolve-Path -LiteralPath $Source -ErrorAction Stop
        $item = Get-Item -LiteralPath $resolved
    } catch {
        Write-Err "local source not found: $Source"
        exit $script:WL_EXIT.SOURCE_BAD
    }
    $inputMountHost = $item.Directory.FullName
    $containerSource = "$inputMountContainer/$($item.Name)"
    $originalSourcePath = $item.FullName
    Write-Stage "source is local file -- mounting parent dir read-only"
}

#endregion

#region DiskCheck

function Get-DownloadEstimateMB {
    param([string]$Url)
    # Native command stderr under StrictMode+Stop becomes a terminating
    # error. Lower preference inside this helper so we can return null
    # cleanly when yt-dlp probe doesn't yield a size.
    $orig = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        # Plain `docker run` (not `docker compose run`) -- compose run
        # deadlocks at container-start on WSL2. stdout captured here for
        # the JSON estimate, so this can't go through Invoke-WLRun (which
        # routes stdout to Out-Host).
        $out = & docker run --rm --name "watch-local-probe-$(Get-Random -Maximum 99999)" `
            -e "W_URL=$Url" `
            -e "W_MAX_HEIGHT=$MaxHeight" `
            -v "$(ConvertTo-DockerPath $workerDir):/app:ro" `
            $script:WL_IMG_TOOLS python3 /app/disk.py 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
        $obj = $out | Out-String | ConvertFrom-Json
        if ($obj.bytes) { return [math]::Round($obj.bytes * 1.3 / 1MB, 0) }
        return $null
    } catch {
        Write-Detail "download estimate failed: $($_.Exception.Message)"
        return $null
    } finally {
        $ErrorActionPreference = $orig
    }
}

$estimateMB = 100
if ($DryRun) {
    Write-Stage "DryRun: skipping yt-dlp probe."
} elseif ($isUrl) {
    Write-Stage "estimating download size (yt-dlp probe)..."
    $dlMB = Get-DownloadEstimateMB -Url $Source
    if ($dlMB) {
        $estimateMB += [int]$dlMB
        Write-Stage "estimated job size: $estimateMB MB"
    } else {
        Write-Warn "yt-dlp probe gave no size hint -- using pessimistic 500 MB."
        $estimateMB += 500
    }
} elseif ($stagedFile) {
    $estimateMB += [int]([math]::Round((Get-Item -LiteralPath $stagedFile).Length / 1MB, 0))
}

$needGbJobs = [math]::Ceiling($estimateMB / 1024.0) + $minFreeJobs
$freeJobsGB = Get-DriveFreeGB $jobsRoot
if ($null -ne $freeJobsGB -and $freeJobsGB -lt $needGbJobs) {
    Write-Err ("not enough free space on jobs_root drive: {0} GB free, need {1} GB (estimate {2} MB + {3} GB reserve)." -f $freeJobsGB, $needGbJobs, $estimateMB, $minFreeJobs)
    Write-Err ("Move jobs_root to another drive: powershell -File `"{0}\setup.ps1`" -SetJobsRoot D:\watch-jobs" -f $PSScriptRoot)
    exit $script:WL_EXIT.NO_DISK
}
if ($stagedDir) {
    $needGbStage = [math]::Ceiling($estimateMB / 1024.0) + $minFreeStaging
    $freeStageGB = Get-DriveFreeGB $stagingRoot
    if ($null -ne $freeStageGB -and $freeStageGB -lt $needGbStage) {
        Write-Err "not enough free space on staging drive for UNC copy: $freeStageGB GB free, need $needGbStage GB."
        exit $script:WL_EXIT.NO_DISK
    }
}
$modelHasFiles = $false
if (Test-Path -LiteralPath $modelsDir) {
    $modelHasFiles = (Get-ChildItem -LiteralPath $modelsDir -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1) -ne $null
}
if (-not $modelHasFiles) {
    $freeModelsGB = Get-DriveFreeGB $modelsDir
    if ($null -ne $freeModelsGB -and $freeModelsGB -lt $minFreeModels) {
        Write-Err "not enough free space for whisper model first-download: $freeModelsGB GB free, need $minFreeModels GB."
        exit $script:WL_EXIT.NO_DISK
    }
}

#endregion

#region Tools

if (-not $DryRun) { Assert-DockerReady }

$envArgs = @(
    '-e', "W_SOURCE=$containerSource",
    '-e', ("W_IS_URL=" + $(if ($isUrl) { '1' } else { '0' })),
    '-e', "W_MAX_FRAMES=$MaxFrames",
    '-e', "W_RESOLUTION=$Resolution",
    '-e', "W_MAX_HEIGHT=$MaxHeight"
)
if ($null -ne $Fps) { $envArgs += @('-e', "W_FPS=$Fps") }
if ($Start)         { $envArgs += @('-e', "W_START=$Start") }
if ($End)           { $envArgs += @('-e', "W_END=$End") }

$mountArgs = @(
    '-v', "$(ConvertTo-DockerPath $workDir):/work",
    '-v', "$(ConvertTo-DockerPath $workerDir):/app:ro"
)
if ($inputMountHost) {
    $mountArgs += @('-v', "$(ConvertTo-DockerPath $inputMountHost):${inputMountContainer}:ro")
}

$toolsRunArgs = $envArgs + $mountArgs + @($script:WL_IMG_TOOLS, 'python3', '/app/tools_run.py')

Write-Stage "running tools container..."
if ($DryRun) {
    Write-Stage "DRY RUN: docker run --rm $($toolsRunArgs -join ' ')"
} else {
    $code = Invoke-WLRun $toolsRunArgs -Name 'tools'
    if ($code -ne 0) {
        Write-Err "tools container failed (exit $code)"
        exit $script:WL_EXIT.TOOLS_FAILED
    }
}

$intermediatePath = Join-Path $workDir 'intermediate.json'
if (-not $DryRun -and -not (Test-Path -LiteralPath $intermediatePath)) {
    Write-Err "tools container did not write intermediate.json"
    exit $script:WL_EXIT.TOOLS_FAILED
}
$intermediate = if ($DryRun) { $null } else {
    Read-UTF8 $intermediatePath | ConvertFrom-Json
}

#endregion

#region Whisper

$whisperTranscript = $null
$whisperOk = $false
$skipWhisperReason = $null

if ($DryRun) {
    $skipWhisperReason = 'DryRun'
} elseif (-not $intermediate.audio_extracted) {
    $skipWhisperReason = 'no audio track in source'
    Write-Warn "skipping whisper -- $skipWhisperReason"
} else {
    Write-Stage "running whisper container on GPU (model: $Model)..."
    $whisperEnv = @('-e', "W_MODEL=$Model")
    if ($Language) { $whisperEnv += @('-e', "W_LANGUAGE=$Language") }
    $whisperMounts = @(
        '-v', "$(ConvertTo-DockerPath $workDir):/work",
        '-v', "$(ConvertTo-DockerPath $modelsDir):/models",
        '-v', "$(ConvertTo-DockerPath $workerDir):/app:ro"
    )
    $whisperRunArgs = $script:WL_WHISPER_RUN_FLAGS + $whisperEnv + $whisperMounts + @($script:WL_IMG_WHISPER, 'python3', '/app/whisper_run.py')
    $code = Invoke-WLRun $whisperRunArgs -Name 'whisper'
    if ($code -eq 0) {
        $whisperTranscript = Read-UTF8 (Join-Path $workDir 'transcript_whisper.json') | ConvertFrom-Json
        $whisperOk = $true
    } else {
        $skipWhisperReason = "whisper container exited $code"
        Write-Warn "whisper container failed (exit $code) -- emitting partial report"
    }
}

#endregion

#region Compare

$comparison = $null

if ($DryRun) {
    # nothing
} elseif ($NoCompare) {
    Write-Detail "compare skipped (-NoCompare)"
} elseif (-not $whisperOk) {
    Write-Detail "compare skipped: no whisper output"
} else {
    $creatorVttContainer = $null
    if ($intermediate.subtitle_path) { $creatorVttContainer = [string]$intermediate.subtitle_path }
    $cmpEnv = @(
        '-e', 'W_WHISPER_JSON=/work/transcript_whisper.json',
        '-e', 'W_OUT_JSON=/work/comparison.json'
    )
    if ($creatorVttContainer) { $cmpEnv += @('-e', "W_CREATOR_VTT=$creatorVttContainer") }
    $cmpMounts = @(
        '-v', "$(ConvertTo-DockerPath $workDir):/work",
        '-v', "$(ConvertTo-DockerPath $workerDir):/app:ro"
    )
    Write-Stage "running comparison stage..."
    $cmpRunArgs = $cmpEnv + $cmpMounts + @($script:WL_IMG_TOOLS, 'python3', '/app/compare.py')
    $code = Invoke-WLRun $cmpRunArgs -Name 'compare'
    if ($code -eq 0) {
        $comparison = Read-UTF8 (Join-Path $workDir 'comparison.json') | ConvertFrom-Json
    } else {
        Write-Warn "compare stage failed (exit $code)"
    }
}

#endregion

#region Picking

$haveCreator = $false
$haveWhisper = $false
$creatorSegments = $null
$whisperSegments = $null

if (-not $DryRun) {
    if ($intermediate.subtitle_path) {
        $vttHost = ConvertTo-HostPath -ContainerPath ([string]$intermediate.subtitle_path) -WorkHost $workDir -InputHost $inputMountHost
        if (Test-Path -LiteralPath $vttHost) { $haveCreator = $true }
    }
    if ($whisperOk) { $haveWhisper = $true }
}

$primaryLabel = $null
$secondaryLabel = $null

if ($PrimaryOverride) {
    if ($PrimaryOverride -eq 'creator' -and $haveCreator) {
        $primaryLabel = 'creator'
    } elseif ($PrimaryOverride -eq 'whisper' -and $haveWhisper) {
        $primaryLabel = 'whisper'
    } else {
        Write-Warn "-PrimaryOverride $PrimaryOverride not available -- falling back to default rule"
    }
}
if (-not $primaryLabel -and -not $DryRun) {
    if ($intermediate.subtitle_source -eq 'creator' -and $haveCreator) {
        $primaryLabel = 'creator'
    } elseif ($haveWhisper) {
        $primaryLabel = 'whisper'
    } elseif ($haveCreator) {
        $primaryLabel = 'creator'
    }
}
if ($primaryLabel -eq 'creator' -and $haveWhisper) { $secondaryLabel = 'whisper' }
if ($primaryLabel -eq 'whisper' -and $haveCreator) { $secondaryLabel = 'creator' }

#endregion

#region Report

function Read-CreatorVTT {
    param([string]$ContainerPath)
    $hostPath = ConvertTo-HostPath -ContainerPath $ContainerPath -WorkHost $workDir -InputHost $inputMountHost
    if (-not (Test-Path -LiteralPath $hostPath)) { return $null }
    $text = Read-UTF8 $hostPath
    $segs = New-Object System.Collections.Generic.List[object]
    $rx = [regex]'(?m)^(\d{2}):(\d{2}):(\d{2})[\.,](\d{3})\s+-->\s+(\d{2}):(\d{2}):(\d{2})[\.,](\d{3})[^\r\n]*\r?\n((?:[^\r\n].*\r?\n?)+)'
    $rxTag = [regex]'<[^>]+>'
    foreach ($m in $rx.Matches($text)) {
        $start = [int]$m.Groups[1].Value*3600 + [int]$m.Groups[2].Value*60 + [int]$m.Groups[3].Value + [double]$m.Groups[4].Value/1000
        $end   = [int]$m.Groups[5].Value*3600 + [int]$m.Groups[6].Value*60 + [int]$m.Groups[7].Value + [double]$m.Groups[8].Value/1000
        $body = ($m.Groups[9].Value -split "`r?`n" | ForEach-Object { ($rxTag.Replace($_, '')).Trim() } | Where-Object { $_ }) -join ' '
        if (-not $body) { continue }
        if ($segs.Count -gt 0) {
            $prev = $segs[$segs.Count-1]
            if ($prev.text -eq $body) { $prev.end = $end; continue }
            if ($body.StartsWith($prev.text + ' ')) { $prev.text = $body; $prev.end = $end; continue }
            $pp = $prev.text -split ' '
            $cc = $body -split ' '
            $maxK = [math]::Min($pp.Length, $cc.Length)
            $merged = $null
            for ($k = $maxK; $k -ge 3; $k--) {
                $pTail = $pp[($pp.Length - $k)..($pp.Length - 1)] -join ' '
                $cHead = $cc[0..($k - 1)] -join ' '
                if ($pTail -ceq $cHead) {
                    # If $k == $cc.Length the current cue is fully contained as
                    # the suffix of the previous cue -- nothing to append. Slicing
                    # $cc[$k..($cc.Length-1)] in that case is a reverse-range and
                    # throws IndexOutOfRangeException.
                    $extra = if ($k -lt $cc.Length) { $cc[$k..($cc.Length - 1)] } else { @() }
                    $merged = (($pp + $extra) -join ' ')
                    break
                }
            }
            if ($merged) { $prev.text = $merged; $prev.end = $end; continue }
        }
        $segs.Add([pscustomobject]@{ start = [math]::Round($start,2); end = [math]::Round($end,2); text = $body }) | Out-Null
    }
    return $segs
}

function Format-TranscriptBlock {
    param([object[]]$Segments, [double]$StartFilter = -1, [double]$EndFilter = -1)
    $lines = @()
    foreach ($seg in $Segments) {
        if ($StartFilter -ge 0 -and $seg.end -lt $StartFilter) { continue }
        if ($EndFilter   -ge 0 -and $seg.start -gt $EndFilter) { continue }
        $start = [int]$seg.start
        $stamp = '[{0:D2}:{1:D2}]' -f [int][math]::Floor($start / 60), [int]($start % 60)
        $lines += "$stamp $($seg.text)"
    }
    return ($lines -join "`n")
}

if ($DryRun) {
    Write-Output ""
    Write-Output "# watch: DRY RUN"
    Write-Output ""
    Write-Output "_No work performed. See [watch] stderr above for the docker invocations that would have run._"
    exit $script:WL_EXIT.OK
}

if ($haveCreator) {
    $creatorSegments = Read-CreatorVTT -ContainerPath ([string]$intermediate.subtitle_path)
    if (-not $creatorSegments) { $haveCreator = $false }
}
if ($haveWhisper) {
    $whisperSegments = $whisperTranscript.segments
}

$info = $intermediate.info
$dur  = [double]$intermediate.duration_seconds
$focused = [bool]$intermediate.focused

# info's keys vary by source kind (local files have no 'uploader'; a URL
# whose info.json failed to parse has no 'title'). Under StrictMode a
# missing property is a terminating error, so probe before reading.
function Get-WLInfoProp([object]$Obj, [string]$Name) {
    if ($null -ne $Obj -and $Obj.PSObject.Properties.Match($Name).Count -gt 0) { return $Obj.$Name }
    return $null
}
$infoTitle    = Get-WLInfoProp $info 'title'
$infoUploader = Get-WLInfoProp $info 'uploader'

Write-Output ""
Write-Output "# watch: video report"
Write-Output ""
Write-Output "- **Source:** $($intermediate.source)"
if ($infoTitle)    { Write-Output "- **Title:** $infoTitle" }
if ($infoUploader) { Write-Output "- **Uploader:** $infoUploader" }
Write-Output ("- **Duration:** {0} ({1:N1}s)" -f (Format-WLTime $dur), $dur)
if ($focused) {
    Write-Output ("- **Focus range:** {0} -> {1} ({2:N1}s)" -f `
        (Format-WLTime ([double]$intermediate.effective_start)), `
        (Format-WLTime ([double]$intermediate.effective_end)), `
        ([double]$intermediate.effective_duration))
}
if ($intermediate.metadata.width) {
    Write-Output "- **Resolution:** $($intermediate.metadata.width)x$($intermediate.metadata.height) ($($intermediate.metadata.codec))"
}
$mode = if ($focused) { 'focused' } else { 'full' }
Write-Output ("- **Frames:** {0} @ {1:N3} fps, {2} mode (budget {3}, max {4})" -f `
    $intermediate.frames.Count, [double]$intermediate.fps, $mode, $intermediate.target_frames, $intermediate.max_frames)
Write-Output "- **Frame size:** $($intermediate.resolution)px wide"
$provLabel = if ($intermediate.subtitle_source) { [string]$intermediate.subtitle_source } else { 'none on source' }
Write-Output "- **Caption provenance:** $provLabel"
$whisperLine = if ($whisperOk) { "ran ($Model)" } else { "skipped/failed -- $skipWhisperReason" }
Write-Output "- **Whisper:** $whisperLine"
if ($comparison -and $comparison.metrics) {
    Write-Output ("- **Comparison:** {0} (length_ratio {1}, word_jaccard {2}, 3gram_jaccard {3})" -f `
        $comparison.significance, $comparison.metrics.length_ratio, $comparison.metrics.word_jaccard, $comparison.metrics.trigram_jaccard)
}

if (-not $whisperOk -and $skipWhisperReason -ne 'no audio track in source') {
    Write-Output ""
    Write-Output "> **Partial result** -- whisper transcription did not complete: $skipWhisperReason. Frames + creator captions (if any) are below."
}
if (-not $focused -and $dur -gt 600) {
    $mins = [int][math]::Floor($dur / 60)
    Write-Output ""
    Write-Output "> **Warning:** This is a $mins-minute video. Frame coverage is sparse at this length -- accuracy degrades on anything over 10 minutes. For better results, re-run with -Start HH:MM:SS -End HH:MM:SS to zoom into a specific section."
}
if ($comparison -and $comparison.significance -eq 'major') {
    Write-Output ""
    Write-Output "> **Note:** noticeable divergence between creator captions and local Whisper. Spot-check spoken proper nouns / technical terms -- one source may be wrong."
}

# Localized hallucination bursts (repetition loops) don't move the global
# comparison metrics enough to flag, so surface them explicitly.
$repRuns = @()
if ($whisperOk) {
    $repRuns = @((Get-WLInfoProp $whisperTranscript 'repetition_runs') | Where-Object { $null -ne $_ })
}
if ($repRuns.Count -gt 0) {
    $spans = ($repRuns | ForEach-Object {
        '{0}-{1} ("{2}" x{3})' -f (Format-WLTime ([double]$_.start)), (Format-WLTime ([double]$_.end)), $_.text, $_.count
    }) -join '; '
    Write-Output ""
    Write-Output "> **Note:** Whisper repetition loop(s) collapsed (hallucination artifact) at: $spans. Treat Whisper output near these spans as unreliable; prefer creator captions there when available."
}

Write-Output ""
Write-Output "## Frames"
Write-Output ""
# -Cleanup deletes the job dir when this command exits, i.e. before the
# caller can Read anything -- so never list canonical paths under -Cleanup.
# With -SaveHere the promoted copies survive; list those instead.
$promotedDir = if ($SaveHere) { Join-Path (Join-Path $PWD.Path 'watch-local-output') $slug } else { $null }
if ($Cleanup -and -not $SaveHere) {
    Write-Output "**-Cleanup is active: frame files are deleted when this command exits -- do NOT try to Read them (transcript-only mode).**"
    Write-Output ""
    Write-Output "For visual analysis with zero leftover footprint, re-run WITHOUT -Cleanup, Read the frames, then remove the job dir with:"
    Write-Output ""
    Write-Output "``powershell -File `"$PSScriptRoot\setup.ps1`" -PurgeJob -Slug $slug``"
    Write-Output ""
    Write-Output "(prints a preview + confirm token; re-run the same command with ``-JobConfirmToken <token>`` to delete)"
} else {
    $framesBase = if ($Cleanup) { Join-Path $promotedDir 'frames' } else { Join-Path $workDir 'frames' }
    Write-Output "Frames live at: ``$(ConvertTo-DockerPath $framesBase)``"
    if ($Cleanup) {
        Write-Output ""
        Write-Output "_(-Cleanup deletes the canonical job dir at exit; the paths below are the -SaveHere promoted copies.)_"
    }
    Write-Output ""
    Write-Output "**Read each frame path below with the Read tool to view the image.** Frames are in chronological order; ``t=MM:SS`` is the absolute timestamp in the source video."
    Write-Output ""
    foreach ($frame in $intermediate.frames) {
        $hostPath = if ($Cleanup) {
            ConvertTo-DockerPath (Join-Path $framesBase (Split-Path -Leaf ([string]$frame.path)))
        } else {
            ConvertTo-HostPath -ContainerPath ([string]$frame.path) -WorkHost $workDir -InputHost $inputMountHost
        }
        $stamp = Format-WLTime ([double]$frame.timestamp_seconds)
        Write-Output "- ``$hostPath`` (t=$stamp)"
    }
}

Write-Output ""
Write-Output "## Transcript ($primaryLabel primary)"
Write-Output ""
$primarySegments = if ($primaryLabel -eq 'creator') { $creatorSegments } elseif ($primaryLabel -eq 'whisper') { $whisperSegments } else { $null }
$secondarySegments = if ($secondaryLabel -eq 'creator') { $creatorSegments } elseif ($secondaryLabel -eq 'whisper') { $whisperSegments } else { $null }
# Force array shape so .Count works under StrictMode regardless of what the
# ternary if-expressions returned (List<T> / array / scalar / $null).
$primarySegments   = @($primarySegments | Where-Object { $null -ne $_ })
$secondarySegments = @($secondarySegments | Where-Object { $null -ne $_ })

if ($primarySegments -and $primarySegments.Count -gt 0) {
    $headerNote = if ($secondaryLabel) { "Compared against $secondaryLabel." } else { 'No secondary transcript.' }
    Write-Output ("_Source: {0}. {1}_" -f $primaryLabel, $headerNote)
    Write-Output ""
    Write-Output '```'
    if ($focused) {
        Write-Output (Format-TranscriptBlock -Segments $primarySegments -StartFilter ([double]$intermediate.effective_start) -EndFilter ([double]$intermediate.effective_end))
    } else {
        Write-Output (Format-TranscriptBlock -Segments $primarySegments)
    }
    Write-Output '```'
} else {
    Write-Output "_No primary transcript available -- proceed with frames only._"
}

if ($secondarySegments -and $secondarySegments.Count -gt 0) {
    Write-Output ""
    Write-Output "<details><summary>Secondary transcript ($secondaryLabel)</summary>"
    Write-Output ""
    Write-Output '```'
    if ($focused) {
        Write-Output (Format-TranscriptBlock -Segments $secondarySegments -StartFilter ([double]$intermediate.effective_start) -EndFilter ([double]$intermediate.effective_end))
    } else {
        Write-Output (Format-TranscriptBlock -Segments $secondarySegments)
    }
    Write-Output '```'
    Write-Output "</details>"
}

Write-Output ""
Write-Output "---"
if ($Cleanup) {
    Write-Output "_Work dir ``$(ConvertTo-DockerPath $workDir)`` is deleted when this command exits (-Cleanup)._"
} else {
    Write-Output "_Work dir: ``$(ConvertTo-DockerPath $workDir)`` -- delete when done via ``setup.ps1 -PurgeJob -Slug $slug`` (or re-run with -Cleanup)._"
}

#endregion

#region Screenshots

# -Screenshots "MM:SS,MM:SS" pulls native-resolution stills of specific
# moments from the (best-quality) source, into <workDir>/screenshots/. They
# are promoted by -SaveHere and survive until -Cleanup, same as frames.
if (-not $DryRun -and $Screenshots) {
    $srcVideoContainer = $null
    $shotMounts = @(
        '-v', "$(ConvertTo-DockerPath $workDir):/work",
        '-v', "$(ConvertTo-DockerPath $workerDir):/app:ro"
    )
    if ($isUrl) {
        $dl = Join-Path $workDir 'download'
        $vid = Get-ChildItem -LiteralPath $dl -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -match '^\.(mp4|mkv|webm|mov|m4v|avi|flv|wmv)$' } |
               Select-Object -First 1
        if ($vid) { $srcVideoContainer = "/work/download/$($vid.Name)" }
    } elseif ($inputMountHost) {
        $shotMounts += @('-v', "$(ConvertTo-DockerPath $inputMountHost):/input:ro")
        $srcVideoContainer = $containerSource
    }

    if (-not $srcVideoContainer) {
        Write-Warn "screenshots requested but source video not found -- skipping."
    } else {
        $resLabel = if ($StillResolution -gt 0) { "$StillResolution px" } else { 'native resolution' }
        Write-Stage "extracting screenshots at ${resLabel}: $Screenshots"
        $shotEnv = @(
            '-e', "W_VIDEO=$srcVideoContainer",
            '-e', "W_SHOTS=$Screenshots",
            '-e', 'W_OUT_DIR=/work/screenshots',
            '-e', "W_STILL_RES=$StillResolution"
        )
        $code = Invoke-WLRun ($shotEnv + $shotMounts + @($script:WL_IMG_TOOLS, 'python3', '/app/stills.py')) -Name 'screenshots'
        $shotsDir = Join-Path $workDir 'screenshots'
        if ($code -eq 0 -and (Test-Path -LiteralPath $shotsDir)) {
            $shotFiles = @(Get-ChildItem -LiteralPath $shotsDir -File -ErrorAction SilentlyContinue |
                           Where-Object { $_.Extension -eq '.jpg' } | Sort-Object Name)
            if ($shotFiles.Count -gt 0) {
                Write-Output ""
                Write-Output "## Screenshots ($resLabel)"
                Write-Output ""
                if ($Cleanup -and -not $SaveHere) {
                    # Same rule as frames: gone before the caller can Read.
                    Write-Output "**-Cleanup is active: screenshot files are deleted when this command exits -- do NOT try to Read them.** Re-run without -Cleanup to view."
                } else {
                    Write-Output "Full-resolution stills of the requested moments. Read these paths to view:"
                    foreach ($f in $shotFiles) {
                        $shotPath = if ($Cleanup) { Join-Path (Join-Path $promotedDir 'screenshots') $f.Name } else { $f.FullName }
                        Write-Output "- ``$(ConvertTo-DockerPath $shotPath)``"
                    }
                }
            }
        } else {
            Write-Warn "screenshot extraction failed (exit $code)."
        }
    }
}

#endregion

#region Promote

try {
    $lastJob = [pscustomobject]@{
        slug          = $slug
        source        = $Source
        created_at    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        is_url        = $isUrl
        original_path = $originalSourcePath
        work_dir      = $workDir
    }
    $lastJob | ConvertTo-Json | Set-Content -LiteralPath $script:WL_LAST_JOB -Encoding utf8
    # Per-job copy so grab-frames can find the original source for ANY job,
    # not just the most recent one (last-job.json gets overwritten).
    $lastJob | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $workDir 'job.json') -Encoding utf8
} catch {
    Write-Detail "could not write last-job registry: $($_.Exception.Message)"
}

$promoteOk = $true
if ($SaveHere) {
    $promoteScript = Join-Path $PSScriptRoot 'save-here.ps1'
    # Hashtable splat, NOT an array of '-Name' strings: PS 5.1 array
    # splatting bound '-Cwd' positionally and threw, so promotion never
    # worked from this call site.
    $promoteArgs = @{ Slug = $slug; Cwd = $PWD.Path }
    if ($IncludeSource) { $promoteArgs.IncludeSource = $true }
    if ($MoveOnSave)    { $promoteArgs.MoveOnSave = $true }
    Write-Stage "promoting artifacts to current directory..."
    $promoteOk = $false
    try {
        & $promoteScript @promoteArgs
        $promoteOk = ($LASTEXITCODE -eq 0)
    } catch {
        Write-Warn "promote failed: $($_.Exception.Message)"
    }
    if (-not $promoteOk) {
        Write-Warn "promote failed -- canonical job dir kept under jobs_root."
    } elseif ($Cleanup) {
        # save-here just said the canonical copy is "still present until you
        # purge it" -- not true when -Cleanup deletes it next.
        Write-Output ""
        Write-Output "_(-Cleanup: the canonical copy under jobs_root is removed at exit -- use only the promoted paths above.)_"
    }
}

#endregion

#region Cleanup

if ($stagedDir -and (Test-Path -LiteralPath $stagedDir)) {
    try {
        Assert-InsideRoot -Target $stagedDir -Root $stagingRoot
        Remove-Item -LiteralPath $stagedDir -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Detail "staging cleanup skipped: $($_.Exception.Message)"
    }
}

if ($Cleanup) {
    if ($OutDir) {
        Write-Warn "-Cleanup ignored when -OutDir is set (scope guard)."
    } elseif (-not $promoteOk) {
        # Deleting the canonical dir after a failed promote would destroy
        # the only copy while the report points at promoted paths that
        # don't exist.
        Write-Warn "-Cleanup skipped: -SaveHere promotion failed; canonical dir kept: $workDir"
    } else {
        try {
            Assert-InsideRoot -Target $workDir -Root $jobsRoot
            Remove-Item -LiteralPath $workDir -Recurse -Force
            Write-Stage "work dir removed."
        } catch {
            Write-Warn "cleanup failed: $($_.Exception.Message)"
        }
    }
}

exit $script:WL_EXIT.OK

#endregion
