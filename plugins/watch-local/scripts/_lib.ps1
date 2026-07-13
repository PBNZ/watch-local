# _lib.ps1 -- shared helpers for watch-local PowerShell scripts.
#
# Dot-source from every other script:
#   . "$PSScriptRoot\_lib.ps1"
#
# Contents (region jump list -- keep labels short for VS Code minimap):
#   #region Globals      module-wide constants, exit codes, ASCII tokens
#   #region Logging      Write-Stage / Write-Detail / Write-Warn / Write-Err
#   #region Paths        slugs, ToDockerPath, ContainerToHost, AssertInsideRoot
#   #region Config       load/save config.json with path validation
#   #region Disk         drive free-space helpers
#   #region Docker       wrappers around docker / docker compose with try/catch
#   #region Time         Format-Time / Parse-Time mirror frames.py
#   #region Confirm      preview + token confirmation for destructive ops
#   #region Misc         file hashing, random tokens, encoding-safe Read

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# PS 7.4+ default for $PSNativeCommandUseErrorActionPreference is $true,
# which turns native command stderr (e.g. `docker compose run` progress
# lines like "Container ... Creating") into a terminating RemoteException
# under $ErrorActionPreference = 'Stop'. Every native call in these
# scripts is guarded by an explicit $LASTEXITCODE check, so we want the
# pre-PS7.4 behaviour where stderr is informational and the exit code is
# the truth. Toggle is a no-op on PS < 7.4.
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $false
}

# Must be initialized BEFORE Write-Detail uses it (StrictMode otherwise
# throws on first call).
if (-not (Get-Variable -Name WL_VERBOSE -Scope Script -ErrorAction SilentlyContinue)) {
    $script:WL_VERBOSE = $false
}

#region Globals

# Exit codes -- see PLAN-v2 section B6.
$script:WL_EXIT = [ordered]@{
    OK                 = 0
    DOCKER_MISSING     = 10
    DOCKER_DOWN        = 11
    GPU_MISSING        = 12
    SOURCE_BAD         = 20
    UNC_COPY_FAILED    = 21
    FLAG_CONFLICT      = 22
    TOOLS_FAILED       = 30
    WHISPER_FAILED     = 31
    # 32 (compare failed) retired: the compare stage is non-fatal by design
    # (warn + report continues), so no process can ever exit 32.
    REPORT_FAILED      = 40
    NO_DISK            = 50
    PURGE_REFUSED      = 60
}

# Image tags. The whisper image has a CUDA and a CPU variant; which one a
# machine builds/runs is decided by GPU detection (config.json `gpu` block).
$script:WL_IMG_TOOLS       = 'watch-local/tools:1'
$script:WL_IMG_WHISPER     = 'watch-local/whisper:cu128'
$script:WL_IMG_WHISPER_CPU = 'watch-local/whisper:cpu'

# NVIDIA container runtime capability set for the tools container. `video`
# is what injects libnvcuvid (NVDEC) -- the default 'compute,utility' set
# does NOT include it, so ffmpeg's cuvid decoders would fail to load.
$script:WL_GPU_CAPS_ENV = 'NVIDIA_DRIVER_CAPABILITIES=compute,video,utility'

# Hard ceilings -- mirror worker/frames.py.
$script:WL_MAX_FPS     = 2.0
$script:WL_MAX_FRAMES_HARD = 100

# True on Windows PowerShell 5.1 (Windows-only host) and on pwsh when
# $IsWindows says so. The -lt 6 check must come first: PS 5.1 has no
# $IsWindows automatic variable and StrictMode would flag it, but -or
# short-circuits before the reference is evaluated.
$script:WL_IS_WINDOWS = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows

# Platform-appropriate default locations. Windows: LOCALAPPDATA + TEMP.
# Elsewhere: XDG data home (fallback ~/.local/share) + the system temp dir.
function Get-WLPlatformDirs {
    param([bool]$IsWindowsPlatform = $script:WL_IS_WINDOWS)
    if ($IsWindowsPlatform) {
        return @{
            Base    = (Join-Path $env:LOCALAPPDATA 'watch-local')
            Staging = (Join-Path $env:TEMP 'watch-local-stage')
        }
    }
    $dataHome = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path (Join-Path $HOME '.local') 'share' }
    return @{
        Base    = (Join-Path $dataHome 'watch-local')
        Staging = (Join-Path ([System.IO.Path]::GetTempPath()) 'watch-local-stage')
    }
}

$script:WL_PLATFORM = Get-WLPlatformDirs

# Default config values. `gpu` is $null until detection has run (setup, or
# watch.ps1's one-time auto-migrate probe).
$script:WL_DEFAULT_CONFIG = [ordered]@{
    jobs_root              = (Join-Path $script:WL_PLATFORM.Base 'jobs')
    models_root            = (Join-Path $script:WL_PLATFORM.Base 'models')
    staging_root           = $script:WL_PLATFORM.Staging
    default_model          = 'large-v3'
    default_language       = $null
    auto_cleanup_days      = $null
    min_free_gb_jobs       = 2
    min_free_gb_staging    = 1
    min_free_gb_models     = 4
    gpu                    = $null
}

# Base dir for config + setup marker.
$script:WL_BASE_DIR     = $script:WL_PLATFORM.Base
$script:WL_CONFIG_FILE  = Join-Path $script:WL_BASE_DIR 'config.json'
$script:WL_SETUP_MARKER = Join-Path $script:WL_BASE_DIR '.setup-complete'
$script:WL_LAST_JOB     = Join-Path $script:WL_BASE_DIR 'last-job.json'

#endregion

#region Logging

# All log output goes to stderr (Write-Host with -ForegroundColor or
# explicit stream). stdout reserved for the final report so callers can
# pipe / capture cleanly.
function Write-Stage([string]$msg) {
    [Console]::Error.WriteLine("[watch] $msg")
}
function Write-Detail([string]$msg) {
    if ($script:WL_VERBOSE) {
        [Console]::Error.WriteLine("[watch] $msg")
    }
}
function Write-Warn([string]$msg) {
    [Console]::Error.WriteLine("[watch] WARNING: $msg")
}
function Write-Err([string]$msg) {
    [Console]::Error.WriteLine("[watch] ERROR: $msg")
}

# Call once near script top to enable verbose logging for this process.
function Enable-VerboseLog { $script:WL_VERBOSE = $true }

#endregion

#region Paths

# Slugify a source string into a 16-char hex string. Stable per call but
# different across calls (includes ticks) so reruns get fresh dirs.
function New-JobSlug([string]$source) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes("$source|$([DateTime]::UtcNow.Ticks)")
    $hash  = [System.Security.Cryptography.SHA1]::Create().ComputeHash($bytes)
    return -join ($hash | Select-Object -First 8 | ForEach-Object { $_.ToString('x2') })
}

# Convert a Windows path to the forward-slash form Docker Desktop accepts.
function ConvertTo-DockerPath([string]$winPath) {
    return ($winPath -replace '\\', '/')
}

# Translate a container path (e.g. /work/frames/foo.jpg) back to a host
# path. Caller provides the host base for /work and (optionally) /input.
function ConvertTo-HostPath {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$ContainerPath,
        [Parameter(Mandatory)][string]$WorkHost,
        [string]$InputHost = $null
    )
    if ([string]::IsNullOrEmpty($ContainerPath)) { return $null }
    if ($ContainerPath.StartsWith('/work/')) {
        return ConvertTo-DockerPath (Join-Path $WorkHost ($ContainerPath.Substring(6)))
    }
    if ($ContainerPath.StartsWith('/input/') -and $InputHost) {
        return ConvertTo-DockerPath (Join-Path $InputHost ($ContainerPath.Substring(7)))
    }
    return ConvertTo-DockerPath $ContainerPath
}

# Scope invariant. Resolve $Target and confirm it is a strict descendant
# of $Root. Throws with exit code 60 on violation. NEVER use on a
# user-supplied path without first calling this.
function Assert-InsideRoot {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Root
    )
    try {
        $tRes = [System.IO.Path]::GetFullPath($Target)
        $rRes = [System.IO.Path]::GetFullPath($Root)
    } catch {
        Write-Err "cannot resolve path: $Target"
        exit $script:WL_EXIT.PURGE_REFUSED
    }
    # Resolve real-path through any reparse points.
    try {
        $item = Get-Item -LiteralPath $tRes -Force -ErrorAction Stop
        if ($item.PSObject.Properties.Match('Target').Count -gt 0 -and $item.Target) {
            $tRes = [System.IO.Path]::GetFullPath((Join-Path $tRes '..' $item.Target))
        }
    } catch {
        # Path doesn't exist yet -- that's fine for create-time checks.
    }
    $tRes = $tRes.TrimEnd([char]'\', [char]'/')
    $rRes = $rRes.TrimEnd([char]'\', [char]'/')
    if ($tRes -ieq $rRes) {
        Write-Err "refused: target is the root itself, not a child: $Target"
        exit $script:WL_EXIT.PURGE_REFUSED
    }
    if (-not $tRes.ToLower().StartsWith(($rRes + [System.IO.Path]::DirectorySeparatorChar).ToLower())) {
        Write-Err "refused: $Target is outside safe root $Root"
        exit $script:WL_EXIT.PURGE_REFUSED
    }
}

#endregion

#region Config

# Read config.json or return defaults. Always returns a hashtable with
# all keys populated (defaults fill missing entries).
function Get-WLConfig {
    $cfg = [ordered]@{}
    foreach ($k in $script:WL_DEFAULT_CONFIG.Keys) {
        $cfg[$k] = $script:WL_DEFAULT_CONFIG[$k]
    }
    if (Test-Path -LiteralPath $script:WL_CONFIG_FILE) {
        try {
            $raw = [System.IO.File]::ReadAllText($script:WL_CONFIG_FILE, [System.Text.Encoding]::UTF8)
            $obj = $raw | ConvertFrom-Json -ErrorAction Stop
            foreach ($prop in $obj.PSObject.Properties) {
                if ($cfg.Contains($prop.Name)) {
                    $cfg[$prop.Name] = $prop.Value
                }
            }
        } catch {
            Write-Warn "config.json unreadable or malformed -- using defaults. ($($_.Exception.Message))"
        }
    }
    return $cfg
}

# Persist config with pretty-printed JSON.
function Save-WLConfig([hashtable]$cfg) {
    if (-not (Test-Path -LiteralPath $script:WL_BASE_DIR)) {
        New-Item -ItemType Directory -Force -Path $script:WL_BASE_DIR | Out-Null
    }
    $json = $cfg | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($script:WL_CONFIG_FILE, $json, [System.Text.Encoding]::UTF8)
}

# Validate a path passed to a config setter. Must exist OR be creatable
# (i.e., parent dir exists / can be created). Returns absolute path.
function Resolve-ConfigPath([string]$path) {
    try {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Force -Path $path -ErrorAction Stop | Out-Null
        }
        return (Resolve-Path -LiteralPath $path).ProviderPath
    } catch {
        throw "cannot create or access path: $path -- $($_.Exception.Message)"
    }
}

#endregion

#region Disk

# Free space in GB on the drive containing $path. Works with UNC by
# resolving to the host drive.
function Get-DriveFreeGB([string]$path) {
    try {
        $resolved = [System.IO.Path]::GetFullPath($path)
        $root = [System.IO.Path]::GetPathRoot($resolved)
        if (-not $root) { return $null }
        $drive = Get-PSDrive -PSProvider FileSystem | Where-Object {
            $_.Root.TrimEnd('\').ToLower() -eq $root.TrimEnd('\').ToLower()
        } | Select-Object -First 1
        if (-not $drive) { return $null }
        return [math]::Round($drive.Free / 1GB, 2)
    } catch {
        Write-Detail "Get-DriveFreeGB failed for ${path}: $($_.Exception.Message)"
        return $null
    }
}

#endregion

#region Docker

# Confirm docker CLI present + daemon responsive. Returns nothing on
# success; calls exit with WL_EXIT.DOCKER_* on failure.
function Assert-DockerReady {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Err 'docker CLI not on PATH. Install Docker Desktop from https://www.docker.com/products/docker-desktop/'
        exit $script:WL_EXIT.DOCKER_MISSING
    }
    try {
        & docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
    } catch {
        Write-Err "docker command failed: $($_.Exception.Message)"
        exit $script:WL_EXIT.DOCKER_DOWN
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Err 'Docker Desktop daemon not responding. Start Docker Desktop and re-run.'
        exit $script:WL_EXIT.DOCKER_DOWN
    }
}

# Run docker with the given flat string-array arg list. Lowers
# $ErrorActionPreference to Continue for the duration of the call so
# native stderr (docker compose progress lines, ffmpeg banner) doesn't
# terminate the caller under PS 7's StrictMode+Stop combo. Pipes output
# through Out-Host so the function's pipeline carries ONLY the exit code
# -- a bare `return $LASTEXITCODE` would otherwise interleave docker
# stdout in the caller's `$code`.
#
# Native stderr lines arrive on the merged pipeline as ErrorRecords, which
# PS 5.1 renders as red "RemoteException" blocks (pure noise for worker
# progress lines). Unwrap them to plain text on the real stderr stream --
# progress stays live, nothing is swallowed, and the exit code stays the
# single source of truth for failure.
#
# NOTE: ArgList is a plain [string[]] (NOT ValueFromRemainingArguments).
# Callers MUST pass a flat array, e.g. `-ArgList @('compose','-f',$f,'build','tools')`.
function Invoke-WLDocker {
    param([Parameter(Mandatory, Position=0)][string[]]$ArgList)
    $orig = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Write-Detail "docker $($ArgList -join ' ')"
    try {
        & docker @ArgList 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                [Console]::Error.WriteLine($_.Exception.Message)
            } else {
                $_ | Out-Host
            }
        }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $orig
    }
}

# Convenience: docker compose -f <file> <rest...>
# ComposeArgs uses ValueFromRemainingArguments so callers can pass
# positional args (or splat with @VarName) without wrapping in @( ).
# NOTE: use this ONLY for `docker compose build`. Per-call worker
# invocations must use Invoke-WLRun (plain `docker run`) -- see below.
function Invoke-WLCompose {
    param(
        [Parameter(Mandatory, Position=0)][string]$ComposeFile,
        [Parameter(ValueFromRemainingArguments=$true)][string[]]$ComposeArgs
    )
    $flat = @('compose', '-f', $ComposeFile) + $ComposeArgs
    Invoke-WLDocker -ArgList $flat
}

# Run a one-off worker container with `docker run --rm`.
#
# WHY NOT `docker compose run`: on the Docker Desktop WSL2 backend,
# `docker compose run` intermittently DEADLOCKS at container-start -- the
# container is created but never transitions to Running, wedged in
# `Created` state, and even `docker rm -f` cannot clear it without a
# Docker Desktop restart. This is the documented v0.2.0 blocker; it
# reproduces on real workloads (download/whisper) even when a trivial
# `compose run echo hi` succeeds. Plain `docker run` does not create a
# per-project compose network and does not exhibit the hang. (The GPU
# preflight has always used `docker run --gpus all` and never hung --
# corroborating evidence.) `docker compose build` is a separate code
# path and is unaffected, so image builds still go through Invoke-WLCompose.
#
# $RunArgs is the full arg list AFTER `run --rm`: env (-e ...), mounts
# (-v ...), GPU flags, the IMAGE TAG (not a compose service name), and the
# command. Returns the exit code; stdout streams via Out-Host like
# Invoke-WLDocker.
function Invoke-WLRun {
    param(
        [Parameter(Mandatory, Position=0)][string[]]$RunArgs,
        [string]$Name = 'worker'
    )
    # Meaningful container names in Docker Desktop (instead of random ones);
    # random suffix so concurrent runs of the same stage never collide.
    $cname = 'watch-local-{0}-{1}' -f $Name, (Get-Random -Maximum 99999)
    Invoke-WLDocker -ArgList (@('run', '--rm', '--name', $cname) + $RunArgs)
}

#endregion

#region Gpu

# StrictMode-safe property access for hashtables AND deserialized JSON
# objects (config.gpu is an [ordered] hashtable pre-save but a
# PSCustomObject after a JSON round-trip).
function Get-WLObjectProp {
    param($Obj, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        return $null
    }
    if ($Obj.PSObject.Properties.Match($Name).Count -gt 0) { return $Obj.$Name }
    return $null
}

# Parse one `nvidia-smi --query-gpu=name,driver_version,memory.total,compute_cap
# --format=csv,noheader` line into the gpu object persisted in config.json.
# Empty / unparseable input yields present=false (the CPU-mode marker).
function ConvertFrom-WLGpuProbe {
    param(
        [AllowEmptyString()][AllowNull()][string]$CsvLine,
        [Parameter(Mandatory)][bool]$Nvdec
    )
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $absent = [pscustomobject]@{
        present = $false; name = $null; driver = $null; vram_mb = 0
        compute_cap = $null; nvdec = $false; checked_at = $stamp
    }
    if ([string]::IsNullOrWhiteSpace($CsvLine)) { return $absent }
    $parts = @($CsvLine -split ',' | ForEach-Object { $_.Trim() })
    if ($parts.Count -lt 4) { return $absent }
    # Last three fields are driver / memory / compute cap; anything before
    # them is the (possibly comma-containing) GPU name.
    $vram = 0
    [void][int]::TryParse(($parts[$parts.Count - 2] -replace '[^\d]', ''), [ref]$vram)
    return [pscustomobject]@{
        present     = $true
        name        = ($parts[0..($parts.Count - 4)] -join ', ')
        driver      = $parts[$parts.Count - 3]
        vram_mb     = $vram
        compute_cap = $parts[$parts.Count - 1]
        nvdec       = $Nvdec
        checked_at  = $stamp
    }
}

# Probe the GPU through docker -- the only visibility that matters, since
# all work runs in containers. Two container runs against the tools image
# (call only after it is built; a missing image reads as "no GPU"):
#   1. nvidia-smi (injected by the NVIDIA runtime) -> presence + identity.
#   2. generate a 1s h264 clip and decode it with the explicit cuvid
#      decoder -> NVDEC works end-to-end (hard-fails when it doesn't;
#      verified against libnvcuvid missing / GPU absent).
# Returns the gpu object; never throws.
function Test-WLGpu {
    param([string]$Image = $script:WL_IMG_TOOLS)
    $orig = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        # Capture ALL lines, then take the first. Piping a native command
        # into `Select-Object -First 1` stops the pipeline after one object,
        # which terminates docker mid-stream and leaves $LASTEXITCODE = -1 --
        # making a working GPU read as absent.
        $out = @(& docker run --rm --name "watch-local-gpuprobe-$(Get-Random -Maximum 99999)" `
            --gpus all -e $script:WL_GPU_CAPS_ENV $Image `
            nvidia-smi --query-gpu=name,driver_version,memory.total,compute_cap --format=csv,noheader 2>$null)
        if ($LASTEXITCODE -ne 0 -or $out.Count -eq 0) {
            return (ConvertFrom-WLGpuProbe -CsvLine '' -Nvdec $false)
        }
        $csv = [string]$out[0]
        & docker run --rm --name "watch-local-nvdecprobe-$(Get-Random -Maximum 99999)" `
            --gpus all -e $script:WL_GPU_CAPS_ENV $Image sh -c `
            'ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=320x240:rate=30 -t 1 -c:v libx264 -pix_fmt yuv420p /tmp/probe.mp4 && ffmpeg -hide_banner -loglevel error -y -c:v h264_cuvid -i /tmp/probe.mp4 -f null -' 2>$null | Out-Null
        $nvdec = ($LASTEXITCODE -eq 0)
        return (ConvertFrom-WLGpuProbe -CsvLine ([string]$csv) -Nvdec $nvdec)
    } catch {
        return (ConvertFrom-WLGpuProbe -CsvLine '' -Nvdec $false)
    } finally {
        $ErrorActionPreference = $orig
    }
}

# docker run flags for the tools/stills containers. Only when the detected
# GPU has working NVDEC: GPU access + video capability + the env that makes
# frames.py insert `-hwaccel cuda`. Otherwise empty (pure CPU decode).
function Get-WLToolsGpuFlags {
    param($Gpu)
    $present = Get-WLObjectProp $Gpu 'present'
    $nvdec   = Get-WLObjectProp $Gpu 'nvdec'
    if (-not $present -or -not $nvdec) { return @() }
    return @('--gpus', 'all', '-e', $script:WL_GPU_CAPS_ENV, '-e', 'W_HWACCEL=cuda')
}

# Whisper image + docker run flags per mode. CPU mode: no GPU request,
# ctranslate2 on cpu/int8 (the documented faster-whisper CPU config).
function Get-WLWhisperImage {
    param([Parameter(Mandatory)][bool]$GpuPresent)
    if ($GpuPresent) { return $script:WL_IMG_WHISPER }
    return $script:WL_IMG_WHISPER_CPU
}

function Get-WLWhisperRunFlags {
    param([Parameter(Mandatory)][bool]$GpuPresent)
    if ($GpuPresent) {
        return @(
            '--gpus', 'all',
            '-e', 'NVIDIA_VISIBLE_DEVICES=all',
            '-e', 'HF_HOME=/models/hf-cache'
        )
    }
    return @(
        '-e', 'HF_HOME=/models/hf-cache',
        '-e', 'W_DEVICE=cpu',
        '-e', 'W_COMPUTE=int8'
    )
}

# Resolve the effective gpu object for a run: use the config block when
# detection has already run; otherwise (pre-upgrade config) probe once and
# persist, so older installs migrate on their first /watch.
function Get-WLGpuInfo {
    param([Parameter(Mandatory)][hashtable]$Config)
    $gpu = Get-WLObjectProp $Config 'gpu'
    if ($null -ne $gpu -and $null -ne (Get-WLObjectProp $gpu 'present')) { return $gpu }
    Write-Stage 'no GPU detection on record -- probing once (10-30s)...'
    $gpu = Test-WLGpu
    $Config.gpu = $gpu
    try { Save-WLConfig $Config } catch {
        Write-Detail "could not persist gpu detection: $($_.Exception.Message)"
    }
    return $gpu
}

#endregion

#region Time

# Mirror frames.format_time -- "MM:SS" or "H:MM:SS".
function Format-WLTime([double]$seconds) {
    $total = [int][math]::Round($seconds)
    $h = [int][math]::Floor($total / 3600)
    $m = [int][math]::Floor(($total % 3600) / 60)
    $s = [int]($total % 60)
    if ($h -gt 0) { return ('{0}:{1:D2}:{2:D2}' -f $h, $m, $s) }
    return ('{0:D2}:{1:D2}' -f $m, $s)
}

# Mirror frames.parse_time -- accepts SS / MM:SS / HH:MM:SS. Returns
# $null for null/empty input.
function Convert-WLTime([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    $parts = $value.Trim() -split ':'
    try {
        switch ($parts.Count) {
            1 { return [double]$parts[0] }
            2 { return ([int]$parts[0] * 60) + [double]$parts[1] }
            3 { return ([int]$parts[0] * 3600) + ([int]$parts[1] * 60) + [double]$parts[2] }
            default { throw 'too many colons' }
        }
    } catch {
        throw "cannot parse time '$value': $($_.Exception.Message)"
    }
}

#endregion

#region Confirm

# Generate an uppercase token. Used to gate destructive purges.
# With -Seed (the exact purge target set), the token is deterministic: a
# non-interactive caller runs once to see the preview + token, then re-runs
# with -*ConfirmToken to proceed. If the target set changed between the two
# runs the token changes too, so the confirmation stays bound to exactly
# what was previewed. (A random token here made non-interactive
# confirmation impossible -- regenerated every invocation, so a token from
# the preview run could never match the confirm run.)
function New-ConfirmToken([string]$prefix = 'CONFIRM', [string]$Seed = '') {
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'  # no 0/O/1/I
    if ($Seed) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Seed))
        } finally { $sha.Dispose() }
        $rnd = -join (0..5 | ForEach-Object { $alphabet[[int]$bytes[$_] % $alphabet.Length] })
    } else {
        $rnd = -join (1..6 | ForEach-Object { $alphabet[(Get-Random -Maximum $alphabet.Length)] })
    }
    return "$prefix-$rnd"
}

# Print preview + read confirmation token interactively. Caller passes
# the expected token. Returns $true on match, $false on cancel / mismatch.
function Request-Confirm {
    param(
        [Parameter(Mandatory)][string]$ExpectedToken,
        [string]$NonInteractiveToken = $null
    )
    if ($NonInteractiveToken) {
        if ($NonInteractiveToken -ceq $ExpectedToken) { return $true }
        Write-Err "confirmation token mismatch (got '$NonInteractiveToken', expected '$ExpectedToken')"
        return $false
    }
    if ([Console]::IsInputRedirected) {
        # Non-interactive host: ReadLine would block forever on
        # redirected-but-open stdin. Cancel cleanly -- the preview above
        # already printed the token; re-run with the token parameter.
        Write-Err 'non-interactive session: re-run with the confirmation token parameter shown in the preview above.'
        return $false
    }
    [Console]::Error.WriteLine('')
    [Console]::Error.Write("Type the token to proceed, or any other input to cancel: ")
    $reply = [Console]::ReadLine()
    if ($null -eq $reply) { return $false }
    return ($reply.Trim() -ceq $ExpectedToken)
}

#endregion

#region Misc

# Hash first N bytes of a file. Used in source-link.txt to verify
# unchanged source without reading huge files end-to-end.
function Get-PartialSHA256([string]$path, [int]$bytes = 65536) {
    try {
        $stream = [System.IO.File]::OpenRead($path)
        try {
            $buffer = New-Object byte[] ([math]::Min($bytes, $stream.Length))
            [void]$stream.Read($buffer, 0, $buffer.Length)
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $hash = $sha.ComputeHash($buffer)
            return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
        } finally {
            $stream.Dispose()
        }
    } catch {
        Write-Detail "Get-PartialSHA256 failed: $($_.Exception.Message)"
        return $null
    }
}

# Read a UTF-8 file regardless of BOM.
function Read-UTF8 ([string]$path) {
    return [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false, $false))
}

# Engine to spawn child PowerShell scripts with: the one running us.
# Windows PowerShell 5.1 -> powershell.exe; PowerShell 7+ (any OS) -> pwsh.
function Get-WLPSEngine {
    if ($PSVersionTable.PSEdition -eq 'Core') { return 'pwsh' }
    return 'powershell.exe'
}

#endregion
