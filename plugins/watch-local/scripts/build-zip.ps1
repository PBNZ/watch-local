#requires -Version 5.1
<#
.SYNOPSIS
    Build a distributable zip of the watch-local marketplace.

.DESCRIPTION
    Zips the marketplace root (.claude-plugin/, plugins/, docs/, LICENSE,
    top-level README.md) into dist/watch-local-marketplace-vX.Y.Z.zip.
    Excludes: tests/, dist/, anything that does not belong in the install.

.PARAMETER OutDir
    Where to write the zip. Default: <marketplace>/dist/

.PARAMETER VersionTag
    Override the version label (default: read from marketplace.json).
#>

#region Params
[CmdletBinding()]
param(
    [string]$OutDir,
    [string]$VersionTag
)
#endregion

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\_lib.ps1"

# scripts/   -> plugin root -> plugins/<name>/ -> plugins/ -> marketplace root
$pluginRoot    = Split-Path -Parent $PSScriptRoot
$pluginsDir    = Split-Path -Parent $pluginRoot
$marketRoot    = Split-Path -Parent $pluginsDir

if (-not $OutDir) { $OutDir = Join-Path $marketRoot 'dist' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$marketJsonPath = Join-Path $marketRoot '.claude-plugin\marketplace.json'
if (-not (Test-Path -LiteralPath $marketJsonPath)) {
    Write-Err "marketplace.json not found at $marketJsonPath"
    exit 1
}
if (-not $VersionTag) {
    $mj = Read-UTF8 $marketJsonPath | ConvertFrom-Json
    $VersionTag = [string]$mj.metadata.version
    if (-not $VersionTag) { $VersionTag = '0.0.0-dev' }
}

$zipName = "watch-local-marketplace-$VersionTag.zip"
$zipPath = Join-Path $OutDir $zipName
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

# Build a staging dir to control exact zip contents.
$stage = Join-Path $env:TEMP ("wl-zip-stage-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $stage | Out-Null
try {
    # Top-level includes.
    $includeTop = @(
        '.claude-plugin',
        'plugins',
        'docs',
        'LICENSE',
        'README.md',
        'SECURITY.md'
    )
    foreach ($name in $includeTop) {
        $src = Join-Path $marketRoot $name
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination $stage -Recurse -Force
        }
    }
    # Exclusions inside plugins/watch-local: drop dist/ tests/ __pycache__ etc.
    $excludeGlobs = @('**/__pycache__', '**/.pytest_cache', '**/.git', '**/dist', '**/tests', '**/*.zip')
    foreach ($glob in $excludeGlobs) {
        $matches = Get-ChildItem -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue |
                   Where-Object { $_.FullName -like (Join-Path $stage $glob) }
        foreach ($m in $matches) {
            Remove-Item -LiteralPath $m.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Stage "writing $zipPath"
    # Use .NET ZipArchive directly so entries are written with forward-slash
    # paths. PowerShell 5.1's Compress-Archive writes backslash paths, which
    # the claude.ai plugin uploader rejects ("Zip file contains path with
    # invalid characters"). Spec-compliant zips MUST use forward slashes.
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    $fs  = [System.IO.File]::Create($zipPath)
    $arc = $null
    try {
        $arc = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        Get-ChildItem -LiteralPath $stage -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($stage.Length).TrimStart('\','/').Replace('\','/')
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $arc, $_.FullName, $rel, [System.IO.Compression.CompressionLevel]::Optimal)
        }
    } finally {
        if ($arc) { $arc.Dispose() }
        $fs.Dispose()
    }

    $size = (Get-Item -LiteralPath $zipPath).Length / 1MB
    Write-Output ''
    Write-Output "# watch-local marketplace zip"
    Write-Output ''
    Write-Output "- **Version:** $VersionTag"
    Write-Output ("- **Output:** ``{0}``" -f $zipPath)
    Write-Output ("- **Size:** {0:N1} MB" -f $size)
    Write-Output ''
    Write-Output "Install:"
    Write-Output '```'
    Write-Output "1. Extract this zip into a stable folder, e.g.:"
    Write-Output "     C:\Users\<you>\plugins\watch-local-marketplace\"
    Write-Output ""
    Write-Output "2. In Claude Code:"
    Write-Output "     /plugin marketplace add `"C:\Users\<you>\plugins\watch-local-marketplace`""
    Write-Output "     /plugin install watch-local@watch-local"
    Write-Output ""
    Write-Output "3. Restart Claude Code so the SessionStart hook fires."
    Write-Output ""
    Write-Output "4. Run:  /watch-setup"
    Write-Output "5. Then: /watch <url-or-path> [question]"
    Write-Output '```'
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

exit 0
