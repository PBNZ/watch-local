# Pester tests for scripts/_runtime.ps1 -- manifest integrity, runtime
# status checks against a fabricated tree, and worker-env composition.
# No downloads, no provisioned runtime required.
#
# Run:   Invoke-Pester -Path tests/pester/Runtime.Tests.ps1

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
    $script:LibPath = Join-Path $Root 'plugins/watch-local/scripts/_lib.ps1'
    . $script:LibPath
}

Describe 'Get-WLPinnedFile download verification (supply-chain gate)' {
    # The compare-and-reject branch is the integrity gate for every
    # pinned binary; a mutation here (flipped comparison, dropped throw)
    # must fail the suite. The network fetch is mocked -- Invoke-WebRequest
    # writes attacker/plausible bytes to -OutFile like the real one.
    BeforeAll {
        $script:payload = 'pinned-binary-payload'
        $script:goodHash = $null
        $probe = Join-Path $TestDrive 'hash-probe.bin'
        [System.IO.File]::WriteAllText($probe, $payload)
        $script:goodHash = Get-WLFileSHA256 $probe
    }

    BeforeEach {
        Mock Invoke-WebRequest {
            [System.IO.File]::WriteAllText($OutFile, $script:payload)
        }
    }

    It 'throws on a sha256 mismatch AND removes the downloaded file' {
        $dest = Join-Path $TestDrive 'dl-bad.bin'
        $wrong = '0' * 64
        { Get-WLPinnedFile -Url 'https://example.invalid/x.bin' -Dest $dest -Sha256 $wrong } |
            Should -Throw '*sha256 mismatch*'
        Test-Path -LiteralPath $dest | Should -BeFalse
    }

    It 'accepts a matching hash (case-insensitively) and keeps the file' {
        $dest = Join-Path $TestDrive 'dl-good.bin'
        { Get-WLPinnedFile -Url 'https://example.invalid/x.bin' -Dest $dest -Sha256 $script:goodHash.ToUpper() } |
            Should -Not -Throw
        Test-Path -LiteralPath $dest | Should -BeTrue
    }
}

Describe 'runtime-manifest.json integrity' {
    BeforeAll {
        $script:m = Get-WLRuntimeManifest
    }

    It 'parses and carries schema + python pin + pip sets' {
        $m.schema | Should -Be 1
        [string]$m.python | Should -Match '^3\.\d+$'
        @($m.pip.common).Count | Should -BeGreaterThan 0
        @($m.pip.gpu).Count | Should -BeGreaterThan 0
    }

    It 'pins all four binaries with version + find names' {
        foreach ($name in @('uv', 'ytdlp', 'deno', 'ffmpeg')) {
            $spec = Get-WLObjectProp $m.binaries $name
            $spec | Should -Not -BeNullOrEmpty
            [string](Get-WLObjectProp $spec 'version') | Should -Not -BeNullOrEmpty
            @(Get-WLObjectProp $spec 'find').Count | Should -BeGreaterThan 0
        }
    }

    It 'every platform entry has https URLs and 64-hex sha256 pins' {
        foreach ($name in @('uv', 'ytdlp', 'deno', 'ffmpeg')) {
            $spec = Get-WLObjectProp $m.binaries $name
            foreach ($platform in @('win_x64', 'linux_x64', 'macos_arm64')) {
                $plat = Get-WLObjectProp $spec $platform
                $plat | Should -Not -BeNullOrEmpty -Because "$name should pin $platform"
                foreach ($f in @(Get-WLObjectProp $plat 'files')) {
                    [string](Get-WLObjectProp $f 'url') | Should -Match '^https://'
                    [string](Get-WLObjectProp $f 'sha256') | Should -Match '^[0-9a-f]{64}$'
                }
            }
        }
    }

    It 'pip pins are exact (==) so installs are reproducible' {
        foreach ($p in @($m.pip.common) + @($m.pip.gpu)) {
            $p | Should -Match '=='
        }
    }
}

Describe 'Test-WLRuntime against a fabricated tree' {
    BeforeAll {
        # Redirect all runtime paths into a sandbox.
        $script:origVars = @{}
        foreach ($v in 'WL_RUNTIME_DIR', 'WL_RUNTIME_BIN', 'WL_RUNTIME_VENV', 'WL_RUNTIME_STATE') {
            $script:origVars[$v] = Get-Variable -Name $v -Scope Script -ValueOnly
        }
        # GetTempPath, not $env:TEMP -- TEMP is undefined on stock Linux.
        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('wl-rt-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:WL_RUNTIME_DIR   = $sandbox
        $script:WL_RUNTIME_BIN   = Join-Path $sandbox 'bin'
        $script:WL_RUNTIME_VENV  = Join-Path $sandbox 'venvs/whisper'
        $script:WL_RUNTIME_STATE = Join-Path $sandbox 'manifest.json'

        $suffix = Get-WLExeSuffix
        $ffDir = Join-Path $script:WL_RUNTIME_BIN 'ffmpeg/bin'
        $pyDir = Join-Path $script:WL_RUNTIME_VENV $(if ($script:WL_IS_WINDOWS) { 'Scripts' } else { 'bin' })
        New-Item -ItemType Directory -Force -Path $script:WL_RUNTIME_BIN, $ffDir, $pyDir | Out-Null
        foreach ($f in @("yt-dlp$suffix", "deno$suffix", "uv$suffix")) {
            Set-Content -LiteralPath (Join-Path $script:WL_RUNTIME_BIN $f) -Value 'stub'
        }
        foreach ($f in @("ffmpeg$suffix", "ffprobe$suffix")) {
            Set-Content -LiteralPath (Join-Path $ffDir $f) -Value 'stub'
        }
        Set-Content -LiteralPath (Join-Path $pyDir "python$suffix") -Value 'stub'
        @{ schema = 1; gpu_deps = $false; binaries = @{ uv = 'x'; ytdlp = 'x'; deno = 'x'; ffmpeg = 'x' } } |
            ConvertTo-Json | Set-Content -LiteralPath $script:WL_RUNTIME_STATE
    }
    AfterAll {
        foreach ($v in $script:origVars.Keys) {
            Set-Variable -Name $v -Scope Script -Value $script:origVars[$v]
        }
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'reports ok for a complete tree' {
        $s = Test-WLRuntime
        $s.ok | Should -BeTrue
        $s.provisioned | Should -BeTrue
        $s.ytdlp | Should -BeTrue
        $s.ffmpeg | Should -BeTrue
        $s.python | Should -BeTrue
    }

    It 'reports not-ok when a binary goes missing' {
        $suffix = Get-WLExeSuffix
        Remove-Item -LiteralPath (Join-Path $script:WL_RUNTIME_BIN "yt-dlp$suffix") -Force
        $s = Test-WLRuntime
        $s.ok | Should -BeFalse
        $s.ytdlp | Should -BeFalse
    }

    It 'reports not-provisioned when the installed manifest is absent' {
        Remove-Item -LiteralPath $script:WL_RUNTIME_STATE -Force
        $s = Test-WLRuntime
        $s.provisioned | Should -BeFalse
        $s.ok | Should -BeFalse
    }
}

Describe 'Get-WLWorkerEnv composition' {
    It 'prepends runtime bin dirs to PATH' {
        $v = Get-WLWorkerEnv
        $sep = [System.IO.Path]::PathSeparator
        $v.PATH | Should -Match ([regex]::Escape("$($script:WL_RUNTIME_BIN)$sep"))
        $v.PATH.IndexOf($script:WL_RUNTIME_BIN) | Should -Be 0
        $v.PATH | Should -Match ([regex]::Escape((Split-Path (Get-WLFfmpegBin) -Parent)))
    }

    It 'pins python + deno behavior inside the runtime dir' {
        $v = Get-WLWorkerEnv
        $v.PYTHONUNBUFFERED | Should -Be '1'
        $v.PYTHONUTF8 | Should -Be '1'
        $v.DENO_DIR | Should -Match ([regex]::Escape($script:WL_RUNTIME_DIR))
    }

    It 'merges caller extras last' {
        $v = Get-WLWorkerEnv -Extra @{ W_MODEL = 'tiny'; W_WORK_DIR = 'C:\x' }
        $v.W_MODEL | Should -Be 'tiny'
        $v.W_WORK_DIR | Should -Be 'C:\x'
    }
}

Describe 'Platform key' {
    It 'resolves to a known key on this host' {
        Get-WLRuntimePlatform | Should -BeIn @('win_x64', 'linux_x64', 'macos_arm64', 'macos_x64')
    }
}
