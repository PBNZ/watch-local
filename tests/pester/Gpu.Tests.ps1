# Pester tests for GPU detection / mode-selection helpers in scripts/_lib.ps1.
#
# Run:   Invoke-Pester -Path tests/pester/Gpu.Tests.ps1
#
# Pester 5 syntax. No docker required -- these cover the pure helpers;
# Test-WLGpu itself (docker probe) is exercised by the integration layer.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).ProviderPath
    $script:LibPath = Join-Path $Root 'plugins\watch-local\scripts\_lib.ps1'
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

Describe 'Whisper mode selection' {
    It 'GPU mode uses the CUDA image' {
        Get-WLWhisperImage -GpuPresent $true | Should -Be 'watch-local/whisper:cu128'
    }

    It 'CPU mode uses the CPU image' {
        Get-WLWhisperImage -GpuPresent $false | Should -Be 'watch-local/whisper:cpu'
    }

    It 'GPU mode flags request the GPU and keep the model cache env' {
        $f = Get-WLWhisperRunFlags -GpuPresent $true
        $f | Should -Contain '--gpus'
        $f | Should -Contain 'HF_HOME=/models/hf-cache'
        $f | Should -Not -Contain 'W_DEVICE=cpu'
    }

    It 'CPU mode flags request no GPU and force cpu/int8' {
        $f = Get-WLWhisperRunFlags -GpuPresent $false
        $f | Should -Not -Contain '--gpus'
        $f | Should -Contain 'W_DEVICE=cpu'
        $f | Should -Contain 'W_COMPUTE=int8'
        $f | Should -Contain 'HF_HOME=/models/hf-cache'
    }
}

Describe 'Tools GPU flags (NVDEC decode)' {
    It 'GPU with NVDEC gets gpu flags + W_HWACCEL' {
        $gpu = [pscustomobject]@{ present = $true; nvdec = $true }
        $f = Get-WLToolsGpuFlags -Gpu $gpu
        $f | Should -Contain '--gpus'
        $f | Should -Contain 'W_HWACCEL=cuda'
        ($f -join ' ') | Should -Match 'NVIDIA_DRIVER_CAPABILITIES='
    }

    It 'GPU without NVDEC gets no flags' {
        $gpu = [pscustomobject]@{ present = $true; nvdec = $false }
        Get-WLToolsGpuFlags -Gpu $gpu | Should -BeNullOrEmpty
    }

    It 'no GPU gets no flags' {
        $gpu = [pscustomobject]@{ present = $false; nvdec = $false }
        Get-WLToolsGpuFlags -Gpu $gpu | Should -BeNullOrEmpty
        Get-WLToolsGpuFlags -Gpu $null | Should -BeNullOrEmpty
    }

    It 'tolerates a gpu object missing the nvdec property (pre-upgrade config)' {
        $gpu = [pscustomobject]@{ present = $true }
        Get-WLToolsGpuFlags -Gpu $gpu | Should -BeNullOrEmpty
    }
}

Describe 'Platform default dirs' {
    It 'Windows dirs live under LOCALAPPDATA / TEMP' {
        $d = Get-WLPlatformDirs -IsWindowsPlatform $true
        $d.Base    | Should -Be (Join-Path $env:LOCALAPPDATA 'watch-local')
        $d.Staging | Should -Be (Join-Path $env:TEMP 'watch-local-stage')
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
