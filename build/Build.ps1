#Requires -Version 5.1
<#
.SYNOPSIS
    Builds dist/install.ps1 from src/.

.DESCRIPTION
    The distributed installer must work when piped to Invoke-Expression, which rules
    out companion files and makes $PSScriptRoot unavailable. So the payload scripts are
    embedded into the installer as base64.

    Base64 is not a stylistic choice here: PowerShell ends a here-string at the first
    line beginning with the closing marker, and the payload scripts legitimately contain
    such lines (the repair script has five "'@" lines). Pasting the payload in verbatim
    produces a file that does not parse. Base64 cannot contain a line starting with the
    terminator, so it round-trips safely.

    Placeholders are substituted in two passes so that literal '$$' sequences in the
    payload text survive .NET's replacement-string processing intact.

.EXAMPLE
    .\build\Build.ps1

.EXAMPLE
    .\build\Build.ps1 -Version 1.1.0
#>
[CmdletBinding()]
param(
    [string]$Version = '1.0.0',
    [string]$InstallUrl = 'https://raw.githubusercontent.com/maxbarnas/pwsh-profile-perf/main/dist/install.ps1',
    [switch]$NoValidate
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $root 'src'
$payloadDir = Join-Path $srcDir 'payload'
$distDir = Join-Path $root 'dist'

function ConvertTo-Base64 {
    param([string]$Text)
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}

function Read-Source {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Source file not found: $Path"
    }
    Get-Content -LiteralPath $Path -Raw
}

Write-Host ''
Write-Host 'Building install.ps1' -ForegroundColor Cyan
Write-Host "  version : $Version"
Write-Host "  install : $InstallUrl"

# --- read sources -----------------------------------------------------------

$repairText = Read-Source (Join-Path $payloadDir 'Repair-ProfilePerf.ps1')
$guardText = Read-Source (Join-Path $payloadDir 'Guard.ps1')
$uninstallerText = Read-Source (Join-Path $srcDir 'uninstaller.body.ps1')
$body = Read-Source (Join-Path $srcDir 'installer.body.ps1')

# Normalise to LF before embedding. Without this the embedded text depends on how the
# source files happen to be saved, and payload files are written back out as LF.
function ConvertTo-Lf { param([string]$T) $T.Replace("`r`n", "`n") }
$repairText = ConvertTo-Lf $repairText
$guardText = ConvertTo-Lf $guardText
$uninstallerText = ConvertTo-Lf $uninstallerText
$body = ConvertTo-Lf $body

foreach ($pair in @(
        @{ Name = 'repair';      Text = $repairText },
        @{ Name = 'guard';       Text = $guardText },
        @{ Name = 'uninstaller'; Text = $uninstallerText }
    )) {
    Write-Host ("  payload {0,-12} {1,7} bytes" -f $pair.Name, $pair.Text.Length)
}

# --- guard sanity: payloads must not smuggle a here-string terminator ------

foreach ($pair in @(
        @{ Name = 'repair';      Text = $repairText },
        @{ Name = 'guard';       Text = $guardText },
        @{ Name = 'uninstaller'; Text = $uninstallerText }
    )) {
    $hasTerminator = [regex]::IsMatch($pair.Text, "(?m)^'@|^`"@")
    if ($hasTerminator) {
        Write-Host ("  note: payload '{0}' contains here-string terminators; base64 embedding handles this." -f $pair.Name) -ForegroundColor DarkGray
    }
}

# --- substitute -------------------------------------------------------------

# Two passes, so a literal '$$' (or '$1') in payload text is not interpreted as a
# .NET replacement token. Pass 1 swaps the payloads for inert tokens; their text is
# never seen by the .NET replacement engine.
$tokenRepair = '<<<TOKEN_REPAIR>>>'
$tokenGuard = '<<<TOKEN_GUARD>>>'
$tokenUninstaller = '<<<TOKEN_UNINSTALLER>>>'

$out = $body

# Pass 1: replace payload placeholders with inert tokens.
$out = $out.Replace('@@PAYLOAD_REPAIR_B64@@', $tokenRepair)
$out = $out.Replace('@@PAYLOAD_GUARD_B64@@', $tokenGuard)
$out = $out.Replace('@@PAYLOAD_UNINSTALLER_B64@@', $tokenUninstaller)

# Pass 2: simple string values.
$out = $out.Replace('@@VERSION@@', $Version)
$out = $out.Replace('@@INSTALL_URL@@', $InstallUrl)

# Pass 3: swap tokens for base64. Done with .Replace, which treats the replacement as
# a literal, so no escaping concerns remain.
$out = $out.Replace($tokenRepair, (ConvertTo-Base64 $repairText))
$out = $out.Replace($tokenGuard, (ConvertTo-Base64 $guardText))
$out = $out.Replace($tokenUninstaller, (ConvertTo-Base64 $uninstallerText))

if ($out -match '@@(VERSION|INSTALL_URL|PAYLOAD_[A-Z_]+)@@') {
    $left = [regex]::Matches($out, '@@[A-Z_]+@@') | ForEach-Object { $_.Value } | Select-Object -Unique
    throw "unsubstituted build-time placeholder(s) remain: $($left -join ', ')"
}

# @@INSTALL_DIR@@ / @@PROFILE_PATH@@ / @@ALLHOSTS_PATH@@ are runtime placeholders and
# are meant to survive the build: the installer resolves them at install time from the
# chosen -InstallDir and profile paths, then bakes them into the files it writes.

# --- validate ---------------------------------------------------------------

if (-not $NoValidate) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($out, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        Write-Host '  BUILD FAILED: generated script has syntax errors' -ForegroundColor Red
        foreach ($e in $errors) {
            Write-Host ("    line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red
        }
        throw 'generated install.ps1 does not parse'
    }
    Write-Host '  generated script parses cleanly' -ForegroundColor Green
}

# --- write ------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $distDir)) {
    New-Item -ItemType Directory -Path $distDir -Force | Out-Null
}

$outFile = Join-Path $distDir 'install.ps1'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($outFile, $out, $utf8NoBom)

Write-Host ''
Write-Host "Wrote $outFile ($((Get-Item -LiteralPath $outFile).Length) bytes)" -ForegroundColor Green
Write-Host ''
