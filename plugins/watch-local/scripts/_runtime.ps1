# _runtime.ps1 -- portable native runtime: provisioning + worker invocation.
#
# Replaces Docker containers with pinned portable binaries (yt-dlp, ffmpeg,
# deno, uv) plus a uv-managed CPython venv (faster-whisper), all under
# <state root>\runtime\. Nothing touches system PATH / registry / Program
# Files; deleting the state root removes every trace.
#
# Dot-sourced from _lib.ps1 -- may use _lib helpers (Write-*, WL_EXIT,
# Get-WLObjectProp, ConvertFrom-WLGpuProbe).
#
#   #region RuntimePaths   dirs, platform key, manifests
#   #region Provision      download/verify/extract + python/venv install
#   #region Status         Test-WLRuntime / Assert-WLRuntimeReady / update
#   #region Workers        Get-WLWorkerEnv / Invoke-WLWorker(+Capture)
#   #region GpuNative      host GPU probes + per-stage worker env

#region RuntimePaths

$script:WL_RUNTIME_DIR    = Join-Path $script:WL_BASE_DIR 'runtime'
$script:WL_RUNTIME_BIN    = Join-Path $script:WL_RUNTIME_DIR 'bin'
$script:WL_RUNTIME_PY     = Join-Path $script:WL_RUNTIME_DIR 'python'
$script:WL_RUNTIME_VENV   = Join-Path (Join-Path $script:WL_RUNTIME_DIR 'venvs') 'whisper'
$script:WL_RUNTIME_TMP    = Join-Path $script:WL_RUNTIME_DIR 'tmp'
$script:WL_RUNTIME_STATE  = Join-Path $script:WL_RUNTIME_DIR 'manifest.json'
$script:WL_RUNTIME_PINS   = Join-Path $PSScriptRoot 'runtime-manifest.json'
$script:WL_WORKER_DIR     = Join-Path $PSScriptRoot 'worker'

function Get-WLExeSuffix { if ($script:WL_IS_WINDOWS) { return '.exe' } return '' }

function Get-WLFfmpegBin {
    param([string]$Tool = 'ffmpeg')
    return (Join-Path (Join-Path (Join-Path $script:WL_RUNTIME_BIN 'ffmpeg') 'bin') "$Tool$(Get-WLExeSuffix)")
}

function Get-WLUv { return (Join-Path $script:WL_RUNTIME_BIN "uv$(Get-WLExeSuffix)") }

# The single Python used for ALL workers. Tools-side workers are
# stdlib-only, so the whisper venv serves both roles -- one interpreter,
# one venv, no duplication.
function Get-WLWorkerPython {
    if ($script:WL_IS_WINDOWS) { return (Join-Path $script:WL_RUNTIME_VENV 'Scripts\python.exe') }
    return (Join-Path $script:WL_RUNTIME_VENV 'bin/python')
}

# Manifest platform key. macOS x64 and other combinations have no pinned
# assets yet -- Install-WLRuntime raises a clear error naming the manifest.
function Get-WLRuntimePlatform {
    if ($script:WL_IS_WINDOWS) { return 'win_x64' }
    if ($IsLinux) { return 'linux_x64' }
    if ($IsMacOS) {
        $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
        if ("$arch" -eq 'Arm64') { return 'macos_arm64' }
        return 'macos_x64'
    }
    return 'unknown'
}

function Get-WLRuntimeManifest {
    return (Read-UTF8 $script:WL_RUNTIME_PINS | ConvertFrom-Json)
}

function Get-WLInstalledRuntime {
    if (-not (Test-Path -LiteralPath $script:WL_RUNTIME_STATE)) { return $null }
    try { return (Read-UTF8 $script:WL_RUNTIME_STATE | ConvertFrom-Json) } catch { return $null }
}

function Save-WLInstalledRuntime([hashtable]$state) {
    if (-not (Test-Path -LiteralPath $script:WL_RUNTIME_DIR)) {
        New-Item -ItemType Directory -Force -Path $script:WL_RUNTIME_DIR | Out-Null
    }
    [System.IO.File]::WriteAllText($script:WL_RUNTIME_STATE, ($state | ConvertTo-Json -Depth 6), [System.Text.Encoding]::UTF8)
}

function Get-WLRuntimeSizeGB {
    if (-not (Test-Path -LiteralPath $script:WL_RUNTIME_DIR)) { return 0 }
    try {
        $bytes = (Get-ChildItem $script:WL_RUNTIME_DIR -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum).Sum
        return [math]::Round($bytes / 1GB, 2)
    } catch { return $null }
}

#endregion

#region Provision

# Download a URL to a file with hash verification. PS 5.1 needs TLS 1.2
# forced and progress suppressed (progress rendering dominates wall time).
function Get-WLPinnedFile {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Dest,
        [Parameter(Mandatory)][string]$Sha256
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $origProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Write-Stage "downloading $([System.IO.Path]::GetFileName($Dest)) ..."
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
    } finally {
        $ProgressPreference = $origProgress
    }
    $actual = Get-WLFileSHA256 $Dest
    if ($actual -ne $Sha256.ToLower()) {
        Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
        throw "sha256 mismatch for $Url`n  expected $Sha256`n  actual   $actual"
    }
}

# Install one pinned binary: download, verify, extract (zip via
# Expand-Archive, tar.* via native tar -- bsdtar ships with Win10+), then
# locate the wanted executables anywhere in the extracted tree. Layout
# differences between archives (gyan vs BtbN vs evermeet) become
# irrelevant: we search by name and copy just those files.
function Install-WLBinary {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Spec,
        [Parameter(Mandatory)][string]$Platform
    )
    $plat = Get-WLObjectProp $Spec $Platform
    if ($null -eq $plat) {
        throw "no pinned $Name assets for platform '$Platform' -- add them to runtime-manifest.json"
    }
    $suffix = Get-WLExeSuffix
    $findNames = @(Get-WLObjectProp $Spec 'find')
    $subdir = Get-WLObjectProp $Spec 'subdir'
    $destDir = $script:WL_RUNTIME_BIN
    if ($subdir) {
        $destDir = Join-Path $script:WL_RUNTIME_BIN ($subdir -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    }
    foreach ($d in @($destDir, $script:WL_RUNTIME_TMP)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }

    $installed = @()
    foreach ($f in @(Get-WLObjectProp $plat 'files')) {
        $url = Get-WLObjectProp $f 'url'
        $rawName = Get-WLObjectProp $f 'raw_name'
        $dl = Join-Path $script:WL_RUNTIME_TMP ([System.IO.Path]::GetFileName(([uri]$url).AbsolutePath))
        Get-WLPinnedFile -Url $url -Dest $dl -Sha256 (Get-WLObjectProp $f 'sha256')

        if ($rawName) {
            $target = Join-Path $destDir $rawName
            Copy-Item -LiteralPath $dl -Destination $target -Force
            $installed += $target
        } else {
            $x = Join-Path $script:WL_RUNTIME_TMP "extract-$Name"
            if (Test-Path -LiteralPath $x) { Remove-Item -LiteralPath $x -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $x | Out-Null
            if ($dl -match '\.zip$') {
                Expand-Archive -LiteralPath $dl -DestinationPath $x -Force
            } else {
                & tar -xf $dl -C $x
                if ($LASTEXITCODE -ne 0) { throw "tar extraction failed for $dl (exit $LASTEXITCODE)" }
            }
            foreach ($bn in $findNames) {
                $exeName = "$bn$suffix"
                $hit = Get-ChildItem -LiteralPath $x -Recurse -File -Filter $exeName | Select-Object -First 1
                if ($null -eq $hit) { continue }  # multi-file platforms carry one tool per archive
                $target = Join-Path $destDir $exeName
                Copy-Item -LiteralPath $hit.FullName -Destination $target -Force
                $installed += $target
            }
            Remove-Item -LiteralPath $x -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $dl -Force -ErrorAction SilentlyContinue
    }

    # Every advertised tool must have landed across the platform's files.
    foreach ($bn in $findNames) {
        $expect = Join-Path $destDir "$bn$suffix"
        if (-not (Test-Path -LiteralPath $expect)) {
            throw "$Name install incomplete: $expect not found after extraction"
        }
        if (-not $script:WL_IS_WINDOWS) {
            & chmod +x $expect
        }
    }
    Write-Stage "$Name $(Get-WLObjectProp $Spec 'version') installed"
    return $installed
}

# Env for uv invocations: keep uv's python installs AND its download cache
# inside the runtime dir so nothing lands in the user profile.
function Invoke-WLUv {
    param([Parameter(Mandatory)][string[]]$ArgList)
    $savedPy = $env:UV_PYTHON_INSTALL_DIR
    $savedCache = $env:UV_CACHE_DIR
    $orig = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $env:UV_PYTHON_INSTALL_DIR = $script:WL_RUNTIME_PY
        $env:UV_CACHE_DIR = Join-Path $script:WL_RUNTIME_DIR 'uv-cache'
        Write-Detail "uv $($ArgList -join ' ')"
        & (Get-WLUv) @ArgList 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                [Console]::Error.WriteLine($_.Exception.Message)
            } else { $_ | Out-Host }
        }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $orig
        $env:UV_PYTHON_INSTALL_DIR = $savedPy
        $env:UV_CACHE_DIR = $savedCache
    }
}

# Stage 1: the four portable binaries. No GPU knowledge needed.
function Install-WLRuntimeBinaries {
    param([switch]$Force)
    $manifest = Get-WLRuntimeManifest
    $platform = Get-WLRuntimePlatform
    if ($platform -in @('unknown', 'macos_x64')) {
        throw "platform '$platform' has no pinned runtime assets (see runtime-manifest.json)"
    }
    $state = Get-WLInstalledRuntime
    foreach ($name in @('uv', 'ytdlp', 'deno', 'ffmpeg')) {
        $spec = Get-WLObjectProp $manifest.binaries $name
        $wanted = Get-WLObjectProp $spec 'version'
        $have = if ($state) { Get-WLObjectProp (Get-WLObjectProp $state 'binaries') $name } else { $null }
        $firstExe = Join-Path $script:WL_RUNTIME_BIN ("$(@(Get-WLObjectProp $spec 'find')[0])$(Get-WLExeSuffix)")
        if ($name -eq 'ffmpeg') { $firstExe = Get-WLFfmpegBin }
        if (-not $Force -and $have -eq $wanted -and (Test-Path -LiteralPath $firstExe)) {
            Write-Detail "$name $wanted already installed"
            continue
        }
        Install-WLBinary -Name $name -Spec $spec -Platform $platform | Out-Null
    }
}

# Stage 2: pinned CPython + the whisper venv. GPU wheels (~1.3 GB) only
# when the machine actually has a CUDA GPU.
function Install-WLRuntimePython {
    param([Parameter(Mandatory)][bool]$GpuPresent)
    $manifest = Get-WLRuntimeManifest
    $pyPin = [string]$manifest.python

    Write-Stage "installing CPython $pyPin (uv-managed, inside runtime dir)..."
    # --no-bin / --no-registry: no shims in ~/.local/bin, no Windows
    # registry entries -- the interpreter must leave zero trace outside
    # the runtime dir.
    if ((Invoke-WLUv @('python', 'install', $pyPin, '--no-bin', '--no-registry')) -ne 0) { throw 'uv python install failed' }
    if ((Invoke-WLUv @('venv', $script:WL_RUNTIME_VENV, '--python', $pyPin, '--clear')) -ne 0) { throw 'uv venv failed' }

    $pkgs = @($manifest.pip.common)
    if ($GpuPresent) { $pkgs += @($manifest.pip.gpu) }
    $mode = if ($GpuPresent) { 'GPU (CUDA wheels, ~1.3 GB)' } else { 'CPU' }
    Write-Stage "installing whisper stack [$mode]..."
    $pipArgs = @('pip', 'install', '--python', (Get-WLWorkerPython)) + $pkgs
    if ((Invoke-WLUv $pipArgs) -ne 0) { throw 'uv pip install failed' }
}

# Record what is actually installed (called after both stages succeed).
function Save-WLRuntimeState {
    param([Parameter(Mandatory)][bool]$GpuPresent)
    $manifest = Get-WLRuntimeManifest
    $ytdlpExe = Join-Path $script:WL_RUNTIME_BIN "yt-dlp$(Get-WLExeSuffix)"
    $ytdlpVer = ([string](& $ytdlpExe --version 2>$null)).Trim()
    $pyVer = ([string](& (Get-WLWorkerPython) --version 2>$null)).Trim() -replace '^Python\s+', ''
    $state = [ordered]@{
        schema       = 1
        platform     = Get-WLRuntimePlatform
        installed_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        gpu_deps     = $GpuPresent
        python       = $pyVer
        binaries     = [ordered]@{
            uv     = [string]$manifest.binaries.uv.version
            ytdlp  = if ($ytdlpVer) { $ytdlpVer } else { [string]$manifest.binaries.ytdlp.version }
            deno   = [string]$manifest.binaries.deno.version
            ffmpeg = [string]$manifest.binaries.ffmpeg.version
        }
    }
    Save-WLInstalledRuntime $state
    Remove-Item -LiteralPath $script:WL_RUNTIME_TMP -Recurse -Force -ErrorAction SilentlyContinue
    return $state
}

# Full provisioning. Returns the state object it persisted.
function Install-WLRuntime {
    param(
        [Parameter(Mandatory)][bool]$GpuPresent,
        [switch]$Force
    )
    Install-WLRuntimeBinaries -Force:$Force
    Install-WLRuntimePython -GpuPresent $GpuPresent
    return (Save-WLRuntimeState -GpuPresent $GpuPresent)
}

#endregion

#region Status

# Fast status object -- existence checks only (no process spawns unless
# -Deep, which also verifies the venv can import faster_whisper).
function Test-WLRuntime {
    param([switch]$Deep)
    $suffix = Get-WLExeSuffix
    $state = Get-WLInstalledRuntime
    $status = [ordered]@{
        provisioned = ($null -ne $state)
        ytdlp       = (Test-Path -LiteralPath (Join-Path $script:WL_RUNTIME_BIN "yt-dlp$suffix"))
        deno        = (Test-Path -LiteralPath (Join-Path $script:WL_RUNTIME_BIN "deno$suffix"))
        ffmpeg      = (Test-Path -LiteralPath (Get-WLFfmpegBin))
        ffprobe     = (Test-Path -LiteralPath (Get-WLFfmpegBin 'ffprobe'))
        uv          = (Test-Path -LiteralPath (Get-WLUv))
        python      = (Test-Path -LiteralPath (Get-WLWorkerPython))
        whisper_ok  = $null
        gpu_deps    = if ($state) { [bool](Get-WLObjectProp $state 'gpu_deps') } else { $false }
        versions    = if ($state) { Get-WLObjectProp $state 'binaries' } else { $null }
        size_gb     = Get-WLRuntimeSizeGB
    }
    $status.ok = $status.ytdlp -and $status.deno -and $status.ffmpeg -and $status.ffprobe -and $status.python -and $status.provisioned
    if ($Deep -and $status.python) {
        & (Get-WLWorkerPython) -c 'import faster_whisper' 2>$null | Out-Null
        $status.whisper_ok = ($LASTEXITCODE -eq 0)
        if (-not $status.whisper_ok) { $status.ok = $false }
    }
    return [pscustomobject]$status
}

# Gate every pipeline entry point. Exits RUNTIME_MISSING when nothing is
# provisioned, RUNTIME_BROKEN when a provisioned runtime lost pieces.
function Assert-WLRuntimeReady {
    $status = Test-WLRuntime
    if ($status.ok) { return }
    if (-not $status.provisioned) {
        Write-Err 'runtime not provisioned. Run /watch-setup (or: setup.ps1 -Install) first.'
        exit $script:WL_EXIT.RUNTIME_MISSING
    }
    $missing = @('ytdlp', 'deno', 'ffmpeg', 'ffprobe', 'python' | Where-Object { -not $status.$_ })
    Write-Err "runtime incomplete (missing: $($missing -join ', ')). Run setup.ps1 -UpdateRuntime to repair."
    exit $script:WL_EXIT.RUNTIME_BROKEN
}

# yt-dlp self-update (official binaries update in place). Keeps the
# installed manifest's recorded version honest.
function Update-WLYtDlp {
    $ytdlp = Join-Path $script:WL_RUNTIME_BIN "yt-dlp$(Get-WLExeSuffix)"
    if (-not (Test-Path -LiteralPath $ytdlp)) {
        Write-Err 'yt-dlp not installed -- run setup first.'
        return 1
    }
    $orig = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $ytdlp -U 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { [Console]::Error.WriteLine($_.Exception.Message) }
            else { $_ | Out-Host }
        }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $orig }
    if ($code -eq 0) {
        $ver = ([string](& $ytdlp --version 2>$null)).Trim()
        $state = Get-WLInstalledRuntime
        if ($state -and $ver) {
            $h = @{}
            foreach ($p in $state.PSObject.Properties) { $h[$p.Name] = $p.Value }
            $h.binaries.ytdlp = $ver
            Save-WLInstalledRuntime $h
            Write-Stage "yt-dlp now $ver"
        }
    }
    return $code
}

#endregion

#region Workers

# Per-worker process env: runtime bins prepended to PATH (workers find
# yt-dlp/ffmpeg/deno via shutil.which), UTF-8 + unbuffered python, deno's
# cache pinned inside the runtime dir (yt-dlp spawns deno for YouTube JS
# challenges; without DENO_DIR it would cache in the user profile).
function Get-WLWorkerEnv {
    param([hashtable]$Extra = @{})
    $sep = [System.IO.Path]::PathSeparator
    $ffmpegDir = Split-Path (Get-WLFfmpegBin) -Parent
    $vars = [ordered]@{
        PATH             = "$($script:WL_RUNTIME_BIN)$sep$ffmpegDir$sep$($env:PATH)"
        PYTHONUNBUFFERED = '1'
        PYTHONUTF8       = '1'
        DENO_DIR         = (Join-Path $script:WL_RUNTIME_DIR 'deno-cache')
    }
    foreach ($k in $Extra.Keys) { $vars[$k] = [string]$Extra[$k] }
    return $vars
}

# Run a worker script natively -- the replacement for Invoke-WLRun.
# Same output contract: stdout/stderr stream live (ErrorRecords unwrapped
# to plain stderr), pipeline carries ONLY the exit code.
function Invoke-WLWorker {
    param(
        [Parameter(Mandatory)][string]$Script,
        [hashtable]$EnvVars = @{},
        [string]$Name = 'worker'
    )
    $py = Get-WLWorkerPython
    $scriptPath = Join-Path $script:WL_WORKER_DIR $Script
    $vars = Get-WLWorkerEnv -Extra $EnvVars
    $saved = @{}
    foreach ($k in $vars.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, [string]$vars[$k])
    }
    $orig = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Write-Detail "worker ${Name}: python $Script"
    try {
        & $py $scriptPath 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                [Console]::Error.WriteLine($_.Exception.Message)
            } else { $_ | Out-Host }
        }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $orig
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}

# Variant that CAPTURES stdout (disk.py size probe, stills.py JSON) while
# stderr still streams to the console. Returns @{ Output; ExitCode }.
function Invoke-WLWorkerCapture {
    param(
        [Parameter(Mandatory)][string]$Script,
        [hashtable]$EnvVars = @{},
        [string]$Name = 'worker'
    )
    $py = Get-WLWorkerPython
    $scriptPath = Join-Path $script:WL_WORKER_DIR $Script
    $vars = Get-WLWorkerEnv -Extra $EnvVars
    $saved = @{}
    foreach ($k in $vars.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, [string]$vars[$k])
    }
    $orig = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $outLines = New-Object System.Collections.Generic.List[string]
    try {
        & $py $scriptPath 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                [Console]::Error.WriteLine($_.Exception.Message)
            } else { $outLines.Add([string]$_) }
        }
        return [pscustomobject]@{ Output = ($outLines -join "`n"); ExitCode = $LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $orig
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}

#endregion

#region GpuNative

# Locate nvidia-smi on the host. Ships with the NVIDIA driver: on PATH,
# or System32, or the legacy NVSMI dir; /usr/bin on Linux.
function Find-WLNvidiaSmi {
    $cmd = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = if ($script:WL_IS_WINDOWS) {
        @(
            (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'),
            (Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe')
        )
    } else {
        @('/usr/bin/nvidia-smi', '/usr/local/bin/nvidia-smi')
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

# Native GPU probe -- same contract as the retired docker Test-WLGpu:
#   1. host nvidia-smi CSV -> presence + identity (ConvertFrom-WLGpuProbe)
#   2. portable ffmpeg: encode 1s testsrc2 clip, decode with h264_cuvid
#      -> NVDEC verified end-to-end
# Returns the gpu object; never throws. Call after binaries are installed
# (the NVDEC leg needs the runtime ffmpeg; without it nvdec reads false).
function Test-WLGpuNative {
    $orig = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $smi = Find-WLNvidiaSmi
        if (-not $smi) { return (ConvertFrom-WLGpuProbe -CsvLine '' -Nvdec $false) }
        # Capture ALL lines, then take the first -- piping a native command
        # into Select-Object -First 1 corrupts $LASTEXITCODE (see docs).
        $out = @(& $smi --query-gpu=name,driver_version,memory.total,compute_cap --format=csv,noheader 2>$null)
        if ($LASTEXITCODE -ne 0 -or $out.Count -eq 0) {
            return (ConvertFrom-WLGpuProbe -CsvLine '' -Nvdec $false)
        }
        $csv = [string]$out[0]

        $nvdec = $false
        $ffmpeg = Get-WLFfmpegBin
        if (Test-Path -LiteralPath $ffmpeg) {
            if (-not (Test-Path -LiteralPath $script:WL_RUNTIME_TMP)) {
                New-Item -ItemType Directory -Force -Path $script:WL_RUNTIME_TMP | Out-Null
            }
            $probe = Join-Path $script:WL_RUNTIME_TMP 'nvdec-probe.mp4'
            & $ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=320x240:rate=30' -t 1 -c:v libx264 -pix_fmt yuv420p $probe 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                & $ffmpeg -hide_banner -loglevel error -y -c:v h264_cuvid -i $probe -f null - 2>$null | Out-Null
                $nvdec = ($LASTEXITCODE -eq 0)
            }
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        }
        return (ConvertFrom-WLGpuProbe -CsvLine $csv -Nvdec $nvdec)
    } catch {
        return (ConvertFrom-WLGpuProbe -CsvLine '' -Nvdec $false)
    } finally {
        $ErrorActionPreference = $orig
    }
}

# Can the venv's ctranslate2 actually reach CUDA? Distinct from "a GPU
# exists": requires the GPU pip wheels + loadable DLLs. Run after
# Install-WLRuntimePython; result persists as gpu.cuda_whisper.
function Test-WLCudaWhisper {
    $py = Get-WLWorkerPython
    if (-not (Test-Path -LiteralPath $py)) { return $false }
    $code = "import sys; sys.path.insert(0, r'$($script:WL_WORKER_DIR)'); " +
            'import cuda_paths; cuda_paths.add_cuda_dll_dirs(); ' +
            'import ctranslate2; print(ctranslate2.get_cuda_device_count())'
    $orig = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $out = @(& $py -c $code 2>$null)
        if ($LASTEXITCODE -ne 0 -or $out.Count -eq 0) { return $false }
        $n = 0
        [void][int]::TryParse([string]$out[$out.Count - 1], [ref]$n)
        return ($n -gt 0)
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $orig
    }
}

# Extra worker env per stage -- native replacements for the docker flag
# builders. Tools/stills: request NVDEC decode only when verified.
function Get-WLToolsWorkerEnv {
    param($Gpu)
    $present = Get-WLObjectProp $Gpu 'present'
    $nvdec   = Get-WLObjectProp $Gpu 'nvdec'
    if ($present -and $nvdec) { return @{ W_HWACCEL = 'cuda' } }
    return @{}
}

# Whisper: cuda/float16 only when the venv-level CUDA probe passed too;
# a GPU without working CUDA wheels degrades to cpu/int8, never to a
# failed run.
function Get-WLWhisperWorkerEnv {
    param($Gpu, [Parameter(Mandatory)][string]$ModelsRoot)
    $present = Get-WLObjectProp $Gpu 'present'
    $cudaWhisper = Get-WLObjectProp $Gpu 'cuda_whisper'
    # Symlink warning off: without Windows Developer Mode huggingface_hub
    # falls back to a copy-based cache and prints an alarming (harmless)
    # warning on every model load.
    $vars = @{
        HF_HOME                         = (Join-Path $ModelsRoot 'hf-cache')
        HF_HUB_DISABLE_SYMLINKS_WARNING = '1'
    }
    if ($present -and $cudaWhisper) {
        $vars.W_DEVICE = 'cuda'
        $vars.W_COMPUTE = 'float16'
    } else {
        $vars.W_DEVICE = 'cpu'
        $vars.W_COMPUTE = 'int8'
    }
    return $vars
}

#endregion
