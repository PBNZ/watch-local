#requires -Version 5.1
<#
.SYNOPSIS
    Interactive first-run wizard for /watch-setup.

.DESCRIPTION
    Steps (each is preview + optional skip):
        1. Verify Docker + GPU.
        2. Show / confirm config locations (jobs_root, models_root, staging_root).
        3. Pick whisper model. Default = large-v3 (best quality, ~3 GB pull).
        4. Build images + warm model cache (delegates to setup.ps1).
        5. Smoke test against a known-short public video.
        6. Print "you're ready" summary.

    Non-interactive: pass -Yes to accept every default and skip the smoke
    test prompt.
#>

#region Params
[CmdletBinding()]
param(
    [ValidateSet('large-v3','medium','small','base','tiny')]
    [string]$Model,
    [string]$JobsRoot,
    [string]$ModelsRoot,
    [string]$StagingRoot,
    [switch]$SkipSmoke,
    [switch]$Yes
)
#endregion

#region Init
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\_lib.ps1"

$setupScript = Join-Path $PSScriptRoot 'setup.ps1'
$watchScript = Join-Path $PSScriptRoot 'watch.ps1'

# The wizard reads stdin. Under a non-interactive host (agent shell tool,
# CI) ReadLine blocks forever on redirected-but-open stdin -- fail fast
# with the flag-driven alternative instead of hanging.
if (-not $Yes -and [Console]::IsInputRedirected) {
    Write-Err 'non-interactive session detected (stdin is redirected) -- the wizard cannot prompt.'
    Write-Err 'Re-run with -Yes to accept all defaults (add -Model <name> / -SkipSmoke as needed),'
    Write-Err "or use `"$setupScript`" -Check for a status probe."
    exit 2
}

function _Prompt([string]$prompt, [string]$default) {
    if ($Yes) { return $default }
    [Console]::Error.Write("$prompt [default: $default] ")
    $reply = [Console]::ReadLine()
    if ([string]::IsNullOrWhiteSpace($reply)) { return $default }
    return $reply.Trim()
}

function _PromptYN([string]$prompt, [bool]$default) {
    if ($Yes) { return $default }
    $tag = if ($default) { 'Y/n' } else { 'y/N' }
    [Console]::Error.Write("$prompt [$tag] ")
    $reply = [Console]::ReadLine()
    if ([string]::IsNullOrWhiteSpace($reply)) { return $default }
    return ($reply.Trim().ToLower() -in @('y','yes'))
}
#endregion

Write-Output ''
Write-Output '# /watch-setup -- watch-local onboarding'
Write-Output ''
Write-Output 'This walks you through first-time setup of watch-local. Three GPU-heavy'
Write-Output 'steps are involved (build whisper image, download model, smoke test).'
Write-Output ''

#region Step1_Docker
Write-Output '## Step 1: Docker + GPU'
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Err 'docker CLI not on PATH. Install Docker Desktop: https://www.docker.com/products/docker-desktop/'
    exit $script:WL_EXIT.DOCKER_MISSING
}
& docker info 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Err 'Docker Desktop daemon not responding. Start Docker Desktop and re-run /watch-setup.'
    exit $script:WL_EXIT.DOCKER_DOWN
}
Write-Output 'Docker CLI + daemon -- OK'

Write-Output 'Probing GPU exposure to Docker (10-20s)...'
& docker run --rm --name "watch-local-gpucheck-$(Get-Random -Maximum 99999)" --gpus all nvidia/cuda:12.8.0-base-ubuntu22.04 nvidia-smi -L 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Err 'Docker cannot see your NVIDIA GPU. Steps to fix:'
    Write-Err '  1. Install the latest NVIDIA Game Ready / Studio driver.'
    Write-Err '  2. In Docker Desktop -> Settings -> General, enable WSL2 backend.'
    Write-Err '  3. Restart Docker Desktop, then re-run /watch-setup.'
    exit $script:WL_EXIT.GPU_MISSING
}
Write-Output 'NVIDIA GPU visible to Docker -- OK'
Write-Output ''
#endregion

#region Step2_Config
Write-Output '## Step 2: Storage locations'
$cfg = Get-WLConfig
$jobs    = if ($JobsRoot)    { $JobsRoot }    else { _Prompt 'jobs_root (per-job artifacts)'        ([string]$cfg.jobs_root) }
$models  = if ($ModelsRoot)  { $ModelsRoot }  else { _Prompt 'models_root (whisper model cache)'    ([string]$cfg.models_root) }
$staging = if ($StagingRoot) { $StagingRoot } else { _Prompt 'staging_root (UNC stage temp)'        ([string]$cfg.staging_root) }

foreach ($p in @($jobs, $models, $staging)) {
    if (-not (Test-Path -LiteralPath $p)) {
        New-Item -ItemType Directory -Force -Path $p | Out-Null
    }
}
$cfg.jobs_root    = (Resolve-ConfigPath $jobs)
$cfg.models_root  = (Resolve-ConfigPath $models)
$cfg.staging_root = (Resolve-ConfigPath $staging)
Save-WLConfig $cfg
Write-Output "jobs_root    = $($cfg.jobs_root)"
Write-Output "models_root  = $($cfg.models_root)"
Write-Output "staging_root = $($cfg.staging_root)"
Write-Output ''
#endregion

#region Step3_Model
Write-Output '## Step 3: Whisper model'
Write-Output 'Models in order of quality (and size):'
Write-Output '  large-v3  ~3.0 GB     best quality (recommended)'
Write-Output '  medium    ~1.5 GB     good quality, faster'
Write-Output '  small     ~500 MB     decent for English-heavy content'
Write-Output '  base      ~150 MB     fast smoke testing'
Write-Output '  tiny      ~75 MB      smoke testing only'
$pickedModel = if ($Model) { $Model } else { _Prompt 'Which model?' 'large-v3' }
$cfg.default_model = $pickedModel
Save-WLConfig $cfg
Write-Output "default_model = $pickedModel"
Write-Output ''
#endregion

#region Step4_Build
Write-Output '## Step 4: Build images + warm model cache'
Write-Output 'First build is the slow part (whisper image ~5-15 min, model ~3 GB pull).'
$go = _PromptYN 'Proceed?' $true
if (-not $go) {
    Write-Err 'cancelled.'
    exit 0
}
$_eapOrig = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try {
    & powershell.exe -ExecutionPolicy Bypass -File $setupScript -Model $pickedModel
    $setupCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $_eapOrig
}
if ($setupCode -ne 0) {
    Write-Err "setup.ps1 failed (exit $setupCode) -- fix and re-run /watch-setup."
    exit $setupCode
}
Write-Output ''
#endregion

#region Step5_Smoke
if (-not $SkipSmoke -and -not $Yes) {
    $doSmoke = _PromptYN 'Run a 30-second smoke test against a short public video?' $true
    if ($doSmoke) {
        Write-Output '## Step 5: Smoke test'
        # Short, captions-bearing, very low-risk URL. Brad's own /watch demo.
        $smokeUrl = 'https://www.youtube.com/watch?v=QZMljuD10sU'
        $_eapOrig = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            & powershell.exe -ExecutionPolicy Bypass -File $watchScript -Source $smokeUrl -MaxFrames 4 -NoCompare
            $smokeCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $_eapOrig
        }
        if ($smokeCode -ne 0) {
            Write-Warn "smoke test exited $smokeCode -- inspect output above."
        } else {
            Write-Output ''
            Write-Output 'Smoke test passed.'
        }
    }
}
#endregion

#region Step6_Summary
Write-Output ''
Write-Output '## Setup complete.'
Write-Output ''
Write-Output 'Usage:'
Write-Output '  /watch <url-or-path> [question]'
Write-Output '  /watch:save-here                     # promote last job to CWD'
Write-Output ''
Write-Output 'Inspect or change settings:'
Write-Output "  powershell -File `"$setupScript`" -ShowConfig"
Write-Output "  powershell -File `"$setupScript`" -SetDefaultModel medium"
Write-Output "  powershell -File `"$setupScript`" -ListJobs"
Write-Output ''
Write-Output 'Disk-space pre-flight runs on every /watch call. Cleanup is opt-in:'
Write-Output "  /watch ... -Cleanup                              # delete this job's dir when done"
Write-Output "  powershell -File `"$setupScript`" -PurgeJobs -OlderThanDays 30"
Write-Output ''
#endregion
exit 0
