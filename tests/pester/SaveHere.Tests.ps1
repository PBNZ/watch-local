# save-here promotion tests -- source metadata recovery and truthful
# reporting for local/UNC jobs (issues #4, #12, #20).
#
# Each scenario spawns save-here.ps1 in a sandboxed jobs_root (state root
# redirected via LOCALAPPDATA / XDG_DATA_HOME, mirroring Purge.Tests.ps1)
# with stdin redirected, i.e. the non-interactive agent-driven path.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
    $script:SaveHere = Join-Path $Root 'plugins/watch-local/scripts/save-here.ps1'
    $script:PSEngine = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell.exe' }

    function _NewSandbox {
        $name = 'wl-savehere-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) $name
        $jobs    = Join-Path $sandbox 'jobs'
        $appdata = Join-Path $sandbox 'appdata'
        $cwd     = Join-Path $sandbox 'cwd'
        $configFile = Join-Path $appdata 'watch-local/config.json'
        New-Item -ItemType Directory -Force -Path $jobs, $cwd, (Split-Path $configFile -Parent) | Out-Null
        [pscustomobject]@{ jobs_root = $jobs } | ConvertTo-Json |
            Set-Content -LiteralPath $configFile -Encoding utf8
        return [pscustomobject]@{
            Sandbox  = $sandbox
            JobsRoot = $jobs
            AppData  = $appdata
            Cwd      = $cwd
        }
    }

    # Seed a local-source job: artifacts in the job dir, "source video"
    # outside it, and optionally the job.json watch.ps1 writes.
    function _SeedLocalJob {
        param([pscustomobject]$S, [string]$Slug, [bool]$WriteJobJson = $true)
        $dir = Join-Path $S.JobsRoot $Slug
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        'artifact' | Set-Content -LiteralPath (Join-Path $dir 'report.md')
        $src = Join-Path $S.Sandbox 'source-video.mp4'
        'fake video bytes' | Set-Content -LiteralPath $src
        if ($WriteJobJson) {
            [pscustomobject]@{
                slug          = $Slug
                source        = $src
                is_url        = $false
                original_path = $src
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'job.json') -Encoding utf8
        }
        return $src
    }

    function _RunSaveHere {
        param([pscustomobject]$S, [string[]]$ArgList)
        $stdoutFile = New-TemporaryFile
        $stderrFile = New-TemporaryFile
        $stdinFile  = New-TemporaryFile
        $quoted = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($script:SaveHere)`"")
        foreach ($a in $ArgList) {
            if ($a -match '\s') { $quoted += "`"$a`"" } else { $quoted += $a }
        }
        $oldLocalAppData = $env:LOCALAPPDATA
        $oldXdg = $env:XDG_DATA_HOME
        try {
            $env:LOCALAPPDATA = $S.AppData
            $env:XDG_DATA_HOME = $S.AppData
            $p = Start-Process -FilePath $script:PSEngine -ArgumentList $quoted `
                -RedirectStandardInput  $stdinFile.FullName `
                -RedirectStandardOutput $stdoutFile.FullName `
                -RedirectStandardError  $stderrFile.FullName `
                -Wait -NoNewWindow -PassThru
            $script:_lastCode = $p.ExitCode
            return (Get-Content $stdoutFile.FullName -Raw) + (Get-Content $stderrFile.FullName -Raw)
        } finally {
            $env:LOCALAPPDATA = $oldLocalAppData
            $env:XDG_DATA_HOME = $oldXdg
            Remove-Item -LiteralPath $stdoutFile.FullName, $stderrFile.FullName, $stdinFile.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'save-here concrete-slug source recovery (#4)' {
    BeforeEach { $script:S = _NewSandbox }
    AfterEach  { Remove-Item -LiteralPath $S.Sandbox -Recurse -Force -ErrorAction SilentlyContinue }

    It 'writes source-link.txt for a local job addressed by concrete slug' {
        # watch.ps1 -SaveHere always passes the concrete slug -- this is the
        # primary path, which used to silently skip source-link.txt.
        _SeedLocalJob -S $S -Slug 'aaaa111122223333' | Out-Null
        $out = _RunSaveHere -S $S -ArgList @('-Slug', 'aaaa111122223333', '-Cwd', $S.Cwd)
        $script:_lastCode | Should -Be 0
        $dest = Join-Path $S.Cwd 'watch-local-output/aaaa111122223333'
        Test-Path (Join-Path $dest 'source-link.txt') | Should -BeTrue
        $out | Should -Match 'Source link:.*source-link\.txt'
    }

    It 'copies the source with -IncludeSource on the concrete-slug path' {
        _SeedLocalJob -S $S -Slug 'bbbb111122223333' | Out-Null
        $out = _RunSaveHere -S $S -ArgList @('-Slug', 'bbbb111122223333', '-Cwd', $S.Cwd, '-IncludeSource')
        $script:_lastCode | Should -Be 0
        $dest = Join-Path $S.Cwd 'watch-local-output/bbbb111122223333'
        Test-Path (Join-Path $dest 'source-video.mp4') | Should -BeTrue
        $out | Should -Match 'Source copied:.*yes'
    }

    It 'reports honestly when the source path is unknown' {
        # No job.json, no matching last-job.json: promotion still succeeds
        # but the report must not claim a source-link.txt was written.
        _SeedLocalJob -S $S -Slug 'cccc111122223333' -WriteJobJson $false | Out-Null
        $out = _RunSaveHere -S $S -ArgList @('-Slug', 'cccc111122223333', '-Cwd', $S.Cwd)
        $script:_lastCode | Should -Be 0
        $dest = Join-Path $S.Cwd 'watch-local-output/cccc111122223333'
        Test-Path (Join-Path $dest 'report.md') | Should -BeTrue
        Test-Path (Join-Path $dest 'source-link.txt') | Should -BeFalse
        $out | Should -Match 'Source link:.*not written'
    }
}

Describe 'save-here StrictMode schema tolerance (#12)' {
    BeforeEach { $script:S = _NewSandbox }
    AfterEach  { Remove-Item -LiteralPath $S.Sandbox -Recurse -Force -ErrorAction SilentlyContinue }

    It "promotes 'last' from a pre-is_url last-job.json without crashing" {
        _SeedLocalJob -S $S -Slug 'dddd111122223333' -WriteJobJson $false | Out-Null
        # Old schema: slug only -- no source / is_url / original_path.
        [pscustomobject]@{ slug = 'dddd111122223333' } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $S.AppData 'watch-local/last-job.json') -Encoding utf8
        $out = _RunSaveHere -S $S -ArgList @('-Slug', 'last', '-Cwd', $S.Cwd)
        $script:_lastCode | Should -Be 0
        Test-Path (Join-Path $S.Cwd 'watch-local-output/dddd111122223333/report.md') | Should -BeTrue
    }
}

Describe 'save-here -RemoveCanonical (#20)' {
    BeforeEach { $script:S = _NewSandbox }
    AfterEach  { Remove-Item -LiteralPath $S.Sandbox -Recurse -Force -ErrorAction SilentlyContinue }

    It 'removes the canonical dir without hanging on a non-interactive host' {
        _SeedLocalJob -S $S -Slug 'eeee111122223333' | Out-Null
        $out = _RunSaveHere -S $S -ArgList @('-Slug', 'eeee111122223333', '-Cwd', $S.Cwd, '-RemoveCanonical')
        $script:_lastCode | Should -Be 0
        Test-Path (Join-Path $S.JobsRoot 'eeee111122223333') | Should -BeFalse
        Test-Path (Join-Path $S.Cwd 'watch-local-output/eeee111122223333/report.md') | Should -BeTrue
        $out | Should -Match 'GONE'
    }
}
