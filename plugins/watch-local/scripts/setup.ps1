#requires -Version 5.1
<#
.SYNOPSIS
    Preflight, install, config, and maintenance for watch-local.

.DESCRIPTION
    Modes (mutually exclusive top-level switches):
        -Check                    silent preflight, non-zero exit on miss
        -Json                     machine-readable status snapshot
        -DetectGpu                (re-)probe NVIDIA GPU + NVDEC, persist to config
        -Install (default)        detect GPU, build images + warm whisper model
        -ShowConfig               print config.json
        -SetJobsRoot <path>       relocate jobs_root
        -SetModelsRoot <path>     relocate models_root (use -MoveModels)
        -SetStagingRoot <path>    relocate staging_root
        -SetDefaultModel <name>   default whisper model for /watch
        -SetAutoCleanupDays <n>   warn on /watch if jobs older than n days exist
        -UnsetAutoCleanupDays     disable above
        -ListJobs                 read-only table of jobs
        -ListModels               read-only table of cached whisper models
        -PurgeJobs -OlderThanDays N [-DryRun] [-ConfirmToken T]
        -PurgeJob -Slug s [-JobConfirmToken T]
        -PurgeAllJobs -Confirm [-AllConfirmToken T]   (also needs env WATCH_LOCAL_I_REALLY_MEAN_IT=1)
        -RemoveModel -ModelName n

    SAFETY: every destructive op only touches paths inside the configured
    jobs_root / models_root / staging_root. Preview-first; confirmation
    token required.
#>

#region Params
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName='Check')]
    [switch]$Check,
    [Parameter(ParameterSetName='Json')]
    [switch]$Json,
    [Parameter(ParameterSetName='DetectGpu')]
    [switch]$DetectGpu,
    [Parameter(ParameterSetName='Install')]
    [switch]$Force,
    [Parameter(ParameterSetName='Install')]
    [string]$Model,

    [Parameter(ParameterSetName='ShowConfig')]
    [switch]$ShowConfig,

    [Parameter(ParameterSetName='SetJobsRoot')]
    [string]$SetJobsRoot,
    [Parameter(ParameterSetName='SetModelsRoot')]
    [string]$SetModelsRoot,
    [Parameter(ParameterSetName='SetModelsRoot')]
    [switch]$MoveModels,
    [Parameter(ParameterSetName='SetStagingRoot')]
    [string]$SetStagingRoot,
    [Parameter(ParameterSetName='SetDefaultModel')]
    [ValidateSet('large-v3','medium','small','base','tiny')]
    [string]$SetDefaultModel,
    [Parameter(ParameterSetName='SetAutoCleanupDays')]
    [int]$SetAutoCleanupDays = -1,
    [Parameter(ParameterSetName='UnsetAutoCleanupDays')]
    [switch]$UnsetAutoCleanupDays,

    [Parameter(ParameterSetName='ListJobs')]
    [switch]$ListJobs,
    [Parameter(ParameterSetName='ListModels')]
    [switch]$ListModels,

    [Parameter(ParameterSetName='PurgeJobs')]
    [switch]$PurgeJobs,
    [Parameter(ParameterSetName='PurgeJobs')]
    [int]$OlderThanDays = -1,
    [Parameter(ParameterSetName='PurgeJobs')]
    [switch]$DryRun,
    [Parameter(ParameterSetName='PurgeJobs')]
    [string]$ConfirmToken,

    [Parameter(ParameterSetName='PurgeJob')]
    [switch]$PurgeJob,
    [Parameter(ParameterSetName='PurgeJob')]
    [string]$Slug,
    [Parameter(ParameterSetName='PurgeJob')]
    [string]$JobConfirmToken,

    [Parameter(ParameterSetName='PurgeAllJobs')]
    [switch]$PurgeAllJobs,
    [Parameter(ParameterSetName='PurgeAllJobs')]
    [switch]$Confirm,
    [Parameter(ParameterSetName='PurgeAllJobs')]
    [string]$AllConfirmToken,

    [Parameter(ParameterSetName='RemoveModel')]
    [switch]$RemoveModel,
    [Parameter(ParameterSetName='RemoveModel')]
    [string]$ModelName
)
#endregion

#region Init
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\_lib.ps1"

$pluginRoot  = Split-Path -Parent $PSScriptRoot
$dockerDir   = Join-Path $pluginRoot 'docker'
$composeFile = Join-Path $dockerDir 'docker-compose.yml'
$workerDir   = Join-Path $PSScriptRoot 'worker'

function _EnsureConfig {
    $cfg = Get-WLConfig
    if (-not (Test-Path -LiteralPath $script:WL_CONFIG_FILE)) {
        Save-WLConfig $cfg
    }
    return $cfg
}
#endregion

#region Status
# Native commands routed to docker.exe occasionally write to stderr even on
# expected failures (e.g. "no such image"). Under StrictMode + Stop, that
# stderr becomes a terminating error. Lower ErrorActionPreference inside
# these helpers so they can return a plain bool.
function _TestImage([string]$tag) {
    $orig = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & docker image inspect $tag *>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $orig
    }
}
function _DockerCli { [bool](Get-Command docker -ErrorAction SilentlyContinue) }
function _DockerDaemon {
    $orig = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & docker info *>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $orig
    }
}

function _Status {
    $cfg = Get-WLConfig
    # Which whisper image counts as "present" depends on the detected mode.
    # Pre-upgrade configs have no gpu block yet: accept either variant so
    # existing installs don't get pushed through setup again (their first
    # /watch runs the one-time detection).
    $gpu = Get-WLObjectProp $cfg 'gpu'
    $whisperOk = if ($null -eq $gpu) {
        (_TestImage $script:WL_IMG_WHISPER) -or (_TestImage $script:WL_IMG_WHISPER_CPU)
    } else {
        _TestImage (Get-WLWhisperImage -GpuPresent ([bool](Get-WLObjectProp $gpu 'present')))
    }
    return [ordered]@{
        docker_cli     = _DockerCli
        docker_running = $(if (_DockerCli) { _DockerDaemon } else { $false })
        tools_image    = _TestImage $script:WL_IMG_TOOLS
        whisper_image  = $whisperOk
        marker         = (Test-Path -LiteralPath $script:WL_SETUP_MARKER)
        config         = $cfg
    }
}
#endregion

#region CheckMode
function _Check {
    $s = _Status
    if (-not $s.docker_cli)     { Write-Warn 'docker CLI not on PATH';                exit 2 }
    if (-not $s.docker_running) { Write-Warn 'Docker Desktop daemon not responding'; exit 3 }
    if (-not $s.tools_image)    { Write-Warn 'watch-local/tools image missing';      exit 4 }
    if (-not $s.whisper_image)  { Write-Warn 'watch-local/whisper image missing';    exit 4 }
    if (-not $s.marker)         { Write-Warn 'setup marker missing -- run setup.ps1'; exit 5 }
    exit 0
}
#endregion

#region JsonMode
function _Json {
    $s = _Status
    $obj = [pscustomobject]@{}
    foreach ($k in $s.Keys) { Add-Member -InputObject $obj -NotePropertyName $k -NotePropertyValue $s[$k] -Force }
    $obj | ConvertTo-Json -Depth 6 | Write-Output
    exit 0
}
#endregion

#region Install
function _AssertDockerForSetup {
    if (-not (_DockerCli)) {
        Write-Err 'docker CLI not found on PATH. Install Docker (Desktop on Windows/macOS, Engine on Linux): https://docs.docker.com/get-docker/'
        exit $script:WL_EXIT.DOCKER_MISSING
    }
    if (-not (_DockerDaemon)) {
        Write-Err 'Docker daemon not responding. Start Docker (Desktop) and re-run.'
        exit $script:WL_EXIT.DOCKER_DOWN
    }
}

function _BuildToolsImage {
    Write-Stage 'building tools image (CPU, small)...'
    $code = Invoke-WLCompose $composeFile 'build' 'tools'
    if ($code -ne 0) { Write-Err 'docker compose build tools failed'; exit $script:WL_EXIT.TOOLS_FAILED }
}

# Probe the GPU (through the tools image), persist the result in
# config.json, and narrate what was found. Returns the gpu object.
function _DetectAndSaveGpu([hashtable]$cfg) {
    Write-Stage 'detecting NVIDIA GPU through docker (10-30s)...'
    $gpu = Test-WLGpu
    $cfg.gpu = $gpu
    Save-WLConfig $cfg
    if ($gpu.present) {
        $nvdecLabel = if ($gpu.nvdec) { 'NVDEC video decode: OK' } else { 'NVDEC video decode: unavailable (CPU decode)' }
        Write-Stage ("GPU: {0} -- {1} MB VRAM, driver {2}, compute {3}. {4}" -f `
            $gpu.name, $gpu.vram_mb, $gpu.driver, $gpu.compute_cap, $nvdecLabel)
    } else {
        Write-Warn 'no NVIDIA GPU visible to Docker -- configuring CPU-only mode.'
        Write-Warn 'Whisper will run on CPU (int8). large-v3 is slow on CPU; consider -SetDefaultModel small.'
    }
    return $gpu
}

function _Install {
    if (-not $Model) { $Model = 'large-v3' }
    $cfg = _EnsureConfig

    Write-Stage 'watch-local setup'
    Write-Stage "plugin root: $pluginRoot"
    Write-Stage "jobs_root  : $($cfg.jobs_root)"
    Write-Stage "models_root: $($cfg.models_root)"

    _AssertDockerForSetup
    Write-Stage 'docker CLI + daemon OK'

    # Tools image first: the GPU probe runs inside it.
    _BuildToolsImage
    $gpu = _DetectAndSaveGpu $cfg
    $gpuPresent = [bool]$gpu.present

    if ($gpuPresent) {
        Write-Stage 'building whisper image (CUDA 12.8, ~6 GB -- first build can take 5-15 min)...'
        $code = Invoke-WLCompose $composeFile 'build' 'whisper'
    } else {
        Write-Stage 'building whisper CPU image (no CUDA, ~1 GB)...'
        $code = Invoke-WLCompose $composeFile 'build' 'whisper-cpu'
    }
    if ($code -ne 0) { Write-Err 'docker compose build whisper failed'; exit $script:WL_EXIT.WHISPER_FAILED }

    Write-Stage "warming model cache for $Model (downloads ~3 GB on first run)..."
    $warmDir = Join-Path $script:WL_BASE_DIR 'warm'
    New-Item -ItemType Directory -Force -Path $warmDir | Out-Null

    try {
        # Plain `docker run` -- compose run deadlocks at container-start on
        # WSL2 (see Invoke-WLRun docs in _lib.ps1). Build still uses compose.
        $code = Invoke-WLRun (@(
            '-v', "$(ConvertTo-DockerPath $warmDir):/work",
            $script:WL_IMG_TOOLS, 'ffmpeg', '-hide_banner', '-loglevel', 'error',
            '-f', 'lavfi', '-i', 'anullsrc=cl=mono:r=16000', '-t', '1', '-b:a', '64k', '/work/audio.mp3'
        )) -Name 'warmup-audio'
        if ($code -ne 0) { throw "warm-up audio build failed (exit $code)" }

        $code = Invoke-WLRun ((Get-WLWhisperRunFlags -GpuPresent $gpuPresent) + @(
            '-e', "W_MODEL=$Model",
            '-v', "$(ConvertTo-DockerPath $warmDir):/work",
            '-v', "$(ConvertTo-DockerPath $cfg.models_root):/models",
            '-v', "$(ConvertTo-DockerPath $workerDir):/app:ro",
            (Get-WLWhisperImage -GpuPresent $gpuPresent), 'python3', '/app/whisper_run.py'
        )) -Name 'warmup-whisper'
        if ($code -ne 0) {
            Write-Warn "model warm-up returned exit $code -- first /watch may pull the model on demand."
        }
    } catch {
        Write-Warn "model warm-up failed: $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $warmDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Set-Content -LiteralPath $script:WL_SETUP_MARKER -Value (Get-Date -Format o) -NoNewline
    $modeLabel = if ($gpuPresent) { 'GPU mode' } else { 'CPU-only mode' }
    Write-Stage "setup complete ($modeLabel). /watch is ready."
    exit 0
}
#endregion

#region DetectGpuCmd
# Standalone re-probe: `setup.ps1 -DetectGpu`. Builds the tools image first
# if missing (the probe runs inside it), persists the result, prints JSON.
function _DetectGpuCmd {
    $cfg = _EnsureConfig
    _AssertDockerForSetup
    if (-not (_TestImage $script:WL_IMG_TOOLS)) { _BuildToolsImage }
    $gpu = _DetectAndSaveGpu $cfg
    $gpu | ConvertTo-Json | Write-Output
    exit 0
}
#endregion

#region ConfigSetters
function _ShowConfig {
    $cfg = Get-WLConfig
    $obj = [pscustomobject]@{}
    foreach ($k in $cfg.Keys) { Add-Member -InputObject $obj -NotePropertyName $k -NotePropertyValue $cfg[$k] -Force }
    $obj | ConvertTo-Json -Depth 4 | Write-Output
    exit 0
}

function _SetPath([string]$key, [string]$value) {
    $cfg = _EnsureConfig
    try { $resolved = Resolve-ConfigPath $value } catch { Write-Err $_.Exception.Message; exit 2 }
    $cfg[$key] = $resolved
    Save-WLConfig $cfg
    Write-Stage "$key set to $resolved"
}

function _SetJobsRoot     { _SetPath 'jobs_root'   $SetJobsRoot; exit 0 }
function _SetStagingRoot  { _SetPath 'staging_root' $SetStagingRoot; exit 0 }

function _SetModelsRoot {
    $cfg = _EnsureConfig
    try { $resolved = Resolve-ConfigPath $SetModelsRoot } catch { Write-Err $_.Exception.Message; exit 2 }
    $old = [string]$cfg.models_root
    $hasFiles = (Test-Path -LiteralPath $old) -and ((Get-ChildItem -LiteralPath $old -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1) -ne $null)
    if ($hasFiles -and -not $MoveModels) {
        Write-Err "existing model cache present at $old. Pass -MoveModels to relocate it."
        exit 2
    }
    if ($hasFiles -and $MoveModels) {
        Write-Stage "moving existing models from $old to $resolved..."
        Get-ChildItem -LiteralPath $old -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Move-Item -LiteralPath $_.FullName -Destination $resolved -Force
        }
    }
    $cfg.models_root = $resolved
    Save-WLConfig $cfg
    Write-Stage "models_root set to $resolved"
    exit 0
}
function _SetDefaultModelCmd {
    $cfg = _EnsureConfig
    $cfg.default_model = $SetDefaultModel
    Save-WLConfig $cfg
    Write-Stage "default_model set to $SetDefaultModel"
    exit 0
}
function _SetAutoCleanupDaysCmd {
    if ($SetAutoCleanupDays -lt 1) {
        Write-Err 'auto_cleanup_days must be >= 1. Use -UnsetAutoCleanupDays to disable.'
        exit 2
    }
    $cfg = _EnsureConfig
    $cfg.auto_cleanup_days = $SetAutoCleanupDays
    Save-WLConfig $cfg
    Write-Stage "auto_cleanup_days set to $SetAutoCleanupDays (WARNING only -- never auto-deletes)"
    exit 0
}
function _UnsetAutoCleanupDaysCmd {
    $cfg = _EnsureConfig
    $cfg.auto_cleanup_days = $null
    Save-WLConfig $cfg
    Write-Stage 'auto_cleanup_days disabled'
    exit 0
}
#endregion

#region ListReadOnly
function _ListJobs {
    $cfg = _EnsureConfig
    $root = [string]$cfg.jobs_root
    if (-not (Test-Path -LiteralPath $root)) {
        Write-Output "jobs_root does not exist yet: $root"
        exit 0
    }
    $rows = @()
    $totalBytes = 0
    foreach ($d in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
        $size = 0
        try {
            $size = (Get-ChildItem -LiteralPath $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            if (-not $size) { $size = 0 }
        } catch { }
        $totalBytes += $size
        $source = '(unknown)'
        $intPath = Join-Path $d.FullName 'intermediate.json'
        if (Test-Path -LiteralPath $intPath) {
            try {
                $j = Read-UTF8 $intPath | ConvertFrom-Json
                $source = $j.source
            } catch { }
        }
        $age = ((Get-Date) - $d.LastWriteTime).Days
        $rows += [pscustomobject]@{ Slug = $d.Name; AgeDays = $age; SizeMB = [math]::Round($size / 1MB, 1); Source = $source }
    }
    Write-Output ("jobs_root: $root")
    Write-Output ("total: {0} jobs, {1:N1} GB" -f $rows.Count, ($totalBytes / 1GB))
    $rows | Sort-Object AgeDays -Descending | Format-Table -AutoSize | Out-String | Write-Output
    exit 0
}

function _ListModels {
    $cfg = _EnsureConfig
    $root = [string]$cfg.models_root
    if (-not (Test-Path -LiteralPath $root)) {
        Write-Output "models_root does not exist yet: $root"
        exit 0
    }
    $hub = Join-Path (Join-Path $root 'hf-cache') 'hub'
    if (-not (Test-Path -LiteralPath $hub)) {
        Write-Output "no HF cache yet under $root"
        exit 0
    }
    $rows = @()
    foreach ($d in Get-ChildItem -LiteralPath $hub -Directory -ErrorAction SilentlyContinue) {
        if (-not $d.Name.StartsWith('models--')) { continue }
        $size = (Get-ChildItem -LiteralPath $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        if (-not $size) { $size = 0 }
        $rows += [pscustomobject]@{
            Model  = $d.Name.Substring('models--'.Length)
            SizeGB = [math]::Round($size / 1GB, 2)
            Path   = $d.FullName
        }
    }
    Write-Output ("models_root: $root")
    $rows | Sort-Object SizeGB -Descending | Format-Table -AutoSize | Out-String | Write-Output
    exit 0
}
#endregion

#region PurgeCore
function _PreviewAndConfirm {
    param(
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$FilterLabel,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Targets,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Kept,
        [Parameter(Mandatory)][string]$TokenPrefix,
        [string]$NonInteractiveToken = $null
    )
    $bytes = 0
    foreach ($t in $Targets) { $bytes += $t.SizeBytes }
    # Seed the token with the exact target set so preview run + confirm run
    # (two separate non-interactive invocations) agree on the token.
    $token = New-ConfirmToken $TokenPrefix -Seed (($Targets | ForEach-Object { $_.Path }) -join '|')

    [Console]::Error.WriteLine('================================')
    [Console]::Error.WriteLine(' PURGE PREVIEW -- REVIEW CAREFULLY')
    [Console]::Error.WriteLine('================================')
    [Console]::Error.WriteLine(" Scope:   $Scope        ($Root)")
    [Console]::Error.WriteLine(" Filter:  $FilterLabel")
    [Console]::Error.WriteLine(" Found:   $($Targets.Count) items, $([math]::Round($bytes / 1GB, 2)) GB")
    if ($Targets.Count -gt 0) {
        [Console]::Error.WriteLine('')
        [Console]::Error.WriteLine(' Items that will be DELETED:')
        foreach ($t in $Targets) {
            [Console]::Error.WriteLine("   - $($t.Path)  ($([math]::Round($t.SizeBytes / 1MB, 1)) MB)")
        }
    }
    if ($Kept.Count -gt 0) {
        [Console]::Error.WriteLine('')
        [Console]::Error.WriteLine(' Items that will be KEPT:')
        foreach ($k in $Kept) { [Console]::Error.WriteLine("   - $($k.Path)") }
    }
    [Console]::Error.WriteLine('')
    [Console]::Error.WriteLine(" Nothing outside $Root is touched.")
    [Console]::Error.WriteLine(" To proceed, type:  $token")
    [Console]::Error.WriteLine('================================')

    if ($Targets.Count -eq 0) { return $false }
    return (Request-Confirm -ExpectedToken $token -NonInteractiveToken $NonInteractiveToken)
}

function _GatherJobDirs {
    param([string]$Root, [int]$OlderThanDays)
    $cutoff = $null
    if ($OlderThanDays -ge 0) { $cutoff = (Get-Date).AddDays(-$OlderThanDays) }
    $targets = @()
    $kept    = @()
    foreach ($d in Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue) {
        try { Assert-InsideRoot -Target $d.FullName -Root $Root } catch { continue }
        $size = 0
        try { $size = (Get-ChildItem -LiteralPath $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } catch { }
        if (-not $size) { $size = 0 }
        $info = [pscustomobject]@{ Path = $d.FullName; SizeBytes = [int64]$size }
        if ($null -eq $cutoff -or $d.LastWriteTime -lt $cutoff) { $targets += $info } else { $kept += $info }
    }
    return @{ Targets = $targets; Kept = $kept }
}
#endregion

#region PurgeJobsCmd
function _PurgeJobsCmd {
    if ($OlderThanDays -lt 0) {
        Write-Err 'specify -OlderThanDays N (no default -- explicit scope required).'
        exit $script:WL_EXIT.PURGE_REFUSED
    }
    $cfg = _EnsureConfig
    $root = [string]$cfg.jobs_root
    if (-not (Test-Path -LiteralPath $root)) { Write-Output 'jobs_root does not exist -- nothing to purge.'; exit 0 }
    $gathered = _GatherJobDirs -Root $root -OlderThanDays $OlderThanDays
    if ($DryRun) {
        [void](_PreviewAndConfirm -Scope 'jobs' -Root $root `
            -FilterLabel "-OlderThanDays $OlderThanDays  (DRY RUN -- nothing deleted)" `
            -Targets $gathered.Targets -Kept $gathered.Kept -TokenPrefix 'PURGE-JOBS' -NonInteractiveToken 'DRY')
        exit 0
    }
    $proceed = _PreviewAndConfirm -Scope 'jobs' -Root $root `
        -FilterLabel "-OlderThanDays $OlderThanDays" `
        -Targets $gathered.Targets -Kept $gathered.Kept -TokenPrefix 'PURGE-JOBS' `
        -NonInteractiveToken $ConfirmToken
    if (-not $proceed) { Write-Stage 'purge cancelled.'; exit $script:WL_EXIT.PURGE_REFUSED }
    foreach ($t in $gathered.Targets) {
        try {
            Assert-InsideRoot -Target $t.Path -Root $root
            Remove-Item -LiteralPath $t.Path -Recurse -Force
            Write-Stage "removed $($t.Path)"
        } catch {
            Write-Warn "failed to remove $($t.Path): $($_.Exception.Message)"
        }
    }
    exit 0
}
#endregion

#region PurgeJobCmd
function _PurgeJobCmd {
    if (-not $Slug) { Write-Err 'specify -Slug.'; exit $script:WL_EXIT.PURGE_REFUSED }
    $cfg = _EnsureConfig
    $root = [string]$cfg.jobs_root
    $target = Join-Path $root $Slug
    if (-not (Test-Path -LiteralPath $target)) { Write-Err "job not found: $Slug"; exit $script:WL_EXIT.SOURCE_BAD }
    try { Assert-InsideRoot -Target $target -Root $root } catch { exit $script:WL_EXIT.PURGE_REFUSED }
    $size = (Get-ChildItem -LiteralPath $target -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    $proceed = _PreviewAndConfirm -Scope 'jobs' -Root $root `
        -FilterLabel "-Slug $Slug" `
        -Targets @([pscustomobject]@{ Path = $target; SizeBytes = [int64]$size }) `
        -Kept @() -TokenPrefix 'PURGE-JOB' -NonInteractiveToken $JobConfirmToken
    if (-not $proceed) { Write-Stage 'purge cancelled.'; exit $script:WL_EXIT.PURGE_REFUSED }
    Remove-Item -LiteralPath $target -Recurse -Force
    Write-Stage "removed $target"
    exit 0
}
#endregion

#region PurgeAllCmd
function _PurgeAllJobsCmd {
    if (-not $Confirm) {
        Write-Err 'refused: pass -Confirm to indicate intent.'
        exit $script:WL_EXIT.PURGE_REFUSED
    }
    if ($env:WATCH_LOCAL_I_REALLY_MEAN_IT -ne '1') {
        Write-Err 'refused: this command also requires the env var WATCH_LOCAL_I_REALLY_MEAN_IT=1. Set it in your shell before re-running.'
        exit $script:WL_EXIT.PURGE_REFUSED
    }
    $cfg = _EnsureConfig
    $root = [string]$cfg.jobs_root
    if (-not (Test-Path -LiteralPath $root)) { Write-Output 'jobs_root does not exist -- nothing to purge.'; exit 0 }
    $gathered = _GatherJobDirs -Root $root -OlderThanDays -1
    $proceed = _PreviewAndConfirm -Scope 'jobs' -Root $root `
        -FilterLabel 'ALL JOBS' `
        -Targets $gathered.Targets -Kept @() `
        -TokenPrefix 'PURGE-ALL' -NonInteractiveToken $AllConfirmToken
    if (-not $proceed) { Write-Stage 'purge cancelled.'; exit $script:WL_EXIT.PURGE_REFUSED }
    foreach ($t in $gathered.Targets) {
        try {
            Assert-InsideRoot -Target $t.Path -Root $root
            Remove-Item -LiteralPath $t.Path -Recurse -Force
            Write-Stage "removed $($t.Path)"
        } catch {
            Write-Warn "failed to remove $($t.Path): $($_.Exception.Message)"
        }
    }
    exit 0
}
#endregion

#region RemoveModelCmd
function _RemoveModelCmd {
    if (-not $ModelName) { Write-Err 'specify -ModelName.'; exit $script:WL_EXIT.PURGE_REFUSED }
    $cfg = _EnsureConfig
    $root = [string]$cfg.models_root
    $hub = Join-Path (Join-Path $root 'hf-cache') 'hub'
    $target = $null
    foreach ($d in Get-ChildItem -LiteralPath $hub -Directory -ErrorAction SilentlyContinue) {
        if ($d.Name -eq "models--$ModelName" -or $d.Name -like "models--*$ModelName") {
            $target = $d.FullName
            break
        }
    }
    if (-not $target) { Write-Err "no cached model matches '$ModelName' under $hub"; exit $script:WL_EXIT.SOURCE_BAD }
    try { Assert-InsideRoot -Target $target -Root $root } catch { exit $script:WL_EXIT.PURGE_REFUSED }
    $size = (Get-ChildItem -LiteralPath $target -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    $proceed = _PreviewAndConfirm -Scope 'models' -Root $root `
        -FilterLabel "-ModelName $ModelName" `
        -Targets @([pscustomobject]@{ Path = $target; SizeBytes = [int64]$size }) `
        -Kept @() -TokenPrefix 'PURGE-MODEL'
    if (-not $proceed) { Write-Stage 'purge cancelled.'; exit $script:WL_EXIT.PURGE_REFUSED }
    Remove-Item -LiteralPath $target -Recurse -Force
    Write-Stage "removed $target"
    exit 0
}
#endregion

#region Dispatch
switch ($PSCmdlet.ParameterSetName) {
    'Check'                  { _Check }
    'Json'                   { _Json }
    'DetectGpu'              { _DetectGpuCmd }
    'ShowConfig'             { _ShowConfig }
    'SetJobsRoot'            { _SetJobsRoot }
    'SetStagingRoot'         { _SetStagingRoot }
    'SetModelsRoot'          { _SetModelsRoot }
    'SetDefaultModel'        { _SetDefaultModelCmd }
    'SetAutoCleanupDays'     { _SetAutoCleanupDaysCmd }
    'UnsetAutoCleanupDays'   { _UnsetAutoCleanupDaysCmd }
    'ListJobs'               { _ListJobs }
    'ListModels'             { _ListModels }
    'PurgeJobs'              { _PurgeJobsCmd }
    'PurgeJob'               { _PurgeJobCmd }
    'PurgeAllJobs'           { _PurgeAllJobsCmd }
    'RemoveModel'            { _RemoveModelCmd }
    'Install'                { _Install }
}
#endregion
