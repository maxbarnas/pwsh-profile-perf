#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstalls the Profile startup-performance fixes.

.DESCRIPTION
    Reverts the main profile to the stock code, removes the startup reminder from the
    AllHosts profile, and deletes the install directory.

    This file is written by Install-ProfilePerf.ps1 with the resolved paths already
    baked in, so it needs no arguments and no network access.

.EXAMPLE
    .\Uninstall-ProfilePerf.ps1
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    # Keep the installed payload scripts on disk, reverting only the profiles.
    [switch]$KeepFiles
)

$ErrorActionPreference = 'Stop'

$InstallDir  = '@@INSTALL_DIR@@'
$ProfilePath = '@@PROFILE_PATH@@'
$AllHostsPath = '@@ALLHOSTS_PATH@@'

function Get-Eol {
    param([string]$Text)
    $crlf = ([regex]::Matches($Text, "`r`n")).Count
    $lf = ([regex]::Matches($Text, "(?<!`r)`n")).Count
    if ($crlf -gt $lf) { "`r`n" } else { "`n" }
}

function Write-TextFileLf {
    param([string]$Path, [string]$Text, [string]$Eol = "`n")
    $out = if ($Eol -eq "`r`n") { $Text.Replace("`n", "`r`n") } else { $Text }
    [System.IO.File]::WriteAllText($Path, $out, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-GuardSpan {
    <#
    .SYNOPSIS
        Locates the guard block, including an adjacent decorative banner line.
    #>
    param([string]$Text)

    $beginIdx = $Text.IndexOf('# >>> LKS-PERF-GUARD-BEGIN', [StringComparison]::Ordinal)
    if ($beginIdx -lt 0) { return $null }
    $endIdx = $Text.IndexOf('# <<< LKS-PERF-GUARD-END', $beginIdx, [StringComparison]::Ordinal)
    if ($endIdx -lt 0) { return $null }

    $start = $Text.LastIndexOf("`n", [Math]::Max(0, $beginIdx - 1))
    $start = if ($start -lt 0) { 0 } else { $start + 1 }
    $endLine = $Text.IndexOf("`n", $endIdx)
    $end = if ($endLine -lt 0) { $Text.Length } else { $endLine + 1 }

    $bannerRe = [regex]'^#\s*=+\s*$'
    $lines = $Text.Substring(0, $start) -split "`n"
    $backLines = 0
    for ($i = $lines.Count - 2; $i -ge 0; $i--) {
        if ($bannerRe.IsMatch($lines[$i])) { $backLines++ } else { break }
    }
    if ($backLines -gt 0) {
        $keep = $lines.Count - 1 - $backLines
        $start = ($lines[0..([Math]::Max(0, $keep - 1))] -join "`n").Length
        if ($keep -gt 0) { $start += 1 }
    }

    $fwd = $Text.Substring($end) -split "`n"
    $fwdLines = 0
    foreach ($l in $fwd) { if ($bannerRe.IsMatch($l)) { $fwdLines++ } else { break } }
    if ($fwdLines -gt 0) {
        $consumed = ($fwd[0..($fwdLines - 1)] -join "`n")
        $end = $end + $consumed.Length
        if ($end -lt $Text.Length -and $Text[$end] -eq "`n") { $end++ }
    }

    [pscustomobject]@{ Start = $start; End = $end }
}

Write-Host ''
Write-Host 'Uninstalling profile startup-performance fixes' -ForegroundColor Cyan

if (-not $PSCmdlet.ShouldProcess($ProfilePath, 'Revert profile fixes')) { return }

# 1. Revert the profile regions, using the installed repair script when available.
$repairFile = Join-Path $InstallDir 'Repair-ProfilePerf.ps1'
$shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }

if (Test-Path -LiteralPath $repairFile -PathType Leaf) {
    Write-Host ''
    Write-Host 'Profile regions:' -ForegroundColor Cyan
    & $shell -NoProfile -ExecutionPolicy Bypass -File $repairFile -ProfilePath $ProfilePath -Uninstall -Confirm:$false
} else {
    Write-Host ''
    Write-Host "Repair script not found at $repairFile" -ForegroundColor Yellow
    Write-Host 'Remove the LKS-PERF regions from the profile by hand, or restore a .bak-* copy.' -ForegroundColor Yellow
}

# 2. Remove the startup reminder from the AllHosts profile.
Write-Host ''
Write-Host 'Startup reminder:' -ForegroundColor Cyan
if (Test-Path -LiteralPath $AllHostsPath -PathType Leaf) {
    $text = Get-Content -LiteralPath $AllHostsPath -Raw
    $span = Get-GuardSpan -Text $text
    if ($span) {
        $new = $text.Remove($span.Start, $span.End - $span.Start)
        if ($new.Trim().Length -eq 0) {
            $new = ''
        } else {
            $new = $new.TrimEnd("`n", "`r") + (Get-Eol $text)
        }
        Write-TextFileLf -Path $AllHostsPath -Text $new -Eol (Get-Eol $text)
        Write-Host "  removed from $(Split-Path -Leaf $AllHostsPath)" -ForegroundColor Green
    } else {
        Write-Host '  not present' -ForegroundColor DarkGray
    }
} else {
    Write-Host '  no AllHosts profile' -ForegroundColor DarkGray
}

# 3. Remove the install directory, unless asked to keep the files.
if (-not $KeepFiles) {
    Write-Host ''
    Write-Host 'Installed files:' -ForegroundColor Cyan
    if (Test-Path -LiteralPath $InstallDir) {
        # Delete the contents rather than the directory itself, because this script is
        # running from inside it. The directory is removed at the very end.
        Get-ChildItem -LiteralPath $InstallDir -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne (Split-Path -Leaf $PSCommandPath) } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $InstallDir) {
            Write-Host "  could not fully remove $InstallDir" -ForegroundColor Yellow
        } else {
            Write-Host "  removed $InstallDir" -ForegroundColor Green
        }
    } else {
        Write-Host '  install directory already gone' -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host 'Uninstalled. Restart the shell to use the stock profile.' -ForegroundColor Green
Write-Host ''
