# Pester tests for GPU detection / mode-selection helpers in scripts/_lib.ps1
# and scripts/_runtime.ps1.
#
# Run:   Invoke-Pester -Path tests/pester/Gpu.Tests.ps1
#
# Pester 5 syntax. No provisioned runtime required -- these cover the pure
# helpers; Test-WLGpuNative itself is exercised by the integration layer.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
    $script:LibPath = Join-Path $Root 'plugins/watch-local/scripts/_lib.ps1'
    . $script:LibPath
}

Describe 'ConvertFrom-WLGpuProbe' {
    It 'parses a nvidia-smi csv line into a gpu object' {
        $g = ConvertFrom-WLGpuProbe -CsvLine 'NVIDIA RTX PRO 5000 Blackwell, 596.59, 48935 MiB, 12.0' -Nvdec $true
        $g.present     | Should -BeTrue
        $g.name        | Should -Be 'NVIDIA RTX PRO 5000 Blackwell'
        $g.driver      | Should -Be '596.59'
        $g.vram_mb     | Should -Be 48935
        $g.compute_cap | Should -Be '12.0'
        $g.nvdec       | Should -BeTrue
        $g.checked_at  | Should -Match '^\d{4}-\d{2}-\d{2}T'
    }

    It 'carries nvdec=false through' {
        (ConvertFrom-WLGpuProbe -CsvLine 'Some GPU, 1.0, 1024 MiB, 8.9' -Nvdec $false).nvdec | Should -BeFalse
    }

    It 'returns present=false for empty / garbage input' {
        (ConvertFrom-WLGpuProbe -CsvLine '' -Nvdec $false).present | Should -BeFalse
        (ConvertFrom-WLGpuProbe -CsvLine $null -Nvdec $false).present | Should -BeFalse
        (ConvertFrom-WLGpuProbe -CsvLine 'not a csv line' -Nvdec $false).present | Should -BeFalse
    }
}

Describe 'Whisper worker env selection' {
    BeforeEach {
        # A real (Pester-managed) dir: Join-Path on Linux pwsh validates
        # drive qualifiers, so a literal 'C:\m' throws there.
        $script:modelsRoot = Join-Path $TestDrive 'models'
    }

    It 'GPU with working CUDA whisper gets cuda/float16 + HF_HOME under models root' {
        $gpu = [pscustomobject]@{ present = $true; cuda_whisper = $true }
        $v = Get-WLWhisperWorkerEnv -Gpu $gpu -ModelsRoot $modelsRoot
        $v.W_DEVICE  | Should -Be 'cuda'
        $v.W_COMPUTE | Should -Be 'float16'
        $v.HF_HOME   | Should -Be (Join-Path $modelsRoot 'hf-cache')
        $v.HF_HUB_DISABLE_SYMLINKS_WARNING | Should -Be '1'
    }

    It 'no GPU gets cpu/int8' {
        $gpu = [pscustomobject]@{ present = $false; cuda_whisper = $false }
        $v = Get-WLWhisperWorkerEnv -Gpu $gpu -ModelsRoot $modelsRoot
        $v.W_DEVICE  | Should -Be 'cpu'
        $v.W_COMPUTE | Should -Be 'int8'
        $v.HF_HOME   | Should -Be (Join-Path $modelsRoot 'hf-cache')
    }

    It 'GPU whose CUDA wheels do not load degrades to cpu/int8 (present=true, cuda_whisper=false)' {
        $gpu = [pscustomobject]@{ present = $true; cuda_whisper = $false }
        $v = Get-WLWhisperWorkerEnv -Gpu $gpu -ModelsRoot $modelsRoot
        $v.W_DEVICE  | Should -Be 'cpu'
        $v.W_COMPUTE | Should -Be 'int8'
    }

    It 'tolerates a gpu object missing cuda_whisper (docker-era config) -> cpu' {
        $gpu = [pscustomobject]@{ present = $true; nvdec = $true }
        (Get-WLWhisperWorkerEnv -Gpu $gpu -ModelsRoot $modelsRoot).W_DEVICE | Should -Be 'cpu'
    }

    # cpu_threads (#34). Unpinned CPU runs auto-size to physical cores;
    # a platform that will not report them leaves the var unset so the
    # worker's own fallback decides -- either way, never a flat 4.
    It 'auto-sizes W_CPU_THREADS on CPU when no pin is configured' {
        $gpu = [pscustomobject]@{ present = $false; cuda_whisper = $false }
        $cores = Get-WLPhysicalCoreCount
        foreach ($v in @(
            (Get-WLWhisperWorkerEnv -Gpu $gpu -ModelsRoot $modelsRoot),
            (Get-WLWhisperWorkerEnv -Gpu $gpu -ModelsRoot $modelsRoot -CpuThreads $null)
        )) {
            if ($null -eq $cores) {
                $v.Keys | Should -Not -Contain 'W_CPU_THREADS'
            } else {
                $v.W_CPU_THREADS | Should -Be ([string]$cores)
            }
        }
    }

    It 'forwards a configured pin on CPU' {
        $gpu = [pscustomobject]@{ present = $false; cuda_whisper = $false }
        (Get-WLWhisperWorkerEnv -Gpu $gpu -ModelsRoot $modelsRoot -CpuThreads 6).W_CPU_THREADS | Should -Be '6'
    }

    It 'forwards an explicit 0 (restores the faster-whisper default)' {
        $gpu = [pscustomobject]@{ present = $false; cuda_whisper = $false }
        (Get-WLWhisperWorkerEnv -Gpu $gpu -ModelsRoot $modelsRoot -CpuThreads 0).W_CPU_THREADS | Should -Be '0'
    }

    It 'treats a negative pin as no pin (auto-sizes instead of passing garbage)' {
        $gpu = [pscustomobject]@{ present = $false; cuda_whisper = $false }
        $v = Get-WLWhisperWorkerEnv -Gpu $gpu -ModelsRoot $modelsRoot -CpuThreads -3
        $cores = Get-WLPhysicalCoreCount
        if ($null -eq $cores) {
            $v.Keys | Should -Not -Contain 'W_CPU_THREADS'
        } else {
            $v.W_CPU_THREADS | Should -Be ([string]$cores)
        }
    }

    It 'never pins threads on a GPU run' {
        $gpu = [pscustomobject]@{ present = $true; cuda_whisper = $true }
        $v = Get-WLWhisperWorkerEnv -Gpu $gpu -ModelsRoot $modelsRoot -CpuThreads 6
        $v.W_DEVICE | Should -Be 'cuda'
        $v.Keys | Should -Not -Contain 'W_CPU_THREADS'
    }
}

Describe 'Process tree discovery' {
    It 'always includes the root pid' {
        (Get-WLProcessTreeIds -RootId $PID) | Should -Contain $PID
    }

    It 'finds a spawned child (the uv trampoline case benchmarks depend on)' {
        # Any child will do; the point is that descendants are reachable.
        # -NoNewWindow, not -WindowStyle: the latter is a terminating
        # error on non-Windows PowerShell, which would take this test --
        # and all Linux coverage of the tree walk -- out entirely.
        $sleeper = Start-Process -FilePath (Get-Process -Id $PID).Path `
                                 -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 6') `
                                 -PassThru -NoNewWindow
        try {
            Start-Sleep -Milliseconds 1500
            $ids = @(Get-WLProcessTreeIds -RootId $PID)
            $ids | Should -Contain $sleeper.Id
        } finally {
            Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns just the root for a pid with no children' {
        $ids = @(Get-WLProcessTreeIds -RootId 999999)
        $ids.Count | Should -Be 1
        $ids[0] | Should -Be 999999
    }

    It 'does not adopt processes that started before the root (recycled PID guard)' {
        # Every live process older than this shell would be swept in if
        # the walk trusted parent ids alone; the tree must stay small.
        $ids = @(Get-WLProcessTreeIds -RootId $PID)
        $ids.Count | Should -BeLessThan 40
        foreach ($id in $ids) {
            if ($id -eq $PID) { continue }
            $child = Get-Process -Id $id -ErrorAction SilentlyContinue
            if ($child) {
                try { $child.StartTime | Should -BeGreaterOrEqual (Get-Process -Id $PID).StartTime } catch { }
            }
        }
    }
}

Describe 'Physical core detection' {
    It 'returns a positive count or null, never zero or negative' {
        $cores = Get-WLPhysicalCoreCount
        if ($null -ne $cores) { $cores | Should -BeGreaterThan 0 }
    }

    It 'never exceeds the CPUs this process may use' {
        $cores = Get-WLPhysicalCoreCount
        if ($null -ne $cores) { $cores | Should -BeLessOrEqual ([Environment]::ProcessorCount) }
    }

    It 'is stable across calls (cached)' {
        Get-WLPhysicalCoreCount | Should -Be (Get-WLPhysicalCoreCount)
    }
}

Describe 'Tools worker env (NVDEC decode)' {
    It 'GPU with NVDEC gets W_HWACCEL=cuda' {
        $gpu = [pscustomobject]@{ present = $true; nvdec = $true }
        (Get-WLToolsWorkerEnv -Gpu $gpu).W_HWACCEL | Should -Be 'cuda'
    }

    It 'GPU without NVDEC gets no hwaccel env' {
        $gpu = [pscustomobject]@{ present = $true; nvdec = $false }
        (Get-WLToolsWorkerEnv -Gpu $gpu).Count | Should -Be 0
    }

    It 'no GPU gets no hwaccel env' {
        $gpu = [pscustomobject]@{ present = $false; nvdec = $false }
        (Get-WLToolsWorkerEnv -Gpu $gpu).Count | Should -Be 0
        (Get-WLToolsWorkerEnv -Gpu $null).Count | Should -Be 0
    }

    It 'tolerates a gpu object missing the nvdec property (pre-upgrade config)' {
        $gpu = [pscustomobject]@{ present = $true }
        (Get-WLToolsWorkerEnv -Gpu $gpu).Count | Should -Be 0
    }
}

Describe 'Platform default dirs' {
    It 'Windows dirs live under LOCALAPPDATA / TEMP' {
        # Pin the env vars for the duration: they are undefined on stock
        # Linux (GitHub ubuntu runners), and the assertion should be
        # deterministic everywhere.
        $oldLad = $env:LOCALAPPDATA
        $oldTemp = $env:TEMP
        try {
            $env:LOCALAPPDATA = Join-Path ([System.IO.Path]::GetTempPath()) 'wl-fake-localappdata'
            $env:TEMP = Join-Path ([System.IO.Path]::GetTempPath()) 'wl-fake-temp'
            $d = Get-WLPlatformDirs -IsWindowsPlatform $true
            $d.Base    | Should -Be (Join-Path $env:LOCALAPPDATA 'watch-local')
            $d.Staging | Should -Be (Join-Path $env:TEMP 'watch-local-stage')
        } finally {
            $env:LOCALAPPDATA = $oldLad
            $env:TEMP = $oldTemp
        }
    }

    It 'non-Windows dirs live under XDG data home + system temp' {
        $d = Get-WLPlatformDirs -IsWindowsPlatform $false
        $d.Base    | Should -Match 'watch-local$'
        $d.Base    | Should -Not -Match 'watch-local\\jobs'
        $d.Staging | Should -Match 'watch-local-stage$'
    }

    It 'lib exposes the platform flag' {
        # On the Windows dev box this is true; the assertion is that the
        # variable exists and is a bool (cross-platform init didn't throw).
        $script:WL_IS_WINDOWS | Should -BeOfType [bool]
    }
}

Describe 'Config gpu block round-trip' {
    BeforeAll {
        $script:origConfig = $script:WL_CONFIG_FILE
        $script:tmpCfg = New-TemporaryFile
        Remove-Item -LiteralPath $tmpCfg.FullName -Force
        $script:WL_CONFIG_FILE = $tmpCfg.FullName
    }
    AfterAll {
        $script:WL_CONFIG_FILE = $script:origConfig
        if (Test-Path -LiteralPath $tmpCfg.FullName) {
            Remove-Item -LiteralPath $tmpCfg.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    It 'defaults to no gpu block' {
        (Get-WLConfig).gpu | Should -BeNullOrEmpty
    }

    It 'persists and reloads the gpu block' {
        $cfg = Get-WLConfig
        $cfg.gpu = ConvertFrom-WLGpuProbe -CsvLine 'NVIDIA RTX PRO 5000 Blackwell, 596.59, 48935 MiB, 12.0' -Nvdec $true
        Save-WLConfig $cfg
        $cfg2 = Get-WLConfig
        $cfg2.gpu.present | Should -BeTrue
        $cfg2.gpu.name    | Should -Be 'NVIDIA RTX PRO 5000 Blackwell'
        $cfg2.gpu.nvdec   | Should -BeTrue
    }
}
