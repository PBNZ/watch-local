# _lib.ps1 -- shared helpers for watch-local PowerShell scripts.
#
# Dot-source from every other script:
#   . "$PSScriptRoot\_lib.ps1"
#
# Contents (region jump list -- keep labels short for VS Code minimap):
#   #region Globals      module-wide constants, exit codes, ASCII tokens
#   #region Logging      Write-Stage / Write-Detail / Write-Warn / Write-Err
#   #region Paths        slugs, slash-path display form, AssertInsideRoot
#   #region Config       load/save config.json with path validation
#   #region Disk         drive free-space helpers
#   #region Gpu          gpu-block parsing + per-run resolution
#   #region Time         Format-Time / Parse-Time mirror frames.py
#   #region Confirm      preview + token confirmation for destructive ops
#   #region Misc         file hashing, random tokens, encoding-safe Read
#
# _runtime.ps1 (dot-sourced at the end) adds runtime provisioning, native
# worker invocation, and the native GPU probes.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# PS 7.4+ default for $PSNativeCommandUseErrorActionPreference is $true,
# which turns native command stderr (e.g. ffmpeg banners, yt-dlp progress)
# into a terminating RemoteException under $ErrorActionPreference = 'Stop'.
# Every native call in these scripts is guarded by an explicit
# $LASTEXITCODE check, so we want the pre-PS7.4 behaviour where stderr is
# informational and the exit code is the truth. No-op on PS < 7.4.
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
    RUNTIME_MISSING    = 10   # runtime not provisioned (was DOCKER_MISSING)
    RUNTIME_BROKEN     = 11   # runtime provisioned but incomplete (was DOCKER_DOWN)
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
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    return -join ($hash | Select-Object -First 8 | ForEach-Object { $_.ToString('x2') })
}

# Normalize a Windows path to forward slashes -- used for display in
# reports (stable, copy-pasteable form on every host OS).
function ConvertTo-WLSlashPath([string]$winPath) {
    return ($winPath -replace '\\', '/')
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
    # Resolve the leaf through a symlink/junction so a link inside the root
    # pointing outside is judged by its real location. Only true links are
    # resolved: other reparse tags (OneDrive / cloud placeholders) have no
    # target and must pass through as ordinary directories. A link whose
    # target cannot be determined is refused outright (fail closed) -- the
    # guard must prove containment, and an unresolvable link proves nothing.
    # Intermediate-component links are not resolved; destructive callers
    # pass the directory to delete as the leaf.
    $item = $null
    try {
        $item = Get-Item -LiteralPath $tRes -Force -ErrorAction Stop
    } catch {
        # Path doesn't exist yet -- that's fine for create-time checks.
    }
    if ($null -ne $item -and
        $item.PSObject.Properties.Match('LinkType').Count -gt 0 -and
        $item.LinkType -in @('SymbolicLink', 'Junction')) {
        $linkTarget = $null
        try {
            # .Target is a string on PS 7 but a string collection on 5.1.
            $rawTarget = [string](@($item.Target) | Select-Object -First 1)
            if (-not [string]::IsNullOrWhiteSpace($rawTarget)) {
                if ([System.IO.Path]::IsPathRooted($rawTarget)) {
                    $linkTarget = [System.IO.Path]::GetFullPath($rawTarget)
                } else {
                    $parent = [System.IO.Path]::GetDirectoryName($tRes)
                    $linkTarget = [System.IO.Path]::GetFullPath((Join-Path $parent $rawTarget))
                }
            }
        } catch {
            $linkTarget = $null
        }
        if (-not $linkTarget) {
            Write-Err "refused: $Target is a link whose target cannot be resolved"
            exit $script:WL_EXIT.PURGE_REFUSED
        }
        $tRes = $linkTarget
    }
    $tRes = $tRes.TrimEnd([char]'\', [char]'/')
    $rRes = $rRes.TrimEnd([char]'\', [char]'/')
    # Windows filesystems are case-insensitive; default Linux (and
    # case-sensitive APFS) are not -- a case-folding compare there would
    # map a distinct sibling like .../JOBS into the root subtree.
    $cmp = if ($script:WL_IS_WINDOWS) { [System.StringComparison]::OrdinalIgnoreCase }
           else { [System.StringComparison]::Ordinal }
    if ([string]::Equals($tRes, $rRes, $cmp)) {
        Write-Err "refused: target is the root itself, not a child: $Target"
        exit $script:WL_EXIT.PURGE_REFUSED
    }
    if (-not $tRes.StartsWith(($rRes + [System.IO.Path]::DirectorySeparatorChar), $cmp)) {
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

# Free space in GB on the volume containing $path. Works with UNC by
# resolving to the host drive. Returns $null when it cannot tell (callers
# treat that as "skip the check", never as 0).
function Get-DriveFreeGB([string]$path) {
    try {
        $resolved = [System.IO.Path]::GetFullPath($path)
        if ($script:WL_IS_WINDOWS) {
            $root = [System.IO.Path]::GetPathRoot($resolved)
            if (-not $root) { return $null }
            $drive = Get-PSDrive -PSProvider FileSystem | Where-Object {
                $_.Root.TrimEnd('\').ToLower() -eq $root.TrimEnd('\').ToLower()
            } | Select-Object -First 1
            if (-not $drive) { return $null }
            return [math]::Round($drive.Free / 1GB, 2)
        }
        # Unix: GetPathRoot is always '/' and PowerShell exposes a single
        # '/' FileSystem PSDrive, so the Windows logic would report the
        # root filesystem for every path (wrong whenever /home, /tmp, or
        # an external volume is a separate mount). Stat the actual path --
        # or its deepest existing ancestor, so pre-creation checks work --
        # with POSIX df.
        $probe = $resolved
        while ($probe -and -not (Test-Path -LiteralPath $probe)) {
            $probe = [System.IO.Path]::GetDirectoryName($probe)
        }
        if (-not $probe) { return $null }
        $lines = @(& df -Pk -- $probe 2>$null)
        if ($LASTEXITCODE -ne 0 -or $lines.Count -lt 2) { return $null }
        # Portable (-P) format, one line per filesystem:
        # Filesystem 1024-blocks Used Available Capacity Mounted-on
        $fields = -split [string]$lines[-1]
        if ($fields.Count -lt 4) { return $null }
        $availKb = [long]0
        if (-not [long]::TryParse($fields[3], [ref]$availKb)) { return $null }
        return [math]::Round(($availKb * 1KB) / 1GB, 2)
    } catch {
        Write-Detail "Get-DriveFreeGB failed for ${path}: $($_.Exception.Message)"
        return $null
    }
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

# Attach the cuda_whisper field (venv-level CUDA availability) to a gpu
# object regardless of hashtable/PSCustomObject shape.
function Set-WLGpuCudaWhisper {
    param([Parameter(Mandatory)]$Gpu, [Parameter(Mandatory)][bool]$Value)
    if ($Gpu -is [System.Collections.IDictionary]) { $Gpu['cuda_whisper'] = $Value }
    else { $Gpu | Add-Member -NotePropertyName 'cuda_whisper' -NotePropertyValue $Value -Force }
    return $Gpu
}

# Resolve the effective gpu object for a run: use the config block when
# detection has already run; otherwise probe once and persist, so older
# installs migrate on their first /watch. Docker-era blocks lack
# cuda_whisper -- probe it once too, or a GPU box would silently run
# whisper on CPU after upgrading.
function Get-WLGpuInfo {
    param([Parameter(Mandatory)][hashtable]$Config)
    $gpu = Get-WLObjectProp $Config 'gpu'
    if ($null -ne $gpu -and $null -ne (Get-WLObjectProp $gpu 'present')) {
        if ($null -eq (Get-WLObjectProp $gpu 'cuda_whisper')) {
            $cw = if ([bool](Get-WLObjectProp $gpu 'present')) { Test-WLCudaWhisper } else { $false }
            $gpu = Set-WLGpuCudaWhisper -Gpu $gpu -Value $cw
            $Config.gpu = $gpu
            try { Save-WLConfig $Config } catch {
                Write-Detail "could not persist gpu migration: $($_.Exception.Message)"
            }
        }
        return $gpu
    }
    Write-Stage 'no GPU detection on record -- probing once...'
    $gpu = Test-WLGpuNative
    $cw = if ([bool](Get-WLObjectProp $gpu 'present')) { Test-WLCudaWhisper } else { $false }
    $gpu = Set-WLGpuCudaWhisper -Gpu $gpu -Value $cw
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

# Full-file SHA256 as lowercase hex via .NET -- deliberately NOT the
# Get-FileHash cmdlet, which a polluted PSModulePath (PS7 module dirs
# shadowing the 5.1 Utility module) can make unresolvable under Windows
# PowerShell 5.1. The .NET path needs no module. Throws on a missing /
# unreadable file: callers verify downloads and must not get $null back.
function Get-WLFileSHA256([string]$path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($path)
        try { $bytes = $sha.ComputeHash($stream) } finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

# Read a UTF-8 file regardless of BOM.
function Read-UTF8 ([string]$path) {
    return [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false, $false))
}

# Engine to spawn child PowerShell scripts with: the one running us.
# Windows PowerShell 5.1 -> powershell.exe; PowerShell 7+ (any OS) -> pwsh.
# Broken-engine escape hatch: PS7 module dirs on the 5.1 PSModulePath can
# shadow Microsoft.PowerShell.Utility/Archive with the (incompatible)
# PS7 copies, leaving cmdlets like Get-FileHash / Expand-Archive
# unresolvable under 5.1. When this process can't see them but pwsh is
# installed, spawn children with pwsh instead.
function Get-WLPSEngine {
    if ($PSVersionTable.PSEdition -eq 'Core') { return 'pwsh' }
    if (-not ((Get-Command Get-FileHash -ErrorAction SilentlyContinue) -and
              (Get-Command Expand-Archive -ErrorAction SilentlyContinue))) {
        if (Get-Command pwsh -ErrorAction SilentlyContinue) { return 'pwsh' }
    }
    return 'powershell.exe'
}

# Spawn a child PowerShell script with the engine above and return ONLY
# its exit code. The child's stdout must go to the host, NOT the caller's
# pipeline: `& $engine ...` emits every stdout line as pipeline output,
# and a bare `return $LASTEXITCODE` after it would hand callers an array
# (stdout lines + code), turning `$code -ne 0` into an element-wise
# filter. EAP is lowered so native stderr can't terminate the caller.
function Invoke-WLChild {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$ChildArgs = @()
    )
    $engine = Get-WLPSEngine
    $flags = @('-NoProfile')
    if ($script:WL_IS_WINDOWS) { $flags += @('-ExecutionPolicy', 'Bypass') }
    $orig = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        & $engine @flags -File $ScriptPath @ChildArgs | Out-Host
        return [int]$LASTEXITCODE
    } finally {
        $ErrorActionPreference = $orig
    }
}

#endregion

# Portable native runtime (provisioning, worker invocation, GPU probes).
. "$PSScriptRoot\_runtime.ps1"
