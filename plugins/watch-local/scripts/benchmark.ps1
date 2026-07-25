#requires -Version 5.1
<#
.SYNOPSIS
    Benchmark local Whisper transcription: per-model timing, resource use,
    and quality against creator captions.

.DESCRIPTION
    Answers "which model should I run on THIS machine?" with measurements
    instead of guesses, and makes the published reference numbers
    (docs/benchmarks.md) reproducible on any supported platform.

    Method -- see docs/benchmarking.md for the rationale:
      0. Every published number uses ONE fixed video (see -Source), so
         results from different machines can be compared at all. Run it
         with no arguments to reproduce them.
      1. Acquire audio once (download + extract, or reuse a job / file),
         so every model transcribes byte-identical input.
      2. Per model: an untimed warm run, then a timed run. The warm pass
         is a FULL transcription -- so budget roughly double the times
         you see reported -- and it exists to move the one-time model
         download and first load out of the measurement. The timed
         number therefore covers load-from-disk + transcription, which
         is what a second run actually costs.
      3. Sample the worker process while it runs -- peak RSS and total
         processor seconds, which divided by wall time gives the mean
         core count. Per-process only: it is the number that isolates
         Whisper, and Get-Process reports it identically on Windows,
         Linux, and macOS.
      4. Score every transcript with worker/quality.py (WER + word
         Jaccard vs the creator captions, plus vs the largest model).
      5. Emit results.json, results.csv, and a ready-to-paste report.md.

    Nothing here writes into the plugin directory: output lands under the
    watch-local state root (or -OutDir).

.PARAMETER Source
    URL or local/UNC path to benchmark. Ignored when -Slug or -AudioPath
    is given.

    Defaults to THE reference fixture every published table uses:

        https://www.youtube.com/watch?v=AfOZ-MXe4uQ
        "50 Insane Declassified MI6 Secrets You Didn't Know"
        The Infographics Show -- 32 min 53 s (1973 s)

    Chosen because it is public, long enough for the differences between
    models to be unmistakable, clean single-narrator English, and carries
    human-written creator captions -- which is what makes the WER column
    a quality signal rather than a comparison against another machine's
    guess. Run without -Source (or pass that URL) whenever you intend to
    compare your numbers with the published ones; anything else measures
    a different workload.

.PARAMETER Slug
    Reuse an already-watched job's audio.mp3 and creator captions. The
    cheapest way to benchmark -- no download, no re-extraction.

.PARAMETER AudioPath
    Benchmark this audio file directly. Pair with -ReferenceVtt to keep
    quality scoring.

.PARAMETER ReferenceVtt
    Caption VTT to score WER against. Auto-detected for -Slug and for a
    fresh -Source download, along with its provenance: most YouTube
    videos only carry AUTO-generated captions, and WER against another
    ASR system is not a quality measurement. The report says which kind
    it used.

.PARAMETER Models
    Models to measure, smallest first. The last one present becomes the
    baseline that the others are compared against.

.PARAMETER CpuThreads
    Thread counts to sweep instead of models -- runs -Models[0] once per
    value. 0 means "faster-whisper's own default" (4). CPU mode only.

.PARAMETER Device
    auto (default) uses the detected GPU when CUDA whisper works; cpu and
    gpu force one side. Use cpu on a GPU box to produce CPU reference
    numbers.

.PARAMETER OutDir
    Where to write results. Default: <state root>/benchmarks/<stamp>.

.PARAMETER SampleMs
    Resource sampling interval in ms (default 500).

.PARAMETER SkipQuality
    Skip WER scoring (timing only).

.PARAMETER SkipWarm
    Skip the untimed warm pass, halving the run. Only valid when every
    model is ALREADY downloaded and has been loaded at least once
    recently -- otherwise the first model's timing absorbs its download
    and is meaningless. Worth it for CPU sweeps, where the warm pass on
    large-v3 alone can cost an hour.

.EXAMPLE
    benchmark.ps1 -Slug last -Models small,medium
    Benchmark two models against the last video you watched.

.EXAMPLE
    benchmark.ps1 -Slug last -Device cpu -Models small -CpuThreads 0,4,8,16
    Measure CPU thread scaling on this machine.
#>

#region Params
[CmdletBinding()]
param(
    [string]$Source = 'https://www.youtube.com/watch?v=AfOZ-MXe4uQ',
    [string]$Slug = '',
    [string]$AudioPath = '',
    [string]$ReferenceVtt = '',
    # Comma-separated or repeated. NOT [ValidateSet]/[int[]]: under
    # `pwsh -File` every argument arrives as one string, so "tiny,base"
    # would fail to bind -- which is exactly how the docs tell people to
    # call this. Parsed and validated below instead.
    [string[]]$Models = @('tiny', 'base', 'small', 'medium', 'large-v3'),
    [string[]]$CpuThreads = @(),
    [ValidateSet('auto', 'cpu', 'gpu')]
    [string]$Device = 'auto',
    [string]$OutDir = '',
    [int]$SampleMs = 500,
    [switch]$SkipQuality,
    [switch]$SkipWarm,
    [switch]$VerboseLog
)
#endregion

#region Init
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\_lib.ps1"
if ($VerboseLog) { Enable-VerboseLog }

Assert-WLRuntimeReady

$config     = Get-WLConfig
$gpuInfo    = Get-WLGpuInfo -Config $config
$modelsRoot = [string]$config.models_root

if ($SampleMs -lt 50) {
    Write-Err 'sampling faster than 50 ms costs more than it measures.'
    exit $script:WL_EXIT.FLAG_CONFLICT
}

# Accept "-Models a,b", "-Models a -Models b", and the `pwsh -File`
# single-string form all the same way.
function _SplitList([string[]]$Raw) {
    $out = @()
    foreach ($item in $Raw) {
        foreach ($piece in ([string]$item) -split ',') {
            $t = $piece.Trim()
            if ($t) { $out += $t }
        }
    }
    return $out
}

$KNOWN_MODELS = @('large-v3', 'medium', 'small', 'base', 'tiny')
$Models = @(_SplitList $Models | ForEach-Object { $_.ToLowerInvariant() })
if ($Models.Count -eq 0) {
    Write-Err 'no models requested.'
    exit $script:WL_EXIT.FLAG_CONFLICT
}
$unknown = @($Models | Where-Object { $_ -notin $KNOWN_MODELS })
if ($unknown.Count -gt 0) {
    Write-Err "unknown model(s): $($unknown -join ', '). Choose from: $($KNOWN_MODELS -join ', ')."
    exit $script:WL_EXIT.FLAG_CONFLICT
}

$threadValues = @()
foreach ($t in (_SplitList $CpuThreads)) {
    $n = 0
    if (-not [int]::TryParse($t, [ref]$n) -or $n -lt 0) {
        Write-Err "-CpuThreads takes non-negative integers; got '$t'."
        exit $script:WL_EXIT.FLAG_CONFLICT
    }
    $threadValues += $n
}
$sourceFlags = @(@($Slug, $AudioPath) | Where-Object { $_ })
if ($sourceFlags.Count -gt 1) {
    Write-Err 'pass at most one of -Slug / -AudioPath.'
    exit $script:WL_EXIT.FLAG_CONFLICT
}
#endregion

#region Device
# The whisper env decides cuda/float16 vs cpu/int8 exactly as /watch
# does; -Device only overrides the choice, never the pairing.
$configThreads = Get-WLObjectProp $config 'cpu_threads'
$whisperEnv = Get-WLWhisperWorkerEnv -Gpu $gpuInfo -ModelsRoot $modelsRoot -CpuThreads $configThreads
if ($Device -eq 'cpu') {
    $whisperEnv.W_DEVICE = 'cpu'
    $whisperEnv.W_COMPUTE = 'int8'
    # Forcing CPU on a GPU box skips the CPU branch entirely, so repeat
    # its thread choice here -- a benchmark should measure what /watch
    # would actually run on a CPU-only machine.
    if ($null -ne $configThreads -and [int]$configThreads -ge 0) {
        $whisperEnv.W_CPU_THREADS = [string][int]$configThreads
    }
} elseif ($Device -eq 'gpu') {
    if (-not (Get-WLObjectProp $gpuInfo 'cuda_whisper')) {
        Write-Err '-Device gpu requested but CUDA whisper is not available (run setup.ps1 -DetectGpu).'
        exit $script:WL_EXIT.FLAG_CONFLICT
    }
    $whisperEnv.W_DEVICE = 'cuda'
    $whisperEnv.W_COMPUTE = 'float16'
}
$deviceName  = [string]$whisperEnv.W_DEVICE
$computeName = [string]$whisperEnv.W_COMPUTE

if ($threadValues.Count -gt 0 -and $deviceName -ne 'cpu') {
    Write-Err '-CpuThreads only means something on CPU. Add -Device cpu.'
    exit $script:WL_EXIT.FLAG_CONFLICT
}
#endregion

#region OutDir
if (-not $OutDir) {
    $dirs = Get-WLPlatformDirs
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $OutDir = Join-Path (Join-Path $dirs.Base 'benchmarks') $stamp
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$workDir = Join-Path $OutDir 'work'
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Write-Stage "benchmark output: $OutDir"
#endregion

#region Audio
# One audio file for every model: identical input is the whole point of
# an apples-to-apples comparison.
$audio = ''
$refVtt = $ReferenceVtt
# 'creator' | 'auto' | 'supplied' | '' -- WER means something different
# against human-edited captions than against another ASR system's
# output, so the provenance travels with the number.
$refKind = if ($ReferenceVtt) { 'supplied' } else { '' }

if ($AudioPath) {
    if (-not (Test-Path -LiteralPath $AudioPath)) {
        Write-Err "audio not found: $AudioPath"
        exit $script:WL_EXIT.SOURCE_BAD
    }
    $audio = (Resolve-Path -LiteralPath $AudioPath).Path
    $sourceLabel = $audio
} elseif ($Slug) {
    $jobsRoot = [string]$config.jobs_root
    if ($Slug -eq 'last') {
        if (-not (Test-Path -LiteralPath $script:WL_LAST_JOB)) {
            Write-Err 'no last-job recorded. Run /watch first, or pass -Source.'
            exit $script:WL_EXIT.SOURCE_BAD
        }
        $last = $null
        try { $last = Read-UTF8 $script:WL_LAST_JOB | ConvertFrom-Json } catch { }
        $Slug = [string](Get-WLObjectProp $last 'slug')
        if (-not $Slug) {
            Write-Err "last-job record is unreadable or has no slug ($script:WL_LAST_JOB). Pass -Slug <name> or -Source."
            exit $script:WL_EXIT.SOURCE_BAD
        }
        Write-Detail "resolved 'last' -> slug $Slug"
    }
    $jobDir = Join-Path $jobsRoot $Slug
    try {
        Assert-InsideRoot -Target $jobDir -Root $jobsRoot
    } catch {
        Write-Err "refused: slug '$Slug' does not resolve inside jobs_root."
        exit $script:WL_EXIT.PURGE_REFUSED
    }
    $audio = Join-Path $jobDir 'audio.mp3'
    if (-not (Test-Path -LiteralPath $audio)) {
        Write-Err "job $Slug has no audio.mp3 (silent source, or an older job)."
        exit $script:WL_EXIT.SOURCE_BAD
    }
    if (-not $refVtt) {
        # Take the job's own classification rather than guessing from the
        # filename: video.en.vtt is whichever track yt-dlp wrote, and on
        # most YouTube videos that is the auto-generated one.
        $jobIntermediate = Join-Path $jobDir 'intermediate.json'
        if (Test-Path -LiteralPath $jobIntermediate) {
            $ji = Read-UTF8 $jobIntermediate | ConvertFrom-Json
            $sub = [string](Get-WLObjectProp $ji 'subtitle_path')
            if ($sub) {
                if (Test-Path -LiteralPath $sub) {
                    $refVtt = $sub
                } else {
                    # Jobs written before the native-runtime migration
                    # recorded container paths (/work/download/...); the
                    # file itself is still in the job dir.
                    $candidate = Join-Path (Join-Path $jobDir 'download') (Split-Path -Leaf $sub)
                    if (Test-Path -LiteralPath $candidate) { $refVtt = $candidate }
                }
            }
            if ($refVtt) { $refKind = [string](Get-WLObjectProp $ji 'subtitle_source') }
        }
    }
    $sourceLabel = "job $Slug"
} else {
    Write-Stage "acquiring audio from $Source ..."
    $isUrl = $Source -match '^https?://'
    $toolsEnv = (Get-WLToolsWorkerEnv -Gpu $gpuInfo) + @{
        W_WORK_DIR   = $workDir
        W_SOURCE     = $Source
        W_IS_URL     = if ($isUrl) { '1' } else { '0' }
        W_MAX_FRAMES = '1'   # frames are irrelevant here; audio is the payload
        W_RESOLUTION = '256'
        # Whisper reads the separately-downloaded audio stream, so capping
        # video height changes nothing it sees -- it just avoids pulling
        # a 1080p file to benchmark a transcript.
        W_MAX_HEIGHT = '480'
    }
    $code = Invoke-WLWorker -Script 'tools_run.py' -EnvVars $toolsEnv -Name 'acquire'
    if ($code -ne 0) {
        Write-Err "could not acquire audio (tools worker exit $code)."
        exit $script:WL_EXIT.TOOLS_FAILED
    }
    $audio = Join-Path $workDir 'audio.mp3'
    if (-not (Test-Path -LiteralPath $audio)) {
        Write-Err 'source produced no audio track -- nothing to transcribe.'
        exit $script:WL_EXIT.SOURCE_BAD
    }
    if (-not $refVtt) {
        $intermediate = Read-UTF8 (Join-Path $workDir 'intermediate.json') | ConvertFrom-Json
        $sub = Get-WLObjectProp $intermediate 'subtitle_path'
        if ($sub) {
            $refVtt = [string]$sub
            $refKind = [string](Get-WLObjectProp $intermediate 'subtitle_source')
        }
    }
    $sourceLabel = $Source
}

# whisper_run.py always reads <W_WORK_DIR>/audio.mp3.
$benchAudio = Join-Path $workDir 'audio.mp3'
if ((Resolve-Path -LiteralPath $audio).Path -ne $benchAudio) {
    Copy-Item -LiteralPath $audio -Destination $benchAudio -Force
}
if ($refVtt -and -not (Test-Path -LiteralPath $refVtt)) {
    Write-Warn "reference captions not found at $refVtt -- models will only be scored against each other."
    $refVtt = ''
}
Write-Detail "audio: $benchAudio"
#endregion

#region Measure
# Run the worker as a child we can watch. Invoke-WLWorker runs it
# synchronously with no handle, and the handle is the measurement -- so
# this mirrors its env handling and starts the process itself.
function Invoke-WLMeasuredWorker {
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][hashtable]$EnvVars,
        [Parameter(Mandatory)][string]$LogPrefix,
        [int]$IntervalMs = 500
    )
    $py = Get-WLWorkerPython
    $scriptPath = Join-Path $script:WL_WORKER_DIR $Script
    $vars = Get-WLWorkerEnv -Extra $EnvVars

    $saved = @{}
    foreach ($k in $vars.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, [string]$vars[$k])
    }
    $outLog = "$LogPrefix.out.log"
    $errLog = "$LogPrefix.err.log"
    $peakRssMb = 0.0
    $cpuSeconds = 0.0
    $samples = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        # Quote the script path explicitly. Unlike `& $py $path`,
        # Start-Process pastes -ArgumentList into a command line verbatim,
        # so an unquoted "C:\Users\Ada Lovelace\..." arrives as two
        # arguments and python opens the wrong file.
        $proc = Start-Process -FilePath $py -ArgumentList @("`"$scriptPath`"") -NoNewWindow -PassThru `
                              -RedirectStandardOutput $outLog -RedirectStandardError $errLog
        # Re-discover the tree periodically: the real interpreter is a
        # child of the launcher and does not exist yet at t=0.
        $treeIds = @($proc.Id)
        $sinceRescan = [int]::MaxValue
        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds $IntervalMs
            if ($sinceRescan * $IntervalMs -ge 2000) {
                try { $treeIds = @(Get-WLProcessTreeIds -RootId $proc.Id) } catch { }
                $sinceRescan = 0
            }
            $sinceRescan++

            # Sum the whole tree. Members die between discovery and
            # sampling all the time -- skip them, never fail the run.
            $rssSum = 0.0
            $cpuSum = 0.0
            $alive = 0
            foreach ($id in $treeIds) {
                try {
                    $live = Get-Process -Id $id -ErrorAction Stop
                    $rssSum += $live.WorkingSet64 / 1MB
                    $cpuSum += $live.TotalProcessorTime.TotalSeconds
                    $alive++
                } catch { }
            }
            if ($alive -gt 0) {
                $samples++
                if ($rssSum -gt $peakRssMb) { $peakRssMb = $rssSum }
                # Processor time only climbs, so the largest reading is
                # the total even when a child exits before the last tick.
                if ($cpuSum -gt $cpuSeconds) { $cpuSeconds = $cpuSum }
            }
        }
        $proc.WaitForExit()
        $sw.Stop()
        # Prefer the process's own timestamps: the poll loop can overshoot
        # the real exit by up to one sampling interval.
        $seconds = $sw.Elapsed.TotalSeconds
        try {
            $exact = ($proc.ExitTime - $proc.StartTime).TotalSeconds
            if ($exact -gt 0) { $seconds = $exact }
        } catch { }
        return [pscustomobject]@{
            ExitCode    = $proc.ExitCode
            Seconds     = [math]::Round($seconds, 2)
            CpuSeconds  = [math]::Round($cpuSeconds, 2)
            PeakRssMb   = [math]::Round($peakRssMb, 1)
            Samples     = $samples
            StderrLog   = $errLog
        }
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}
#endregion

#region Run
# Sweep mode measures one model across thread counts; normal mode
# measures each model at whatever thread count the worker picks.
$runs = @()
if ($threadValues.Count -gt 0) {
    $sweepModel = $Models[0]
    foreach ($t in $threadValues) {
        $runs += [pscustomobject]@{ Model = $sweepModel; Threads = $t; Label = "$sweepModel@t$t" }
    }
    Write-Stage "cpu_threads sweep on '$sweepModel': $($threadValues -join ', ')"
} else {
    foreach ($m in $Models) {
        $runs += [pscustomobject]@{ Model = $m; Threads = $null; Label = $m }
    }
    Write-Stage "models: $($Models -join ', ') on $deviceName/$computeName"
}

$results = @()
$audioDuration = $null
$transcriptDir = Join-Path $OutDir 'transcripts'
New-Item -ItemType Directory -Force -Path $transcriptDir | Out-Null

$configLanguage = [string](Get-WLObjectProp $config 'default_language')

foreach ($run in $runs) {
    $runEnv = $whisperEnv.Clone()
    $runEnv.W_WORK_DIR = $workDir
    $runEnv.W_MODEL = $run.Model
    # Match /watch: with a language configured, no model spends time
    # auto-detecting, and every run measures the same work.
    if ($configLanguage) { $runEnv.W_LANGUAGE = $configLanguage }
    if ($null -ne $run.Threads) { $runEnv.W_CPU_THREADS = [string]$run.Threads }

    # Warm first: a full untimed pass that absorbs the one-time model
    # download and first load, so the timed run measures steady state.
    # It costs as much as the timed run -- the price of comparability.
    if ($SkipWarm) {
        Write-Detail "[$($run.Label)] warm-up skipped (-SkipWarm)"
    } else {
        Write-Stage "[$($run.Label)] warm-up (untimed full pass -- may download the model)"
        $warm = Invoke-WLMeasuredWorker -Script 'whisper_run.py' -EnvVars $runEnv `
                                        -LogPrefix (Join-Path $OutDir "warm-$($run.Label)") -IntervalMs 2000
        if ($warm.ExitCode -ne 0) {
            Write-Warn "[$($run.Label)] warm-up failed (exit $($warm.ExitCode)); see $($warm.StderrLog). Skipping."
            continue
        }
    }

    Write-Stage "[$($run.Label)] timed run"
    $timed = Invoke-WLMeasuredWorker -Script 'whisper_run.py' -EnvVars $runEnv `
                                     -LogPrefix (Join-Path $OutDir "run-$($run.Label)") -IntervalMs $SampleMs
    if ($timed.ExitCode -ne 0) {
        Write-Warn "[$($run.Label)] failed (exit $($timed.ExitCode)); see $($timed.StderrLog). Skipping."
        continue
    }

    $transcript = Read-UTF8 (Join-Path $workDir 'transcript_whisper.json') | ConvertFrom-Json
    if ($null -eq $audioDuration) { $audioDuration = [double]$transcript.duration }
    Copy-Item -LiteralPath (Join-Path $workDir 'transcript_whisper.json') `
              -Destination (Join-Path $transcriptDir "transcript-$($run.Label).json") -Force

    $segments = @($transcript.segments).Count
    $repRuns = @((Get-WLObjectProp $transcript 'repetition_runs') | Where-Object { $null -ne $_ }).Count
    $rtf = if ($timed.Seconds -gt 0) { [math]::Round($audioDuration / $timed.Seconds, 2) } else { $null }
    $meanCores = if ($timed.Seconds -gt 0) { [math]::Round($timed.CpuSeconds / $timed.Seconds, 2) } else { $null }

    $results += [pscustomobject]@{
        label            = $run.Label
        model            = $run.Model
        device           = $deviceName
        compute          = $computeName
        cpu_threads      = [int](Get-WLObjectProp $transcript 'cpu_threads')
        seconds          = $timed.Seconds
        speed_vs_realtime = $rtf
        mean_cores       = $meanCores
        peak_rss_mb      = $timed.PeakRssMb
        segments         = $segments
        repetition_runs  = $repRuns
    }
    Write-Output ("  {0,-16} {1,8:N1}s  {2,6:N2}x realtime  {3,5:N1} cores  {4,7:N0} MB  {5} segments" -f `
        $run.Label, $timed.Seconds, $rtf, $meanCores, $timed.PeakRssMb, $segments)
}

if ($results.Count -eq 0) {
    Write-Err 'every run failed -- nothing to report.'
    exit $script:WL_EXIT.TOOLS_FAILED
}
#endregion

#region Quality
$quality = $null
if (-not $SkipQuality) {
    Write-Stage 'scoring transcripts (WER + Jaccard)'
    $qualEnv = @{
        W_QUALITY_DIR = $transcriptDir
        W_MODELS      = ($results.label -join ',')
        W_OUT_JSON    = (Join-Path $OutDir 'quality.json')
    }
    if ($refVtt) { $qualEnv.W_REFERENCE_VTT = $refVtt }
    $code = Invoke-WLWorker -Script 'quality.py' -EnvVars $qualEnv -Name 'quality'
    if ($code -eq 0) {
        $quality = Read-UTF8 (Join-Path $OutDir 'quality.json') | ConvertFrom-Json
    } else {
        Write-Warn "quality scoring failed (exit $code) -- timing results still written."
    }
}
#endregion

#region Emit
$psVersion = $PSVersionTable.PSVersion.ToString()
$osLabel = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription.Trim()
$arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture

$machine = [ordered]@{
    os               = $osLabel
    arch             = "$arch"
    logical_cpus     = [Environment]::ProcessorCount
    powershell       = $psVersion
    gpu_present      = [bool](Get-WLObjectProp $gpuInfo 'present')
    gpu_name         = [string](Get-WLObjectProp $gpuInfo 'name')
    gpu_cuda_whisper = [bool](Get-WLObjectProp $gpuInfo 'cuda_whisper')
}

$payload = [ordered]@{
    schema         = 'watch-local/benchmark@1'
    generated_at   = (Get-Date).ToUniversalTime().ToString('o')
    source         = $sourceLabel
    audio_seconds  = $audioDuration
    device         = $deviceName
    compute        = $computeName
    reference_vtt  = [bool]$refVtt
    reference_kind = $refKind
    warmed         = (-not $SkipWarm)
    machine        = $machine
    runs           = $results
    quality        = $quality
}
$jsonPath = Join-Path $OutDir 'results.json'
$payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$csvPath = Join-Path $OutDir 'results.csv'
$results | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

function _Wer([string]$label) {
    if (-not $quality) { return '' }
    $models = Get-WLObjectProp $quality 'models'
    if (-not $models) { return '' }
    $m = Get-WLObjectProp $models $label
    if (-not $m) { return '' }
    $v = Get-WLObjectProp $m 'wer_vs_captions'
    if ($null -eq $v) { return '' }
    return ('{0:N1}%' -f ([double]$v * 100))
}

$durLabel = if ($audioDuration) { Format-WLTime $audioDuration } else { 'unknown' }
$lines = @()
$lines += "# watch-local benchmark"
$lines += ""
$lines += "- **Generated:** $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC"
$lines += "- **Source:** $(ConvertTo-WLSafeMetaText $sourceLabel 120)"
$lines += "- **Audio duration:** $durLabel"
$lines += "- **Mode:** $deviceName / $computeName"
$lines += "- **Machine:** $osLabel ($arch), $([Environment]::ProcessorCount) logical CPUs"
if ($machine.gpu_present) {
    # nvidia-smi output is device-provided text landing in markdown.
    $lines += "- **GPU:** $(ConvertTo-WLSafeMetaText ([string]$machine.gpu_name) 80) (CUDA whisper: $($machine.gpu_cuda_whisper))"
}
$refLabel = switch ($refKind) {
    'creator'  { 'creator captions (human-edited)' }
    'auto'     { 'platform AUTO-captions (machine ASR, not human-edited)' }
    'supplied' { 'caption file supplied via -ReferenceVtt' }
    default    { if ($refVtt) { 'captions of unknown provenance' } else { 'none -- models compared to the largest only' } }
}
$lines += "- **Quality reference:** $refLabel"
$lines += ""
$lines += "| Run | Threads | Time | Speed vs real-time | Mean cores | Peak RSS | Segments | WER vs captions |"
$lines += "|---|---:|---:|---:|---:|---:|---:|---:|"
foreach ($r in $results) {
    $lines += ("| {0} | {1} | {2:N1} s | {3:N2}x | {4:N1} | {5:N0} MB | {6} | {7} |" -f `
        $r.label, $r.cpu_threads, $r.seconds, $r.speed_vs_realtime, $r.mean_cores, $r.peak_rss_mb, $r.segments, (_Wer $r.label))
}
$lines += ""
if ($SkipWarm) {
    $lines += "Times cover model load-from-disk plus transcription. The untimed warm pass"
    $lines += "was SKIPPED (-SkipWarm), so these numbers assume every model was already"
    $lines += "downloaded and recently loaded."
} else {
    $lines += "Times cover model load-from-disk plus transcription; the one-time model"
    $lines += "download happens in an untimed warm-up run."
}
$lines += "Mean cores = processor-seconds consumed / wall seconds, sampled every ${SampleMs} ms."
if ($refVtt) {
    $lines += ""
    if ($refKind -eq 'auto') {
        $lines += "WER here is measured against the platform's OWN automatic captions -- machine"
        $lines += "ASR output, not a human reference. It shows how far each model drifts from"
        $lines += "another speech recogniser, which is NOT the same as accuracy: both sides can"
        $lines += "be wrong, and a better model can score worse. Re-run against a video with"
        $lines += "creator-uploaded captions for a quality signal worth quoting."
    } else {
        $lines += "WER is measured against captions, which are human-EDITED text and not ground"
        $lines += "truth: a more literal transcriber scores worse without being less correct."
        $lines += "Treat these as relative, not absolute, accuracy."
    }
}
$lines += ""
$lines += "Raw data: ``results.json``, ``results.csv``, ``quality.json``, ``transcripts/``."

$reportPath = Join-Path $OutDir 'report.md'
$lines -join [Environment]::NewLine | Set-Content -LiteralPath $reportPath -Encoding UTF8

Write-Output ''
Write-Output ($lines -join [Environment]::NewLine)
Write-Output ''
Write-Output "Wrote:"
Write-Output "- ``$(ConvertTo-WLSlashPath $reportPath)``"
Write-Output "- ``$(ConvertTo-WLSlashPath $jsonPath)``"
Write-Output "- ``$(ConvertTo-WLSlashPath $csvPath)``"
Write-Output ''
Write-Output 'Comparable numbers from other machines live in docs/benchmarks.md --'
Write-Output 'contributions welcome (see docs/benchmarking.md).'
#endregion

exit $script:WL_EXIT.OK
