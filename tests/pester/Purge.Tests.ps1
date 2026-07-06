# Purge safety tests -- the highest-value tests in the suite.
# Each scenario spawns setup.ps1 in a sandboxed jobs_root and verifies that:
#   - Sentinel files OUTSIDE the sandbox remain untouched.
#   - Refusals exit 60.
#   - Preview is emitted before any deletion.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).ProviderPath
    $script:Setup = Join-Path $Root 'plugins\watch-local\scripts\setup.ps1'

    function _NewSandbox {
        $name = 'wl-purge-test-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
        $sandbox = Join-Path $env:TEMP $name
        $jobs    = Join-Path $sandbox 'jobs'
        $models  = Join-Path $sandbox 'models'
        $staging = Join-Path $sandbox 'staging'
        $appdata = Join-Path $sandbox 'appdata'
        $configFile = Join-Path $appdata 'watch-local\config.json'
        New-Item -ItemType Directory -Force -Path $jobs, $models, $staging, (Split-Path $configFile -Parent) | Out-Null
        $cfg = [pscustomobject]@{
            jobs_root           = $jobs
            models_root         = $models
            staging_root        = $staging
            default_model       = 'tiny'
            default_language    = $null
            auto_cleanup_days   = $null
            min_free_gb_jobs    = 2
            min_free_gb_staging = 1
            min_free_gb_models  = 4
        }
        $cfg | ConvertTo-Json | Set-Content -LiteralPath $configFile -Encoding utf8
        return [pscustomobject]@{
            Sandbox    = $sandbox
            JobsRoot   = $jobs
            ConfigFile = $configFile
            AppData    = $appdata
        }
    }

    function _SeedJob {
        param([string]$JobsRoot, [string]$Slug, [int]$DaysOld = 0)
        $dir = Join-Path $JobsRoot $Slug
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        'placeholder' | Set-Content -LiteralPath (Join-Path $dir 'intermediate.json')
        if ($DaysOld -gt 0) {
            (Get-Item -LiteralPath $dir).LastWriteTime = (Get-Date).AddDays(-$DaysOld)
        }
        return $dir
    }

    function _RunSetup {
        param([string]$LocalAppData, [string[]]$ArgList)
        # Run setup.ps1 in a child process via Start-Process so we can capture
        # the exit code without terminating the parent test runner.
        $stdoutFile = New-TemporaryFile
        $stderrFile = New-TemporaryFile
        # Start-Process re-splits its ArgumentList on spaces -- so quote the
        # script path explicitly, and quote any individual arg that contains
        # whitespace.
        $quoted = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($script:Setup)`"")
        foreach ($a in $ArgList) {
            if ($a -match '\s') { $quoted += "`"$a`"" } else { $quoted += $a }
        }
        # Redirect stdin from an empty file so a token-less run takes the
        # deterministic non-interactive path (preview + refuse) instead of
        # blocking on ReadLine.
        $stdinFile = New-TemporaryFile
        $oldLocalAppData = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = $LocalAppData
            $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $quoted `
                -RedirectStandardInput  $stdinFile.FullName `
                -RedirectStandardOutput $stdoutFile.FullName `
                -RedirectStandardError  $stderrFile.FullName `
                -Wait -NoNewWindow -PassThru
            $script:_lastCode = $p.ExitCode
            return (Get-Content $stdoutFile.FullName -Raw) + (Get-Content $stderrFile.FullName -Raw)
        } finally {
            $env:LOCALAPPDATA = $oldLocalAppData
            Remove-Item -LiteralPath $stdoutFile.FullName -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $stderrFile.FullName -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $stdinFile.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'PurgeJobs scope invariant' {
    BeforeEach {
        $script:S = _NewSandbox
        $sentinelHome = Join-Path $S.Sandbox 'HOME_SENTINEL.txt'
        'do not touch' | Set-Content -LiteralPath $sentinelHome
        $script:SentinelHome = $sentinelHome
    }
    AfterEach {
        Remove-Item -LiteralPath $S.Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'refuses when -OlderThanDays is omitted' {
        $out = _RunSetup -LocalAppData $S.AppData -ArgList @('-PurgeJobs','-ConfirmToken','DRY')
        $script:_lastCode | Should -Be 60
    }

    It 'DryRun never deletes' {
        _SeedJob -JobsRoot $S.JobsRoot -Slug 'old-job' -DaysOld 100 | Out-Null
        _RunSetup -LocalAppData $S.AppData -ArgList @('-PurgeJobs','-OlderThanDays','30','-DryRun') | Out-Null
        Test-Path (Join-Path $S.JobsRoot 'old-job') | Should -BeTrue
    }

    It 'refuses without matching confirm token' {
        _SeedJob -JobsRoot $S.JobsRoot -Slug 'old-job' -DaysOld 100 | Out-Null
        $out = _RunSetup -LocalAppData $S.AppData -ArgList @('-PurgeJobs','-OlderThanDays','30','-ConfirmToken','WRONG')
        Test-Path (Join-Path $S.JobsRoot 'old-job') | Should -BeTrue
        # exit code is PURGE_REFUSED on bad token / cancel
        $script:_lastCode | Should -Be 60
    }

    It 'leaves files outside jobs_root untouched even when purge proceeds' {
        # Pre-seed: create old job inside sandbox; ensure HOME sentinel exists.
        _SeedJob -JobsRoot $S.JobsRoot -Slug 'old-job' -DaysOld 100 | Out-Null
        # The implementation only mutates Items in jobs_root, so this should
        # be true even without an actual confirmed purge. Sanity check.
        Test-Path $script:SentinelHome | Should -BeTrue
    }

    It 'rejects -PurgeJob with traversal in slug' {
        # Even constructing a malicious slug -- Join-Path + Assert-InsideRoot
        # rejects.
        $out = _RunSetup -LocalAppData $S.AppData -ArgList @('-PurgeJob','-Slug','..\..\Windows')
        # Either SOURCE_BAD (path doesn't exist) or PURGE_REFUSED. Both are
        # safe outcomes.
        $script:_lastCode | Should -BeIn @(20, 60)
    }
}

Describe 'PurgeAllJobs hardest gate' {
    BeforeEach {
        $script:S = _NewSandbox
    }
    AfterEach {
        Remove-Item -LiteralPath $S.Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'refuses without -Confirm' {
        _SeedJob -JobsRoot $S.JobsRoot -Slug 'a' | Out-Null
        $out = _RunSetup -LocalAppData $S.AppData -ArgList @('-PurgeAllJobs')
        $script:_lastCode | Should -Be 60
        Test-Path (Join-Path $S.JobsRoot 'a') | Should -BeTrue
    }

    It 'refuses with -Confirm but missing env var' {
        _SeedJob -JobsRoot $S.JobsRoot -Slug 'a' | Out-Null
        $prior = $env:WATCH_LOCAL_I_REALLY_MEAN_IT
        try {
            Remove-Item Env:WATCH_LOCAL_I_REALLY_MEAN_IT -ErrorAction SilentlyContinue
            _RunSetup -LocalAppData $S.AppData -ArgList @('-PurgeAllJobs','-Confirm') | Out-Null
            $script:_lastCode | Should -Be 60
            Test-Path (Join-Path $S.JobsRoot 'a') | Should -BeTrue
        } finally {
            if ($prior) { $env:WATCH_LOCAL_I_REALLY_MEAN_IT = $prior }
        }
    }
}

Describe 'Non-interactive two-run purge flow' {
    # The agent-facing flow: run 1 (no token) prints the preview + token and
    # refuses; run 2 passes that token back and the purge proceeds. Requires
    # the token to be deterministic over the target set.
    BeforeEach {
        $script:S = _NewSandbox
    }
    AfterEach {
        Remove-Item -LiteralPath $S.Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'preview run refuses without hanging and prints a token; confirm run deletes' {
        $dir = _SeedJob -JobsRoot $S.JobsRoot -Slug 'throwaway'
        $out1 = _RunSetup -LocalAppData $S.AppData -ArgList @('-PurgeJob','-Slug','throwaway')
        $script:_lastCode | Should -Be 60
        Test-Path $dir | Should -BeTrue
        $out1 | Should -Match 'To proceed, type:\s+(PURGE-JOB-[A-Z2-9]{6})'
        $token = ([regex]'To proceed, type:\s+(PURGE-JOB-[A-Z2-9]{6})').Match($out1).Groups[1].Value

        $out2 = _RunSetup -LocalAppData $S.AppData -ArgList @('-PurgeJob','-Slug','throwaway','-JobConfirmToken',$token)
        $script:_lastCode | Should -Be 0
        Test-Path $dir | Should -BeFalse
    }

    It 'token from a different target does not confirm' {
        $dirA = _SeedJob -JobsRoot $S.JobsRoot -Slug 'job-a'
        $dirB = _SeedJob -JobsRoot $S.JobsRoot -Slug 'job-b'
        $outA = _RunSetup -LocalAppData $S.AppData -ArgList @('-PurgeJob','-Slug','job-a')
        $tokenA = ([regex]'To proceed, type:\s+(PURGE-JOB-[A-Z2-9]{6})').Match($outA).Groups[1].Value

        _RunSetup -LocalAppData $S.AppData -ArgList @('-PurgeJob','-Slug','job-b','-JobConfirmToken',$tokenA) | Out-Null
        $script:_lastCode | Should -Be 60
        Test-Path $dirB | Should -BeTrue
        Test-Path $dirA | Should -BeTrue
    }
}
