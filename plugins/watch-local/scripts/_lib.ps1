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
    COMPARE_FAILED     = 32
    REPORT_FAILED      = 40
    NO_DISK            = 50
    PURGE_REFUSED      = 60
}

# Image tags.
$script:WL_IMG_TOOLS   = 'watch-local/tools:1'
$script:WL_IMG_WHISPER = 'watch-local/whisper:cu128'

# Extra `docker run` flags the whisper container needs, replicating the
# `whisper` service block in docker-compose.yml (GPU access + model cache
# env). Tools container needs none of these.
$script:WL_WHISPER_RUN_FLAGS = @(
    '--gpus', 'all',
    '-e', 'NVIDIA_VISIBLE_DEVICES=all',
    '-e', 'HF_HOME=/models/hf-cache'
)

# Hard ceilings -- mirror worker/frames.py.
$script:WL_MAX_FPS     = 2.0
$script:WL_MAX_FRAMES_HARD = 100

# Default config values.
$script:WL_DEFAULT_CONFIG = [ordered]@{
    jobs_root              = (Join-Path $env:LOCALAPPDATA 'watch-local\jobs')
    models_root            = (Join-Path $env:LOCALAPPDATA 'watch-local\models')
    staging_root           = (Join-Path $env:TEMP        'watch-local-stage')
    default_model          = 'large-v3'
    default_language       = $null
    auto_cleanup_days      = $null
    min_free_gb_jobs       = 2
    min_free_gb_staging    = 1
    min_free_gb_models     = 4
}

# Base dir for config + setup marker.
$script:WL_BASE_DIR     = Join-Path $env:LOCALAPPDATA 'watch-local'
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
# NOTE: ArgList is a plain [string[]] (NOT ValueFromRemainingArguments).
# Callers MUST pass a flat array, e.g. `-ArgList @('compose','-f',$f,'build','tools')`.
function Invoke-WLDocker {
    param([Parameter(Mandatory, Position=0)][string[]]$ArgList)
    $orig = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Write-Detail "docker $($ArgList -join ' ')"
    try {
        & docker @ArgList 2>&1 | Out-Host
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
    param([Parameter(Mandatory, Position=0)][string[]]$RunArgs)
    Invoke-WLDocker -ArgList (@('run', '--rm') + $RunArgs)
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

# Generate a random uppercase token. Used to gate destructive purges.
function New-ConfirmToken([string]$prefix = 'CONFIRM') {
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'  # no 0/O/1/I
    $rnd = -join (1..6 | ForEach-Object { $alphabet[(Get-Random -Maximum $alphabet.Length)] })
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

#endregion
