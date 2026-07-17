# Pester tests for scripts/_lib.ps1 helpers.
#
# Run:   Invoke-Pester -Path tests/pester/Lib.Tests.ps1
#
# Pester 5 syntax.

BeforeDiscovery {
    # -Skip: conditions are evaluated at discovery time, before BeforeAll
    # has dot-sourced the lib -- compute the platform here, not via
    # $script:WL_IS_WINDOWS.
    $script:OnWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
}

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
    $script:LibPath = Join-Path $Root 'plugins/watch-local/scripts/_lib.ps1'
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

Describe 'Display path normalization' {
    It 'ConvertTo-WLSlashPath flips backslashes' {
        ConvertTo-WLSlashPath 'C:\foo\bar' | Should -Be 'C:/foo/bar'
    }

    It 'ConvertTo-WLSlashPath leaves forward slashes alone' {
        ConvertTo-WLSlashPath 'C:/already/fine' | Should -Be 'C:/already/fine'
    }
}

Describe 'Assert-InsideRoot scope invariant' {
    BeforeAll {
        # [IO.Path]::GetTempPath(), not $env:TEMP -- TEMP is undefined on
        # stock Linux (e.g. GitHub's ubuntu runners).
        $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wl-scope-test-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Force -Path (Join-Path $tmpRoot 'good') | Out-Null

        # Subshell helper. Lowers $ErrorActionPreference around the native call so
        # PS 7's $PSNativeCommandUseErrorActionPreference doesn't turn the child's
        # stderr + non-zero exit into a RemoteException in the parent test process.
        # Child runs on the SAME engine as the test runner (Get-WLPSEngine), so
        # `powershell -File run-tests.ps1` covers 5.1 and `pwsh -File ...` covers 7.
        function script:Invoke-AssertSubshell([string]$Target, [string]$Root) {
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & (Get-WLPSEngine) -NoProfile -Command "
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
        Invoke-AssertSubshell ([System.IO.Path]::GetTempPath()) $tmpRoot | Should -Not -Be 0
    }

    It 'rejects root itself (only strict subdirs allowed)' {
        Invoke-AssertSubshell $tmpRoot $tmpRoot | Should -Not -Be 0
    }

    It 'rejects path traversal attempts' {
        Invoke-AssertSubshell "$tmpRoot\good\..\..\foo" $tmpRoot | Should -Not -Be 0
    }

    It 'rejects a sibling dir sharing the root as a string prefix' {
        # Root=.../jobs must not contain .../jobs-evil/x. Guards the
        # separator append in the containment predicate.
        $sibling = "$tmpRoot-evil"
        New-Item -ItemType Directory -Force -Path (Join-Path $sibling 'x') | Out-Null
        try {
            Invoke-AssertSubshell (Join-Path $sibling 'x') $tmpRoot | Should -Not -Be 0
        } finally {
            Remove-Item -LiteralPath $sibling -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'treats case-distinct paths as outside root on case-sensitive filesystems' -Skip:$script:OnWindows {
        # On default Linux, .../JOBS is a physically different directory
        # from the .../jobs root; the guard must not case-fold it inside.
        $upper = Join-Path (Split-Path $tmpRoot -Parent) ((Split-Path $tmpRoot -Leaf).ToUpper())
        New-Item -ItemType Directory -Force -Path (Join-Path $upper 'secret') | Out-Null
        try {
            Invoke-AssertSubshell (Join-Path $upper 'secret') $tmpRoot | Should -Not -Be 0
        } finally {
            Remove-Item -LiteralPath $upper -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects a junction inside root pointing outside root' -Skip:(-not $script:OnWindows) {
        # Reparse defense-in-depth: a junction under jobs_root whose target
        # escapes the root must be judged by its resolved location.
        $outside = Join-Path ([System.IO.Path]::GetTempPath()) ("wl-scope-outside-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $outside | Out-Null
        $junction = Join-Path $tmpRoot 'jx'
        try {
            New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
            Invoke-AssertSubshell $junction $tmpRoot | Should -Not -Be 0
        } finally {
            if (Test-Path -LiteralPath $junction) {
                Remove-Item -LiteralPath $junction -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $outside -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'still accepts an ordinary subdir on a OneDrive-style reparse tree' {
        # Regression guard: non-link reparse tags (cloud placeholders) have
        # no LinkType and must not trip the fail-closed link handling.
        { Assert-InsideRoot -Target (Join-Path $tmpRoot 'good') -Root $tmpRoot } | Should -Not -Throw
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

    It 'seeded tokens are deterministic per target set' {
        (New-ConfirmToken 'TEST' -Seed 'C:\jobs\a') | Should -Be (New-ConfirmToken 'TEST' -Seed 'C:\jobs\a')
        (New-ConfirmToken 'TEST' -Seed 'C:\jobs\a') | Should -Match '^TEST-[A-Z2-9]{6}$'
        (New-ConfirmToken 'TEST' -Seed 'C:\jobs\a') | Should -Not -Be (New-ConfirmToken 'TEST' -Seed 'C:\jobs\b')
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
        Get-PartialSHA256 -path (Join-Path ([System.IO.Path]::GetTempPath()) ('nope-' + [Guid]::NewGuid())) | Should -BeNullOrEmpty
    }
}

Describe 'Full-file SHA256 helper (Get-WLFileSHA256)' {
    # Backs Get-WLPinnedFile's download verification -- replaced
    # Get-FileHash, which a polluted PSModulePath can make unresolvable
    # under Windows PowerShell 5.1.
    It 'matches the known SHA256 of a fixed input' {
        $f = Join-Path $TestDrive 'sha-vector.txt'
        [System.IO.File]::WriteAllText($f, 'hello world')
        Get-WLFileSHA256 $f | Should -Be 'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9'
    }

    It 'throws for a missing file (verification must not silently pass)' {
        { Get-WLFileSHA256 (Join-Path $TestDrive 'does-not-exist.bin') } | Should -Throw
    }
}

Describe 'Child spawn helper (Invoke-WLChild)' {
    # Regression for the 0.5.0-rc.1 onboarding -Yes failure: the child's
    # stdout leaked onto the helper's pipeline, so callers received
    # @(<stdout lines>, <exit code>) and `$code -ne 0` element-filtered
    # that array to a truthy non-empty collection even on success.
    BeforeAll {
        $script:childDir = Join-Path $TestDrive 'child-spawn'
        New-Item -ItemType Directory -Force -Path $childDir | Out-Null

        # Mirrors setup.ps1 -DetectGpu: JSON on stdout, then exit 0.
        $script:okChild = Join-Path $childDir 'ok.ps1'
        Set-Content -LiteralPath $okChild -Value @'
@{ present = $false } | ConvertTo-Json | Write-Output
exit 0
'@

        $script:failChild = Join-Path $childDir 'fail.ps1'
        Set-Content -LiteralPath $failChild -Value @'
Write-Output 'some stdout noise'
exit 7
'@
    }

    It 'returns scalar 0 for a stdout-writing child that succeeds' {
        $code = Invoke-WLChild $okChild
        $code | Should -BeOfType [int]
        $code | Should -Be 0
        ($code -ne 0) | Should -BeFalse
    }

    It 'returns the scalar exit code for a stdout-writing child that fails' {
        $code = Invoke-WLChild $failChild
        $code | Should -BeOfType [int]
        $code | Should -Be 7
    }

    It 'passes child args through' {
        $argChild = Join-Path $childDir 'args.ps1'
        Set-Content -LiteralPath $argChild -Value @'
param([int]$Code)
exit $Code
'@
        Invoke-WLChild $argChild @('-Code', '5') | Should -Be 5
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
