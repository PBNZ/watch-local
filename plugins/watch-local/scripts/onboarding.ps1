#requires -Version 5.1
<#
.SYNOPSIS
    Interactive first-run wizard for /watch-setup.

.DESCRIPTION
    Steps (each is preview + optional skip):
        1. Provision portable runtime binaries + GPU detection.
        2. Show / confirm config locations (jobs_root, models_root, staging_root).
        3. Pick whisper model. Default = large-v3 (best quality, ~3 GB pull).
        4. Install python/venv + warm model cache (delegates to setup.ps1).
        5. Smoke test against a known-short public video.
        6. Print "you're ready" summary.

    No Docker, no admin rights: everything lands under the watch-local
    state root and is removed by deleting that one folder.

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

# Spawn a child script with the same engine that runs us (powershell.exe /
# pwsh), with EAP lowered so native stderr doesn't terminate the wizard.
function _RunChild([string]$scriptPath, [string[]]$childArgs) {
    $engine = Get-WLPSEngine
    $flags = @('-NoProfile')
    if ($script:WL_IS_WINDOWS) { $flags += @('-ExecutionPolicy', 'Bypass') }
    $_eapOrig = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        & $engine @flags -File $scriptPath @childArgs
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $_eapOrig
    }
}
#endregion

Write-Output ''
Write-Output '# /watch-setup -- watch-local onboarding'
Write-Output ''
Write-Output 'This walks you through first-time setup of watch-local. Everything is'
Write-Output 'downloaded into the watch-local state folder -- no Docker, no admin'
Write-Output 'rights, nothing on system PATH. Delete that one folder to remove it all.'
Write-Output ''

#region Step1_Runtime
Write-Output '## Step 1: Portable runtime + GPU detection'
Write-Output 'Downloading pinned portable tools (~190 MB: yt-dlp, ffmpeg, deno, uv)'
Write-Output 'and probing for an NVIDIA GPU...'
$code = _RunChild $setupScript @('-DetectGpu')
if ($code -ne 0) {
    Write-Err "runtime provisioning / GPU detection failed (exit $code) -- check the output above and re-run /watch-setup."
    exit $code
}
$cfg = Get-WLConfig
$gpu = Get-WLObjectProp $cfg 'gpu'
$gpuPresent = [bool](Get-WLObjectProp $gpu 'present')
if ($gpuPresent) {
    $nvdecTxt = if (Get-WLObjectProp $gpu 'nvdec') { 'NVDEC video decode available' } else { 'no NVDEC (CPU decode)' }
    Write-Output ("GPU mode: {0} ({1} MB VRAM, {2})" -f (Get-WLObjectProp $gpu 'name'), (Get-WLObjectProp $gpu 'vram_mb'), $nvdecTxt)
    Write-Output 'Note: GPU whisper adds a one-time ~1.3 GB CUDA library download in step 4.'
} else {
    Write-Output 'CPU-only mode: no NVIDIA GPU detected on this machine.'
    Write-Output 'Everything still works -- transcription runs on CPU (int8), just slower.'
    Write-Output 'If this machine DOES have an NVIDIA GPU: install the latest NVIDIA driver,'
    Write-Output "then re-run /watch-setup (or: setup.ps1 -DetectGpu)."
}
Write-Output ''
#endregion

#region Step2_Config
Write-Output '## Step 2: Storage locations'
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
if ($gpuPresent) {
    Write-Output '  large-v3  ~3.0 GB     best quality (recommended on GPU)'
    Write-Output '  medium    ~1.5 GB     good quality, faster'
    Write-Output '  small     ~500 MB     decent for English-heavy content'
} else {
    Write-Output '  large-v3  ~3.0 GB     best quality -- SLOW on CPU (can approach real-time)'
    Write-Output '  medium    ~1.5 GB     good quality, still heavy on CPU'
    Write-Output '  small     ~500 MB     recommended on CPU -- good speed/quality balance'
}
Write-Output '  base      ~150 MB     fast smoke testing'
Write-Output '  tiny      ~75 MB      smoke testing only'
$recommended = if ($gpuPresent) { 'large-v3' } else { 'small' }
$pickedModel = if ($Model) { $Model } else { _Prompt 'Which model?' $recommended }
$cfg.default_model = $pickedModel
Save-WLConfig $cfg
Write-Output "default_model = $pickedModel"
Write-Output ''
#endregion

#region Step4_Install
Write-Output '## Step 4: Install whisper runtime + warm model cache'
$buildNote = if ($gpuPresent) { 'Python + whisper CUDA stack ~1.5 GB' } else { 'Python + whisper CPU stack ~100 MB' }
Write-Output "Downloads on this step: $buildNote, then the model pull."
$go = _PromptYN 'Proceed?' $true
if (-not $go) {
    Write-Err 'cancelled.'
    exit 0
}
$setupCode = _RunChild $setupScript @('-Model', $pickedModel)
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
        $smokeCode = _RunChild $watchScript @('-Source', $smokeUrl, '-MaxFrames', '4', '-NoCompare')
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
$psEngine = Get-WLPSEngine
Write-Output 'Inspect or change settings:'
Write-Output "  $psEngine -File `"$setupScript`" -ShowConfig"
Write-Output "  $psEngine -File `"$setupScript`" -SetDefaultModel medium"
Write-Output "  $psEngine -File `"$setupScript`" -ListJobs"
Write-Output "  $psEngine -File `"$setupScript`" -DetectGpu        # re-probe after driver/hardware changes"
Write-Output ''
Write-Output 'Disk-space pre-flight runs on every /watch call. Cleanup is opt-in:'
Write-Output "  /watch ... -Cleanup                              # delete this job's dir when done"
Write-Output "  $psEngine -File `"$setupScript`" -PurgeJobs -OlderThanDays 30"
Write-Output ''
#endregion
exit 0
