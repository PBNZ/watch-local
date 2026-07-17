#requires -Version 5.1
<#
.SYNOPSIS
    Preflight, install, config, and maintenance for watch-local.

.DESCRIPTION
    Modes (mutually exclusive top-level switches):
        -Check                    silent preflight, non-zero exit on miss
        -Json                     machine-readable status snapshot
        -DetectGpu                (re-)probe NVIDIA GPU + NVDEC, persist to config
        -Install (default)        provision portable runtime, detect GPU, warm model
        -UpdateRuntime            re-converge runtime to the pinned manifest
        -UpdateYtDlp              yt-dlp self-update (YouTube breakage fixes)
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
        -PurgeStaging [-StagingConfirmToken T]        (leftover staged UNC copies)
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

    [Parameter(ParameterSetName='UpdateRuntime')]
    [switch]$UpdateRuntime,
    [Parameter(ParameterSetName='UpdateYtDlp')]
    [switch]$UpdateYtDlp,

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

    [Parameter(ParameterSetName='PurgeStaging')]
    [switch]$PurgeStaging,
    [Parameter(ParameterSetName='PurgeStaging')]
    [string]$StagingConfirmToken,

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

$pluginRoot = Split-Path -Parent $PSScriptRoot

function _EnsureConfig {
    $cfg = Get-WLConfig
    if (-not (Test-Path -LiteralPath $script:WL_CONFIG_FILE)) {
        Save-WLConfig $cfg
    }
    return $cfg
}
#endregion

#region Status
function _Status {
    $cfg = Get-WLConfig
    $rt = Test-WLRuntime
    return [ordered]@{
        runtime = $rt
        marker  = (Test-Path -LiteralPath $script:WL_SETUP_MARKER)
        config  = $cfg
    }
}
#endregion

#region CheckMode
function _Check {
    $s = _Status
    if (-not $s.runtime.provisioned) { Write-Warn 'runtime not provisioned -- run setup.ps1'; exit 2 }
    if (-not $s.runtime.ok)          { Write-Warn 'runtime incomplete -- run setup.ps1 -UpdateRuntime'; exit 4 }
    if (-not $s.marker)              { Write-Warn 'setup marker missing -- run setup.ps1'; exit 5 }
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
# Probe the GPU natively (host nvidia-smi + portable-ffmpeg NVDEC test),
# persist the result in config.json, and narrate what was found. Call
# only after Install-WLRuntimeBinaries (the NVDEC leg needs ffmpeg).
function _DetectAndSaveGpu([hashtable]$cfg) {
    Write-Stage 'detecting NVIDIA GPU (host nvidia-smi + NVDEC probe)...'
    $gpu = Test-WLGpuNative
    $cfg.gpu = $gpu
    Save-WLConfig $cfg
    if ($gpu.present) {
        $nvdecLabel = if ($gpu.nvdec) { 'NVDEC video decode: OK' } else { 'NVDEC video decode: unavailable (CPU decode)' }
        Write-Stage ("GPU: {0} -- {1} MB VRAM, driver {2}, compute {3}. {4}" -f `
            $gpu.name, $gpu.vram_mb, $gpu.driver, $gpu.compute_cap, $nvdecLabel)
    } else {
        Write-Warn 'no NVIDIA GPU detected -- configuring CPU-only mode.'
        Write-Warn 'Whisper will run on CPU (int8). large-v3 is slow on CPU; consider -SetDefaultModel small.'
    }
    return $gpu
}

# Probe venv-level CUDA (ctranslate2 reaching the GPU through the pip
# wheels), persist as gpu.cuda_whisper, narrate. Call after
# Install-WLRuntimePython.
function _ProbeAndSaveCudaWhisper([hashtable]$cfg, $gpu) {
    $cw = if ([bool](Get-WLObjectProp $gpu 'present')) { Test-WLCudaWhisper } else { $false }
    $cfg.gpu = Set-WLGpuCudaWhisper -Gpu $gpu -Value $cw
    Save-WLConfig $cfg
    if ([bool](Get-WLObjectProp $gpu 'present')) {
        if ($cw) { Write-Stage 'CUDA whisper: OK (float16)' }
        else { Write-Warn 'GPU present but ctranslate2 cannot reach CUDA -- whisper will run on CPU (int8). Check the VC++ runtime, then setup.ps1 -UpdateRuntime.' }
    }
    return $cfg.gpu
}

# Warm the whisper model cache: 1s of silence through the real worker so
# faster-whisper downloads the model into models_root\hf-cache.
function _WarmModel([hashtable]$cfg, $gpu, [string]$ModelName) {
    Write-Stage "warming model cache for $ModelName (downloads the model on first run)..."
    $warmDir = Join-Path $script:WL_BASE_DIR 'warm'
    New-Item -ItemType Directory -Force -Path $warmDir | Out-Null
    try {
        $ffmpeg = Get-WLFfmpegBin
        $orig = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'anullsrc=cl=mono:r=16000' -t 1 -b:a 64k (Join-Path $warmDir 'audio.mp3') 2>&1 | Out-Null
            $code = $LASTEXITCODE
        } finally { $ErrorActionPreference = $orig }
        if ($code -ne 0) { throw "warm-up audio build failed (exit $code)" }

        $warmEnv = (Get-WLWhisperWorkerEnv -Gpu $gpu -ModelsRoot ([string]$cfg.models_root)) + @{
            W_WORK_DIR = $warmDir
            W_MODEL    = $ModelName
        }
        $code = Invoke-WLWorker -Script 'whisper_run.py' -EnvVars $warmEnv -Name 'warmup-whisper'
        if ($code -ne 0) {
            Write-Warn "model warm-up returned exit $code -- first /watch may pull the model on demand."
        }
    } catch {
        Write-Warn "model warm-up failed: $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $warmDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function _Install {
    if (-not $Model) { $Model = 'large-v3' }
    $cfg = _EnsureConfig

    Write-Stage 'watch-local setup'
    Write-Stage "plugin root: $pluginRoot"
    Write-Stage "jobs_root  : $($cfg.jobs_root)"
    Write-Stage "models_root: $($cfg.models_root)"

    # Binaries first: the NVDEC leg of GPU detection needs ffmpeg.
    Write-Stage 'provisioning portable runtime (yt-dlp, ffmpeg, deno, uv)...'
    Install-WLRuntimeBinaries -Force:$Force

    $gpu = _DetectAndSaveGpu $cfg
    $gpuPresent = [bool]$gpu.present

    Install-WLRuntimePython -GpuPresent $gpuPresent
    $gpu = _ProbeAndSaveCudaWhisper $cfg $gpu
    Save-WLRuntimeState -GpuPresent $gpuPresent | Out-Null

    _WarmModel $cfg $gpu $Model

    Set-Content -LiteralPath $script:WL_SETUP_MARKER -Value (Get-Date -Format o) -NoNewline
    $modeLabel = if ($gpuPresent) { 'GPU mode' } else { 'CPU-only mode' }
    Write-Stage "setup complete ($modeLabel). /watch is ready."
    exit 0
}
#endregion

#region DetectGpuCmd
# Standalone re-probe: `setup.ps1 -DetectGpu`. Provisions the runtime
# binaries first if missing (the NVDEC probe needs the portable ffmpeg),
# persists the result, prints JSON.
function _DetectGpuCmd {
    $cfg = _EnsureConfig
    if (-not (Test-Path -LiteralPath (Get-WLFfmpegBin))) {
        Write-Stage 'portable ffmpeg missing -- provisioning runtime binaries first...'
        Install-WLRuntimeBinaries
    }
    $gpu = _DetectAndSaveGpu $cfg
    # Refresh cuda_whisper too when the venv exists (no-op otherwise).
    if (Test-Path -LiteralPath (Get-WLWorkerPython)) {
        $gpu = _ProbeAndSaveCudaWhisper $cfg $gpu
    }
    $gpu | ConvertTo-Json | Write-Output
    exit 0
}
#endregion

#region UpdateCmds
# Re-converge the runtime to the pinned manifest (new pins after a plugin
# update, or repair a broken tree). GPU wheel choice follows the recorded
# detection; re-run -DetectGpu first after hardware changes.
function _UpdateRuntimeCmd {
    $cfg = _EnsureConfig
    $gpu = Get-WLObjectProp $cfg 'gpu'
    $gpuPresent = [bool](Get-WLObjectProp $gpu 'present')
    Install-WLRuntime -GpuPresent $gpuPresent -Force | Out-Null
    if ($null -ne $gpu) { [void](_ProbeAndSaveCudaWhisper $cfg $gpu) }
    Write-Stage 'runtime updated.'
    exit 0
}

function _UpdateYtDlpCmd {
    exit (Update-WLYtDlp)
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
    $rtSize = Get-WLRuntimeSizeGB
    if ($rtSize) { Write-Output ("runtime: {0:N2} GB under {1}" -f $rtSize, $script:WL_RUNTIME_DIR) }
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

#region PurgeStagingCmd
# Staged UNC copies are transient by design (reclaimed at end-of-run), so
# anything under staging_root is a leftover from a killed run or an older
# plugin version -- no age filter; every child dir is a target.
function _PurgeStagingCmd {
    $cfg = _EnsureConfig
    $root = [string]$cfg.staging_root
    if (-not (Test-Path -LiteralPath $root)) { Write-Output 'staging_root does not exist -- nothing to purge.'; exit 0 }
    $gathered = _GatherJobDirs -Root $root -OlderThanDays -1
    $proceed = _PreviewAndConfirm -Scope 'staging' -Root $root `
        -FilterLabel 'ALL STAGED LEFTOVERS' `
        -Targets $gathered.Targets -Kept @() `
        -TokenPrefix 'PURGE-STAGE' -NonInteractiveToken $StagingConfirmToken
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
    'UpdateRuntime'          { _UpdateRuntimeCmd }
    'UpdateYtDlp'            { _UpdateYtDlpCmd }
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
    'PurgeStaging'           { _PurgeStagingCmd }
    'RemoveModel'            { _RemoveModelCmd }
    'Install'                { _Install }
}
#endregion
