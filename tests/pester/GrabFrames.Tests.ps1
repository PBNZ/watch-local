# grab-frames source-resolution tests -- lock the R1.1 fix.
# A plain local job (source left in place, no download/ dir) must resolve the
# original source via the job's job.json; unreachable sources must fail with
# exit 20 and an actionable message. All paths tested here exit before any
# worker invocation, so the unit layer needs no provisioned runtime.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
    $script:Grab = Join-Path $Root 'plugins/watch-local/scripts/grab-frames.ps1'

    # Child scripts run on the SAME engine as the test runner, so the suite
    # covers PowerShell 5.1 when launched via powershell.exe and PowerShell 7
    # when launched via pwsh (mirrors _lib.ps1's Get-WLPSEngine).
    $script:PSEngine = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell.exe' }

    function _NewSandbox {
        $name = 'wl-grab-test-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
        $sandbox = Join-Path $env:TEMP $name
        $jobs    = Join-Path $sandbox 'jobs'
        $appdata = Join-Path $sandbox 'appdata'
        $configFile = Join-Path $appdata 'watch-local/config.json'
        New-Item -ItemType Directory -Force -Path $jobs, (Split-Path $configFile -Parent) | Out-Null
        [pscustomobject]@{
            jobs_root           = $jobs
            models_root         = (Join-Path $sandbox 'models')
            staging_root        = (Join-Path $sandbox 'staging')
            default_model       = 'tiny'
            default_language    = $null
            auto_cleanup_days   = $null
            min_free_gb_jobs    = 2
            min_free_gb_staging = 1
            min_free_gb_models  = 4
        } | ConvertTo-Json | Set-Content -LiteralPath $configFile -Encoding utf8
        return [pscustomobject]@{ Sandbox = $sandbox; JobsRoot = $jobs; AppData = $appdata }
    }

    function _SeedJob {
        param([string]$JobsRoot, [string]$Slug, [string]$OriginalPath = $null)
        $dir = Join-Path $JobsRoot $Slug
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        if ($null -ne $OriginalPath) {
            [pscustomobject]@{
                slug          = $Slug
                source        = $OriginalPath
                is_url        = $false
                original_path = $OriginalPath
                work_dir      = $dir
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'job.json') -Encoding utf8
        }
        return $dir
    }

    function _RunGrab {
        param([string]$LocalAppData, [string[]]$ArgList)
        $stdoutFile = New-TemporaryFile
        $stderrFile = New-TemporaryFile
        $quoted = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($script:Grab)`"")
        foreach ($a in $ArgList) {
            if ($a -match '\s') { $quoted += "`"$a`"" } else { $quoted += $a }
        }
        # Redirect the state root into the sandbox on BOTH platforms:
        # _lib.ps1 reads LOCALAPPDATA on Windows and XDG_DATA_HOME elsewhere.
        $oldLocalAppData = $env:LOCALAPPDATA
        $oldXdg = $env:XDG_DATA_HOME
        try {
            $env:LOCALAPPDATA = $LocalAppData
            $env:XDG_DATA_HOME = $LocalAppData
            $p = Start-Process -FilePath $script:PSEngine -ArgumentList $quoted `
                -RedirectStandardOutput $stdoutFile.FullName `
                -RedirectStandardError  $stderrFile.FullName `
                -Wait -NoNewWindow -PassThru
            $script:_lastCode = $p.ExitCode
            return (Get-Content $stdoutFile.FullName -Raw) + (Get-Content $stderrFile.FullName -Raw)
        } finally {
            $env:LOCALAPPDATA = $oldLocalAppData
            $env:XDG_DATA_HOME = $oldXdg
            Remove-Item -LiteralPath $stdoutFile.FullName -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $stderrFile.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'grab-frames source resolution (plain local jobs)' {
    BeforeEach {
        $script:S = _NewSandbox
    }
    AfterEach {
        Remove-Item -LiteralPath $S.Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'fails with exit 20 and actionable message when job has no download and no job.json' {
        _SeedJob -JobsRoot $S.JobsRoot -Slug 'bare-job' | Out-Null
        $out = _RunGrab -LocalAppData $S.AppData -ArgList @('-Slug','bare-job','-Screenshots','0:05')
        $script:_lastCode | Should -Be 20
        $out | Should -Match 'no recorded original path'
        $out | Should -Match 'IncludeSource'
    }

    It 'fails with exit 20 when a UNC original source is unreachable (reachable shares are read directly now)' {
        # Native ffmpeg reads \\server\share paths itself, so UNC sources are
        # no longer refused outright -- an unreachable one falls through to
        # the same "no longer at" path as a deleted local source.
        _SeedJob -JobsRoot $S.JobsRoot -Slug 'unc-job' -OriginalPath '\\nas\share\talk.mkv' | Out-Null
        $out = _RunGrab -LocalAppData $S.AppData -ArgList @('-Slug','unc-job','-Screenshots','0:05')
        $script:_lastCode | Should -Be 20
        $out | Should -Match 'no longer at'
    }

    It 'fails with exit 20 when the recorded local source no longer exists' {
        $gone = Join-Path $S.Sandbox 'videos/deleted.mp4'
        _SeedJob -JobsRoot $S.JobsRoot -Slug 'gone-job' -OriginalPath $gone | Out-Null
        $out = _RunGrab -LocalAppData $S.AppData -ArgList @('-Slug','gone-job','-Screenshots','0:05')
        $script:_lastCode | Should -Be 20
        $out | Should -Match 'no longer at'
    }

    It 'fails with exit 20 when the job dir itself does not exist' {
        $out = _RunGrab -LocalAppData $S.AppData -ArgList @('-Slug','nope','-Screenshots','0:05')
        $script:_lastCode | Should -Be 20
        $out | Should -Match 'job dir not found'
    }

    It 'refuses a traversal slug with exit 60' {
        $out = _RunGrab -LocalAppData $S.AppData -ArgList @('-Slug','../../Windows','-Screenshots','0:05')
        $script:_lastCode | Should -Be 60
    }
}

Describe 'save-here slug validation (destination-side scope safety)' {
    BeforeEach {
        $script:S = _NewSandbox
    }
    AfterEach {
        Remove-Item -LiteralPath $S.Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'refuses a slug with separators or .. before touching the destination' {
        # A traversal slug can re-resolve INSIDE jobs_root on the source side
        # while redirecting the destination overwrite outside
        # watch-local-output -- so save-here must reject it outright.
        $saveHere = Join-Path $script:Root 'plugins/watch-local/scripts/save-here.ps1'
        $victim = Join-Path $S.Sandbox 'project/jobs/keep'
        New-Item -ItemType Directory -Force -Path $victim | Out-Null
        'precious' | Set-Content -LiteralPath (Join-Path $victim 'data.txt')
        $stdoutFile = New-TemporaryFile; $stderrFile = New-TemporaryFile
        $old = $env:LOCALAPPDATA
        $oldXdg = $env:XDG_DATA_HOME
        try {
            $env:LOCALAPPDATA = $S.AppData
            $env:XDG_DATA_HOME = $S.AppData
            $p = Start-Process -FilePath $script:PSEngine -ArgumentList @(
                '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$saveHere`"",
                '-Slug','"../jobs/keep"','-Cwd',"`"$(Join-Path $S.Sandbox 'project')`"") `
                -RedirectStandardOutput $stdoutFile.FullName `
                -RedirectStandardError $stderrFile.FullName -Wait -NoNewWindow -PassThru
            $p.ExitCode | Should -Be 60
            Test-Path (Join-Path $victim 'data.txt') | Should -BeTrue
        } finally {
            $env:LOCALAPPDATA = $old
            $env:XDG_DATA_HOME = $oldXdg
            Remove-Item $stdoutFile.FullName, $stderrFile.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}
