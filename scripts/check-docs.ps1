#!/usr/bin/env pwsh
#Requires -Version 7.0
# check-docs.ps1 - living-docs consistency check (RepoKit living-docs add-on).
#
# Default mode: verify, exit 1 on any problem. -Update: rewrite every state block in
# README.md + docs/**/*.md from docs/STATE.json, then verify the rest.
#
# Checks:
#   1. Every state block matches what docs/STATE.json renders, and references known keys.
#   2. No fact's as_of is in the future or older than its stale_after_days (0 = never stale).
#   3. docs/RUNBOOK.md carries no superseded-content markers - old content must be deleted.
#   4. Every markdown table separator row starts and ends with a pipe (doc-style rule).
#
# Only check 1 is auto-fixable (-Update); the others always need a human edit.

[CmdletBinding()]
param(
    [switch]$Update,
    [string]$Root
)

$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = (Resolve-Path -Path $Root).Path

$problems = [System.Collections.Generic.List[string]]::new()

# --- Load STATE.json ---------------------------------------------------------

$statePath = Join-Path $Root 'docs/STATE.json'
if (-not (Test-Path $statePath)) {
    Write-Host "check-docs: ERROR - docs/STATE.json not found under $Root"
    exit 1
}
try {
    $state = Get-Content -Path $statePath -Raw | ConvertFrom-Json -AsHashtable
} catch {
    Write-Host "check-docs: ERROR - docs/STATE.json is not valid JSON: $($_.Exception.Message)"
    exit 1
}
$facts = $state['facts']
if ($null -eq $facts -or $facts.Count -eq 0) {
    Write-Host "check-docs: ERROR - docs/STATE.json has no 'facts' object."
    exit 1
}

# --- Rendering ---------------------------------------------------------------

function Get-FactLabel([string]$Key, $Fact) {
    if ($Fact['note']) { return ([string]$Fact['note']).Replace('|', '\|') }
    return $Key
}

function Format-TableBlock([string[]]$Keys) {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('| Fact | Value | As of |')
    $lines.Add('|---|---|---|')
    foreach ($k in $Keys) {
        $f = $facts[$k]
        $value = ([string]$f['value']).Replace('|', '\|')
        $lines.Add("| $(Get-FactLabel $k $f) | $value | $($f['as_of']) |")
    }
    return $lines.ToArray()
}

function Format-InlineBlock([string]$Key) {
    $f = $facts[$Key]
    return @("$([string]$f['value']) (as of $($f['as_of']))")
}

# --- Check 2: fact validity + staleness ---------------------------------------

$today = (Get-Date).Date
$defaultStale = 14
if ($null -ne $state['stale_after_days']) { $defaultStale = [int]$state['stale_after_days'] }

foreach ($key in @($facts.Keys)) {
    $fact = $facts[$key]
    if ($null -eq $fact['value'] -or -not $fact['as_of']) {
        $problems.Add("STATE.json: fact '$key' must have 'value' and 'as_of'.")
        continue
    }
    $asOf = [datetime]::MinValue
    $ok = [datetime]::TryParseExact([string]$fact['as_of'], 'yyyy-MM-dd',
        [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$asOf)
    if (-not $ok) {
        $problems.Add("STATE.json: fact '$key' has invalid as_of '$($fact['as_of'])' - use YYYY-MM-DD.")
        continue
    }
    if ($asOf.Date -gt $today) {
        $problems.Add("STATE.json: fact '$key' has a future as_of ($($fact['as_of'])).")
        continue
    }
    $limit = $defaultStale
    if ($null -ne $fact['stale_after_days']) { $limit = [int]$fact['stale_after_days'] }
    if ($limit -gt 0) {
        $age = ($today - $asOf.Date).Days
        if ($age -gt $limit) {
            $problems.Add("STATE.json: fact '$key' is stale - as_of $($fact['as_of']) is $age days old (limit $limit). Re-confirm the value and update as_of.")
        }
    }
}

# --- Checks 1 + 4: state blocks and table separators over the managed files ---

$docFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
$readmePath = Join-Path $Root 'README.md'
if (Test-Path $readmePath) { $docFiles.Add((Get-Item $readmePath)) }
$docsDir = Join-Path $Root 'docs'
if (Test-Path $docsDir) {
    foreach ($f in (Get-ChildItem -Path $docsDir -Recurse -Filter '*.md' -File)) { $docFiles.Add($f) }
}

foreach ($file in $docFiles) {
    $rel = [System.IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
    $raw = Get-Content -Path $file.FullName -Raw
    if ($null -eq $raw) { $raw = '' }
    $eol = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $hadTrailingNewline = $raw.EndsWith("`n")
    $lines = @($raw -split "`r?`n")
    if ($hadTrailingNewline -and $lines.Count -gt 0 -and $lines[-1] -eq '') {
        $lines = $lines[0..($lines.Count - 2)]
    }

    $out = [System.Collections.Generic.List[string]]::new()
    $fileChanged = $false
    $i = 0
    while ($i -lt $lines.Count) {
        $line = $lines[$i]

        # Check 4: table separator rows must start and end with a pipe.
        $trimmed = $line.Trim()
        if ($trimmed -match '^[|:\- ]+$' -and $trimmed.Contains('-') -and $trimmed.Contains('|')) {
            if (-not ($trimmed.StartsWith('|') -and $trimmed.EndsWith('|'))) {
                $problems.Add("${rel}:$($i + 1): table separator row must start and end with '|' (doc-style).")
            }
        }

        $m = [regex]::Match($line, '^<!-- state:begin (keys|key)=(\S+) -->\s*$')
        if (-not $m.Success) {
            $out.Add($line)
            $i++
            continue
        }

        # Find the matching end marker.
        $end = -1
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            if ($lines[$j] -match '^<!-- state:end -->\s*$') { $end = $j; break }
            if ($lines[$j] -match '^<!-- state:begin ') { break }
        }
        if ($end -lt 0) {
            $problems.Add("${rel}:$($i + 1): state:begin has no matching state:end marker.")
            $out.Add($line)
            $i++
            continue
        }

        $kind = $m.Groups[1].Value
        $keys = @($m.Groups[2].Value -split ',' | Where-Object { $_ })
        $blockOk = $true
        if ($kind -eq 'key' -and $keys.Count -ne 1) {
            $problems.Add("${rel}:$($i + 1): 'key=' takes exactly one key - use 'keys=' for several.")
            $blockOk = $false
        }
        $unknown = @($keys | Where-Object { -not $facts.ContainsKey($_) })
        if ($unknown.Count -gt 0) {
            $problems.Add("${rel}:$($i + 1): unknown fact key(s): $($unknown -join ', ') - add them to docs/STATE.json or fix the block.")
            $blockOk = $false
        }

        if (-not $blockOk) {
            for ($j = $i; $j -le $end; $j++) { $out.Add($lines[$j]) }
            $i = $end + 1
            continue
        }

        $expected = if ($kind -eq 'keys') { @(Format-TableBlock $keys) } else { @(Format-InlineBlock $keys[0]) }
        $actual = if ($end -gt $i + 1) { @($lines[($i + 1)..($end - 1)]) } else { @() }
        $isSame = ($actual.Count -eq $expected.Count)
        if ($isSame) {
            for ($j = 0; $j -lt $expected.Count; $j++) {
                if ($actual[$j] -cne $expected[$j]) { $isSame = $false; break }
            }
        }

        $out.Add($line)
        if ($isSame) {
            foreach ($l in $actual) { $out.Add($l) }
        } elseif ($Update) {
            foreach ($l in $expected) { $out.Add($l) }
            $fileChanged = $true
        } else {
            foreach ($l in $actual) { $out.Add($l) }
            $problems.Add("${rel}:$($i + 1): state block is out of date with docs/STATE.json - run 'pwsh scripts/check-docs.ps1 -Update'.")
        }
        $out.Add($lines[$end])
        $i = $end + 1
    }

    if ($Update -and $fileChanged) {
        $newRaw = $out -join $eol
        if ($hadTrailingNewline) { $newRaw += $eol }
        Set-Content -Path $file.FullName -Value $newRaw -NoNewline
        Write-Host "check-docs: updated state block(s) in $rel"
    }
}

# --- Check 3: superseded-content markers in the runbook ------------------------

$runbookPath = Join-Path $Root 'docs/RUNBOOK.md'
if (Test-Path $runbookPath) {
    $hits = Select-String -Path $runbookPath -Pattern '(?i)\b(superseded|obsolete|no longer current)\b'
    foreach ($h in $hits) {
        $problems.Add("docs/RUNBOOK.md:$($h.LineNumber): superseded-content marker '$($h.Matches[0].Value)' - the runbook is current-state-only; delete replaced content (git keeps history).")
    }
}

# --- Result --------------------------------------------------------------------

if ($problems.Count -gt 0) {
    Write-Host ''
    Write-Host "check-docs: FAILED - $($problems.Count) problem(s):"
    foreach ($p in $problems) { Write-Host "  - $p" }
    exit 1
}
Write-Host 'check-docs: all checks passed.'
exit 0
