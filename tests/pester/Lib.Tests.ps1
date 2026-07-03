# Pester tests for scripts/_lib.ps1 helpers.
#
# Run:   Invoke-Pester -Path tests/pester/Lib.Tests.ps1
#
# Pester 5 syntax.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).ProviderPath
    $script:LibPath = Join-Path $Root 'plugins\watch-local\scripts\_lib.ps1'
    . $script:LibPath
}

Describe 'Time helpers' {
    It 'Format-WLTime handles short durations' {
        Format-WLTime 0       | Should -Be '00:00'
        Format-WLTime 65      | Should -Be '01:05'
        Format-WLTime 3661.4  | Should -Be '1:01:01'
    }

    It 'Format-WLTime casts double to int safely (no D2-on-double regression)' {
        # If this throws "Format specifier was invalid" the cast regressed.
        { Format-WLTime 1234.7 } | Should -Not -Throw
    }

    It 'Convert-WLTime parses SS, MM:SS, HH:MM:SS' {
        Convert-WLTime '45'       | Should -Be 45.0
        Convert-WLTime '01:30'    | Should -Be 90.0
        Convert-WLTime '01:02:03' | Should -Be 3723.0
    }

    It 'Convert-WLTime returns null for empty / null' {
        Convert-WLTime $null | Should -BeNullOrEmpty
        Convert-WLTime ''    | Should -BeNullOrEmpty
    }
}

Describe 'Slug helper' {
    It 'New-JobSlug returns 16-char hex' {
        $s = New-JobSlug 'https://example.com/video'
        $s | Should -Match '^[0-9a-f]{16}$'
    }

    It 'New-JobSlug differs across calls (includes ticks)' {
        $a = New-JobSlug 'same'
        Start-Sleep -Milliseconds 5
        $b = New-JobSlug 'same'
        $a | Should -Not -Be $b
    }
}

Describe 'Path translation' {
    It 'ConvertTo-DockerPath flips backslashes' {
        ConvertTo-DockerPath 'C:\foo\bar' | Should -Be 'C:/foo/bar'
    }

    It 'ConvertTo-HostPath rewrites /work/...' {
        $h = ConvertTo-HostPath -ContainerPath '/work/frames/frame_0001.jpg' `
            -WorkHost 'C:\jobs\abc'
        $h | Should -Be 'C:/jobs/abc/frames/frame_0001.jpg'
    }

    It 'ConvertTo-HostPath rewrites /input/...' {
        $h = ConvertTo-HostPath -ContainerPath '/input/video.mp4' `
            -WorkHost 'C:\jobs\abc' -InputHost 'D:\videos'
        $h | Should -Be 'D:/videos/video.mp4'
    }

    It 'ConvertTo-HostPath returns null for null input' {
        ConvertTo-HostPath -ContainerPath $null -WorkHost 'C:\anywhere' | Should -BeNullOrEmpty
    }
}

Describe 'Assert-InsideRoot scope invariant' {
    BeforeAll {
        $script:tmpRoot = Join-Path $env:TEMP ("wl-scope-test-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Force -Path (Join-Path $tmpRoot 'good') | Out-Null

        # Subshell helper. Lowers $ErrorActionPreference around the native call so
        # PS 7's $PSNativeCommandUseErrorActionPreference doesn't turn the child's
        # stderr + non-zero exit into a RemoteException in the parent test process.
        function script:Invoke-AssertSubshell([string]$Target, [string]$Root) {
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & powershell.exe -NoProfile -Command "
                    `$ErrorActionPreference = 'Continue'
                    . '$script:LibPath'
                    Assert-InsideRoot -Target '$Target' -Root '$Root'
                    exit 0
                " 2>&1 | Out-Null
                return $LASTEXITCODE
            } catch {
                return -1
            } finally {
                $ErrorActionPreference = $prev
            }
        }
    }
    AfterAll {
        if (Test-Path -LiteralPath $tmpRoot) {
            Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'accepts a strict subdir' {
        { Assert-InsideRoot -Target (Join-Path $tmpRoot 'good') -Root $tmpRoot } | Should -Not -Throw
    }

    It 'rejects parent dir' {
        Invoke-AssertSubshell $env:TEMP $tmpRoot | Should -Not -Be 0
    }

    It 'rejects root itself (only strict subdirs allowed)' {
        Invoke-AssertSubshell $tmpRoot $tmpRoot | Should -Not -Be 0
    }

    It 'rejects path traversal attempts' {
        Invoke-AssertSubshell "$tmpRoot\good\..\..\foo" $tmpRoot | Should -Not -Be 0
    }
}

Describe 'Confirm token helpers' {
    It 'New-ConfirmToken includes prefix' {
        $t = New-ConfirmToken 'TEST'
        $t | Should -Match '^TEST-[A-Z2-9]{6}$'
    }

    It 'Request-Confirm accepts matching non-interactive token' {
        Request-Confirm -ExpectedToken 'X' -NonInteractiveToken 'X' | Should -BeTrue
    }

    It 'Request-Confirm rejects mismatched non-interactive token' {
        Request-Confirm -ExpectedToken 'X' -NonInteractiveToken 'Y' | Should -BeFalse
    }
}

Describe 'Partial SHA helper' {
    It 'returns lowercase hex for an existing file' {
        $tmp = New-TemporaryFile
        try {
            'hello world' | Set-Content -LiteralPath $tmp.FullName -NoNewline
            $h = Get-PartialSHA256 -path $tmp.FullName
            $h | Should -Match '^[0-9a-f]{64}$'
        } finally {
            Remove-Item -LiteralPath $tmp.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns null for missing file' {
        Get-PartialSHA256 -path (Join-Path $env:TEMP ('nope-' + [Guid]::NewGuid())) | Should -BeNullOrEmpty
    }
}

Describe 'Config helpers' {
    BeforeAll {
        $script:origConfig = $script:WL_CONFIG_FILE
        $script:tmpCfg = New-TemporaryFile
        Remove-Item -LiteralPath $tmpCfg.FullName -Force
        # Re-point lib's config location to our scratch file.
        $script:WL_CONFIG_FILE = $tmpCfg.FullName
    }
    AfterAll {
        $script:WL_CONFIG_FILE = $script:origConfig
        if (Test-Path -LiteralPath $tmpCfg.FullName) {
            Remove-Item -LiteralPath $tmpCfg.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Get-WLConfig returns defaults when no file' {
        $cfg = Get-WLConfig
        $cfg.default_model | Should -Be 'large-v3'
        $cfg.min_free_gb_jobs | Should -Be 2
    }

    It 'Save-WLConfig round-trips' {
        $cfg = Get-WLConfig
        $cfg.default_model = 'medium'
        Save-WLConfig $cfg
        $cfg2 = Get-WLConfig
        $cfg2.default_model | Should -Be 'medium'
    }
}
