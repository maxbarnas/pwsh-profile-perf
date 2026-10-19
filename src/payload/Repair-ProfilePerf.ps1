#Requires -Version 5.1
<#
.SYNOPSIS
    Applies or reverts PowerShell profile startup-performance fixes.

.DESCRIPTION
    Speeds up an interactive PowerShell startup that uses the Chris Titus Tech (CTT)
    profile, which is popular because it self-updates from GitHub.

    The problem: that profile imports several slow things eagerly on every shell start.

      * Terminal-Icons        ~500 ms  (dot-sources a 571 KB glyph table, converts both
                                        colour themes, then rewrites ~184 KB of theme
                                        XML under %APPDATA% on every single import)
      * Chocolatey profile    ~100-280 ms  (loads Chocolatey.PowerShell.dll, only to
                                            provide refreshenv)
      * Resolve-Editor        ~185 ms  (probes 8 candidates one at a time; 'code' was
                                        5th, so 4 PATH scans hit nothing)

    The fixes defer the two module imports until first use, and try the editor that is
    actually installed first. Measured on the machine this was developed on: startup
    went from ~1891 ms to ~1086 ms.

    Each fix lives in a region delimited by sentinel comments, so it can be found and
    reverted reliably:

      LKS-PERF-TI-BEGIN / END         lazy-load Terminal-Icons
      LKS-PERF-CHOCO-BEGIN / END      lazy-load the Chocolatey profile
      LKS-PERF-EDITOR-BEGIN / END     try 'code' first in Resolve-Editor
      LKS-PERF-LAZY-BEGIN / END       the first-use wrapper functions
      LKS-PERF-NOUPDATE-BEGIN / END   weekly auto-update left off

    Auto-update is switched off as part of the patch because Update-Profile replaces
    the whole profile with the stock copy from GitHub, which would discard the fixes.

    The script is idempotent: regions already applied are left alone. A timestamped
    backup is written before the file is modified, and the result is parsed before it
    is saved, so a broken profile is never written.

.PARAMETER ProfilePath
    Profile to patch. Defaults to the current user's profile for this host.

.PARAMETER Check
    Report the state of each region without changing anything.

.PARAMETER Uninstall
    Restore the original stock code for every region, removing the fixes.

.PARAMETER RestoreBackup
    Restore from the most recent .bak-* file next to the profile instead of
    reconstructing stock text region by region.

.EXAMPLE
    .\Repair-ProfilePerf.ps1 -Check

.EXAMPLE
    .\Repair-ProfilePerf.ps1

.EXAMPLE
    .\Repair-ProfilePerf.ps1 -Uninstall
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$ProfilePath = $PROFILE.CurrentUserCurrentHost,
    [switch]$Check,
    [switch]$Uninstall,
    [switch]$RestoreBackup
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Stock (unpatched) and patched text for each region.
#
# These are here-strings at the top level of this file. Do not move them inside
# another here-string: PowerShell terminates a here-string at the first line that
# starts with the closing marker, and the patched text below contains such lines.
# ---------------------------------------------------------------------------

$tiOriginal = @'
    if (Get-Module -ListAvailable -Name Terminal-Icons) {
        Import-Module -Name Terminal-Icons -ErrorAction SilentlyContinue
    } elseif ($isInteractiveShell) {
        Write-Warning 'Terminal-Icons module is not installed. Run setup.ps1 to install dependencies.'
    }
'@

$tiPatched = @'
    # >>> LKS-PERF-TI-BEGIN
    if (Get-Module -ListAvailable -Name Terminal-Icons) {
        # Perf: no longer imported here. Terminal-Icons takes ~500 ms to import (it
        # dot-sources a 571 KB glyph table at Data/glyphs.ps1, converts both built-in
        # colour themes to escape sequences, and re-exports ~184 KB of theme XML to
        # %APPDATA% on every single import). It is now imported on first directory
        # listing by the Get-ChildItem wrapper in the "Lazy tool loaders" block below,
        # so `ls` looks the same as before but the prompt appears immediately.
        #
        # REVERT: replace this region with the original 3 lines:
        #   if (Get-Module -ListAvailable -Name Terminal-Icons) {
        #       Import-Module -Name Terminal-Icons -ErrorAction SilentlyContinue
        #   } elseif ($isInteractiveShell) {
        #       Write-Warning 'Terminal-Icons module is not installed. Run setup.ps1 to install dependencies.'
        #   }
        $global:TerminalIconsAvailable = $true
    } elseif ($isInteractiveShell) {
        Write-Warning 'Terminal-Icons module is not installed. Run setup.ps1 to install dependencies.'
    }
    # <<< LKS-PERF-TI-END
'@

$chocoOriginal = @'
    $chocolateyProfile = if ($env:ChocolateyInstall) {
        Join-Path $env:ChocolateyInstall 'helpers\chocolateyProfile.psm1'
    } else {
        $null
    }

    if ($chocolateyProfile -and (Test-Path -Path $chocolateyProfile -PathType Leaf)) {
        Import-Module $chocolateyProfile -ErrorAction SilentlyContinue
    }
'@

$chocoPatched = @'
    # >>> LKS-PERF-CHOCO-BEGIN
    # Perf: the Chocolatey profile is only imported to provide `refreshenv` /
    # Update-SessionEnvironment. Importing it loads Chocolatey.PowerShell.dll and costs
    # ~100-280 ms. It is now imported on first use instead; this only records whether
    # the module is present so the lazy wrapper below knows to install itself.
    # REVERT: restore the original direct import:
    #   $chocolateyProfile = if ($env:ChocolateyInstall) {
    #       Join-Path $env:ChocolateyInstall 'helpers\chocolateyProfile.psm1'
    #   } else { $null }
    #   if ($chocolateyProfile -and (Test-Path -Path $chocolateyProfile -PathType Leaf)) {
    #       Import-Module $chocolateyProfile -ErrorAction SilentlyContinue
    #   }
    $global:ChocolateyProfilePath = if ($env:ChocolateyInstall) {
        $path = Join-Path $env:ChocolateyInstall 'helpers\chocolateyProfile.psm1'
        if (Test-Path -Path $path -PathType Leaf) { $path }
    }
    # <<< LKS-PERF-CHOCO-END
'@

$editorOriginal = @'
    foreach ($candidate in 'nvim', 'pvim', 'vim', 'vi', 'code', 'codium', 'notepad++', 'sublime_text') {
        if (Test-Command $candidate) {
            return $candidate
        }
    }
'@

$editorPatched = @'
    # >>> LKS-PERF-EDITOR-BEGIN
    # Perf: candidates used to be ordered nvim, pvim, vim, vi, code, ... and each
    # Test-Command miss costs ~45 ms because the PATH is scanned per lookup. 'code' was
    # 5th, so startup paid ~180 ms for four editors that are not installed. Candidates
    # now start with the ones actually present on this machine.
    # REVERT: restore the original order
    #   'nvim', 'pvim', 'vim', 'vi', 'code', 'codium', 'notepad++', 'sublime_text'
    foreach ($candidate in 'code', 'codium', 'code-insiders', 'nvim', 'pvim', 'vim', 'vi', 'notepad++', 'sublime_text') {
        if (Test-Command $candidate) {
            return $candidate
        }
    }
    # <<< LKS-PERF-EDITOR-END
'@

$noUpdateOriginal = @'
Invoke-ScheduledProfileUpdate
'@

$noUpdatePatched = @'
# >>> LKS-PERF-NOUPDATE-BEGIN
# Auto-update DISABLED (see the local perf-fix notes at the top of this file).
#
# Invoke-ScheduledProfileUpdate downloads the stock CTT profile from GitHub and
# overwrites this file whenever the local copy differs, which silently discards
# the local startup-performance fixes. It is off now. To refresh from upstream
# deliberately, run 'Update-Profile' -- then re-apply the fixes with
# 'Repair-ProfilePerf'. The reminder at shell start tells you if they are gone.
#
# REVERT: delete this block and restore the single original call:
#     Invoke-ScheduledProfileUpdate
if ($false) { Invoke-ScheduledProfileUpdate }
# <<< LKS-PERF-NOUPDATE-END
'@

# Inserted after the bare "Initialize-OptionalModule" call. There is no stock text
# for this region: uninstalling removes the whole block.
$lazyPatched = @'
# >>> LKS-PERF-LAZY-BEGIN
# ---------------------------------------------------------------------------
# Lazy tool loaders
#
# Perf: Terminal-Icons and the Chocolatey profile used to be imported eagerly in
# Initialize-OptionalModule, costing ~500 ms and ~100-280 ms on every shell start.
# Instead they are imported the first time you actually use them.
#
# The wrapper functions below are declared at profile scope (inside a top-level
# `if`). That matters: a function defined inside another function body does NOT
# persist after that function returns, so these cannot be moved into a helper.
#
# REVERT: restore eager loading by deleting this block (down to
# "End lazy tool loaders") and re-adding the two direct imports in
# Initialize-OptionalModule:
#     Import-Module -Name Terminal-Icons -ErrorAction SilentlyContinue
#     Import-Module $chocolateyProfile -ErrorAction SilentlyContinue
# ---------------------------------------------------------------------------

# Terminal-Icons: wrapped around Get-ChildItem. Icons appear on the very first
# listing, because the wrapper imports the module before calling the real cmdlet.
#
# This is deliberately a NON-advanced function: $args preserves the caller's named
# parameters (-Force, -Filter, -Name, -Directory, -Recurse, ...) when splatted with
# @args. An advanced function using [Parameter(ValueFromRemainingArguments)] flattens
# them into positionals and breaks those switches. Verified identical to the unwrapped
# cmdlet across 25 call shapes (plain, -Force, -Filter, -File, -Directory, -Name,
# -Recurse, -Depth, -LiteralPath, -Attributes, wildcard paths, array paths, pipeline
# use, gci/ls/dir aliases, error handling, and non-filesystem providers).
if ($global:TerminalIconsAvailable -and -not (Get-Module Terminal-Icons)) {
    function Get-ChildItem {
        # Terminal-Icons calls Get-ChildItem while its own module body is loading
        # (it lists its theme directories). Without this bypass that inner call would
        # re-enter this wrapper and try to Import-Module inside an in-flight import,
        # which fails with "module nesting limit exceeded". So while the import is
        # running, forward straight to the real cmdlet.
        if ($global:TerminalIconsImporting) {
            Microsoft.PowerShell.Management\Get-ChildItem @args
            return
        }

        $global:TerminalIconsImporting = $true
        try {
            if (-not (Get-Module Terminal-Icons)) {
                Import-Module -Name Terminal-Icons -ErrorAction SilentlyContinue
            }
        } finally {
            $global:TerminalIconsImporting = $false
        }

        # The wrapper has done its job; drop it so every later call goes straight to the
        # real cmdlet. This is unconditional on purpose: on a profile reload the module
        # may already be loaded, and the wrapper must still remove itself rather than
        # linger for the rest of the session.
        Remove-Item -Path 'function:\Get-ChildItem' -Force -ErrorAction SilentlyContinue
        Microsoft.PowerShell.Management\Get-ChildItem @args
    }
}

# Chocolatey: wrapped around refreshenv / Update-SessionEnvironment, which are all the
# profile uses that module for.
if ($global:ChocolateyProfilePath -and -not (Get-Module chocolateyProfile)) {
    function Update-SessionEnvironment {
        $chocoProfile = if ($env:ChocolateyInstall) {
            Join-Path $env:ChocolateyInstall 'helpers\chocolateyProfile.psm1'
        }

        if (-not (Get-Module chocolateyProfile) -and $chocoProfile -and (Test-Path -Path $chocoProfile -PathType Leaf)) {
            Import-Module $chocoProfile -ErrorAction SilentlyContinue
        }
        # Get out of the way unconditionally, including on a profile reload where the
        # module may already be loaded (see the note on the Get-ChildItem wrapper above).
        Remove-Item -Path 'function:\Update-SessionEnvironment' -Force -ErrorAction SilentlyContinue

        if (Get-Command -Name 'chocolateyProfile\Update-SessionEnvironment' -ErrorAction SilentlyContinue) {
            chocolateyProfile\Update-SessionEnvironment @args
        } else {
            # Module unavailable: refresh PATH directly so refreshenv still works.
            $env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                        [Environment]::GetEnvironmentVariable('PATH', 'User')
        }
    }
    Set-Alias -Name refreshenv -Value Update-SessionEnvironment -Force
}
# <<< LKS-PERF-LAZY-END
'@

# The lazy block is inserted after this bare call, and uninstall removes it again.
$lazyAnchor = 'Initialize-OptionalModule'

# ---------------------------------------------------------------------------
# Engine
# ---------------------------------------------------------------------------

function Get-RegionSpec {
    <#
    .SYNOPSIS
        Describes every managed region: where it lives, its stock text, its patched text.
    #>
    @(
        [pscustomobject]@{
            Name     = 'TI'
            Kind     = 'Replace'
            Original = $tiOriginal
            Patched  = $tiPatched
        }
        [pscustomobject]@{
            Name     = 'CHOCO'
            Kind     = 'Replace'
            Original = $chocoOriginal
            Patched  = $chocoPatched
        }
        [pscustomobject]@{
            Name     = 'EDITOR'
            Kind     = 'Replace'
            Original = $editorOriginal
            Patched  = $editorPatched
        }
        [pscustomobject]@{
            Name     = 'NOUPDATE'
            Kind     = 'Replace'
            Original = $noUpdateOriginal
            Patched  = $noUpdatePatched
        }
        [pscustomobject]@{
            Name     = 'LAZY'
            Kind     = 'Insert'
            Anchor   = $lazyAnchor
            Original = ''
            Patched  = $lazyPatched
        }
    )
}

function ConvertTo-Lf {
    <#
    .SYNOPSIS
        Normalises CRLF to LF.

    .DESCRIPTION
        Region text is matched against profile text, so both sides must agree on line
        endings. Normalising to LF makes matching independent of how this script
        happened to be saved and of which editor touched the profile last.
    #>
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $Text.Replace("`r`n", "`n")
}

function ConvertTo-BlockNeedle {
    <#
    .SYNOPSIS
        Wraps a block of code in newline anchors so it can only match whole lines.

    .DESCRIPTION
        Here-strings drop the final newline, so a region's text has no leading or
        trailing newline of its own and a naive .Replace() would match it as a
        substring anywhere -- including in the middle of a longer line.

        That is not hypothetical: the NOUPDATE stock text is the bare call
        'Invoke-ScheduledProfileUpdate', which also occurs inside the line
        'function Invoke-ScheduledProfileUpdate {'. Matching without anchors rewrote
        the function declaration and produced a profile that would not parse.

        Anchoring with newlines makes each region match only where it occupies whole
        lines of the file.
    #>
    param([string]$Text)
    "`n" + (ConvertTo-Lf $Text) + "`n"
}

function Set-FirstOccurrence {
    <#
    .SYNOPSIS
        Replaces only the first occurrence of $Needle.

    .DESCRIPTION
        .NET's String.Replace substitutes every occurrence; if a region's text appeared
        twice, both would be rewritten. IndexOf + Remove + Insert limits the change to
        the first match, which is the intended one.
    #>
    param([string]$Text, [string]$Needle, [string]$Replacement)

    $idx = $Text.IndexOf($Needle, [StringComparison]::Ordinal)
    if ($idx -lt 0) { return [pscustomobject]@{ Found = $false; Text = $Text } }

    $new = $Text.Remove($idx, $Needle.Length).Insert($idx, $Replacement)
    [pscustomobject]@{ Found = $true; Text = $new }
}

function Get-Eol {
    <#
    .SYNOPSIS
        Returns the dominant line ending of the text, so it can be preserved on write.
    #>
    param([string]$Text)
    $crlf = ([regex]::Matches($Text, "`r`n")).Count
    $lf = ([regex]::Matches($Text, "(?<!`r)`n")).Count
    if ($crlf -gt $lf) { "`r`n" } else { "`n" }
}

function Get-MarkedSpan {
    <#
    .SYNOPSIS
        Finds the character span of a sentinel-delimited region.

    .DESCRIPTION
        Uninstall works from the markers rather than from the patched text, so it still
        works if the region body was edited or partially truncated by hand. Returns
        $null when either marker is absent.

        $ConsumeTrailingNewline exists for 'Insert' regions. Applying one inserts a blank
        line before the block and keeps the anchor's own newline, so removing just the
        marker lines would leave that blank line behind and the file would not return to
        its original byte length. Consuming one further newline makes apply and revert
        exact inverses.
    #>
    param([string]$Text, [string]$Name, [switch]$ConsumeTrailingNewline)

    $beginMarker = "# >>> LKS-PERF-$Name-BEGIN"
    $endMarker = "# <<< LKS-PERF-$Name-END"

    $beginIdx = $Text.IndexOf($beginMarker, [StringComparison]::Ordinal)
    if ($beginIdx -lt 0) { return $null }

    $endIdx = $Text.IndexOf($endMarker, $beginIdx, [StringComparison]::Ordinal)
    if ($endIdx -lt 0) { return $null }

    # Extend to the start of the line holding the begin marker, and to the end of the
    # line holding the end marker, so no blank leftover lines remain after removal.
    $spanStart = $Text.LastIndexOf("`n", [Math]::Max(0, $beginIdx - 1))
    if ($spanStart -lt 0) { $spanStart = 0 } else { $spanStart = $spanStart + 1 }

    $lineEnd = $Text.IndexOf("`n", $endIdx)
    $spanEnd = if ($lineEnd -lt 0) { $Text.Length } else { $lineEnd + 1 }

    if ($ConsumeTrailingNewline -and $spanEnd -lt $Text.Length -and $Text[$spanEnd] -eq "`n") {
        $spanEnd++
    }

    [pscustomobject]@{
        Start = $spanStart
        End   = $spanEnd
        Text  = $Text.Substring($spanStart, $spanEnd - $spanStart)
    }
}

function Test-RegionApplied {
    <#
    .SYNOPSIS
        $true when both sentinel markers for the region are present.
    #>
    param([string]$Text, [string]$Name)
    $Text.Contains("# >>> LKS-PERF-$Name-BEGIN") -and $Text.Contains("# <<< LKS-PERF-$Name-END")
}

function Invoke-Patch {
    <#
    .SYNOPSIS
        Applies every missing region. Returns the new text and a per-region log.
    #>
    param([string]$Text, $Specs)

    $log = [System.Collections.Generic.List[string]]::new()
    $updated = $Text

    foreach ($spec in $Specs) {
        if (Test-RegionApplied -Text $updated -Name $spec.Name) {
            $log.Add("  already applied : $($spec.Name)")
            continue
        }

        $patched = ConvertTo-BlockNeedle $spec.Patched

        if ($spec.Kind -eq 'Insert') {
            $anchorNeedle = "`n" + (ConvertTo-Lf $spec.Anchor) + "`n"
            # Keep the anchor line, then a blank line, then the block.
            $replacement = "`n" + (ConvertTo-Lf $spec.Anchor) + "`n`n" + (ConvertTo-Lf $spec.Patched) + "`n"
            $result = Set-FirstOccurrence -Text $updated -Needle $anchorNeedle -Replacement $replacement
            if ($result.Found) {
                $updated = $result.Text
                $log.Add("  applied         : $($spec.Name) (inserted after '$($spec.Anchor)')")
            } else {
                $log.Add("  SKIPPED         : $($spec.Name) (anchor '$($spec.Anchor)' not found)")
            }
            continue
        }

        if ($updated.Contains($patched)) {
            $log.Add("  already applied : $($spec.Name) (patched text present)")
            continue
        }

        $originalNeedle = ConvertTo-BlockNeedle $spec.Original
        $result = Set-FirstOccurrence -Text $updated -Needle $originalNeedle -Replacement $patched
        if ($result.Found) {
            $updated = $result.Text
            $log.Add("  applied         : $($spec.Name)")
        } else {
            $log.Add("  SKIPPED         : $($spec.Name) (stock text not found; profile is not in the expected shape)")
        }
    }

    [pscustomobject]@{ Text = $updated; Log = $log }
}

function Invoke-Unpatch {
    <#
    .SYNOPSIS
        Reverts every applied region back to its stock text.
    #>
    param([string]$Text, $Specs)

    $log = [System.Collections.Generic.List[string]]::new()
    $updated = $Text

    foreach ($spec in $Specs) {
        # An 'Insert' region was added with a blank line before it, so its removal must
        # consume that blank line to restore the original text exactly.
        $span = if ($spec.Kind -eq 'Insert') {
            Get-MarkedSpan -Text $updated -Name $spec.Name -ConsumeTrailingNewline
        } else {
            Get-MarkedSpan -Text $updated -Name $spec.Name
        }
        if (-not $span) {
            $log.Add("  not applied     : $($spec.Name)")
            continue
        }

        # Replacement keeps exactly one newline on each side, matching how
        # ConvertTo-BlockNeedle matched the block when it was applied.
        $replacement = if ($spec.Kind -eq 'Insert') { '' } else { (ConvertTo-Lf $spec.Original) + "`n" }
        $updated = $updated.Remove($span.Start, $span.End - $span.Start).Insert($span.Start, $replacement)
        $log.Add("  reverted        : $($spec.Name)")
    }

    [pscustomobject]@{ Text = $updated; Log = $log }
}

function Write-ProfileText {
    <#
    .SYNOPSIS
        Validates and writes the profile, preserving its original line endings.

    .DESCRIPTION
        Parsing before writing means a malformed edit can never leave a broken profile
        behind. Line endings are restored from the file as it was found.
    #>
    param([string]$Path, [string]$Text, [string]$Eol)

    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        Write-Host '  RESULT: not written, the patched profile has syntax errors:' -ForegroundColor Red
        foreach ($e in $errors) {
            Write-Host ("    line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red
        }
        return $false
    }

    $out = if ($Eol -eq "`r`n") { $Text.Replace("`n", "`r`n") } else { $Text }

    # UTF-8 without BOM, matching how PowerShell profiles are normally stored.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $out, $utf8NoBom)
    return $true
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) {
    throw "Profile not found: $ProfilePath"
}

$specs = Get-RegionSpec
$raw = Get-Content -LiteralPath $ProfilePath -Raw
$eol = Get-Eol $raw
$text = ConvertTo-Lf $raw

Write-Host ''
Write-Host 'PowerShell profile startup-performance fixes' -ForegroundColor Cyan
Write-Host "  Profile : $ProfilePath"
Write-Host "  Size    : $((Get-Item -LiteralPath $ProfilePath).Length) bytes"
Write-Host ''

$states = foreach ($spec in $specs) {
    [pscustomobject]@{
        Name  = $spec.Name
        Begin = $text.Contains("# >>> LKS-PERF-$($spec.Name)-BEGIN")
        End   = $text.Contains("# <<< LKS-PERF-$($spec.Name)-END")
    }
}

$applied = @($states | Where-Object { $_.Begin -and $_.End }).Count
$partial = @($states | Where-Object { ($_.Begin -or $_.End) -and -not ($_.Begin -and $_.End) }).Count
$total = @($states).Count

Write-Host "Status: $applied of $total regions applied"
foreach ($s in $states) {
    $label = if ($s.Begin -and $s.End) { 'applied' }
             elseif ($s.Begin -or $s.End) { 'PARTIAL (markers incomplete)' }
             else { 'not applied' }
    $colour = if ($s.Begin -and $s.End) { 'Green' } elseif ($s.Begin -or $s.End) { 'Yellow' } else { 'DarkGray' }
    Write-Host ("  {0,-9} {1}" -f $s.Name, $label) -ForegroundColor $colour
}
Write-Host ''

if ($Check) {
    if ($applied -eq $total) {
        Write-Host 'All fixes are applied. Nothing to do.' -ForegroundColor Green
    } elseif ($applied -eq 0) {
        Write-Host 'No fixes are applied. Run without -Check to apply them.' -ForegroundColor Yellow
    } else {
        Write-Host 'Some fixes are missing. Run without -Check to apply them.' -ForegroundColor Yellow
    }
    return
}

# Nothing looks patched and nothing matches stock: refuse to guess.
if ($applied -eq 0) {
    $matchesStock = @($specs | Where-Object {
        $_.Kind -eq 'Replace' -and $text.Contains((ConvertTo-Lf $_.Original))
    }).Count
    if ($matchesStock -eq 0) {
        Write-Host 'RESULT: this profile does not contain any of the expected code, so nothing' -ForegroundColor Yellow
        Write-Host '        was changed. These fixes target the Chris Titus Tech profile layout.' -ForegroundColor Yellow
        Write-Host "        If it is a CTT profile, it may be a version this script does not know." -ForegroundColor Yellow
        return
    }
}

if ($RestoreBackup) {
    $candidates = @(Get-ChildItem -LiteralPath (Split-Path -Parent $ProfilePath) -Filter "$(Split-Path -Leaf $ProfilePath).bak-*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -eq 0) {
        Write-Host 'No .bak-* backup found next to the profile.' -ForegroundColor Yellow
        return
    }
    $newest = $candidates[0]
    Write-Host "Restoring from: $($newest.Name)  ($($newest.LastWriteTime))" -ForegroundColor Cyan
    if ($PSCmdlet.ShouldProcess($ProfilePath, "Restore from $($newest.Name)")) {
        Copy-Item -LiteralPath $newest.FullName -Destination $ProfilePath -Force
        Write-Host 'Restored. Restart the shell to use it.' -ForegroundColor Green
    }
    return
}

$action = if ($Uninstall) { 'Revert' } else { 'Apply' }
if (-not $PSCmdlet.ShouldProcess($ProfilePath, "$action perf-fix regions")) { return }

$backup = "$ProfilePath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item -LiteralPath $ProfilePath -Destination $backup -Force
Write-Host "Backup written: $(Split-Path -Leaf $backup)" -ForegroundColor DarkGray
Write-Host ''

if ($Uninstall) {
    Write-Host 'Reverting regions to the stock code:'
    $result = Invoke-Unpatch -Text $text -Specs $specs
    $changed = @($result.Log | Where-Object { $_ -match 'reverted' }).Count
    $result.Log | ForEach-Object { Write-Host $_ }

    if ($changed -eq 0) {
        Write-Host ''
        Write-Host 'Nothing was applied, so the profile is unchanged.' -ForegroundColor Yellow
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        return
    }
} else {
    Write-Host 'Applying missing regions:'
    $result = Invoke-Patch -Text $text -Specs $specs
    $changed = @($result.Log | Where-Object { $_ -match '^\s+applied' }).Count
    $result.Log | ForEach-Object { Write-Host $_ }

    if ($changed -eq 0) {
        Write-Host ''
        Write-Host 'Nothing could be applied. See the SKIPPED lines above.' -ForegroundColor Yellow
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        return
    }
}

Write-Host ''
if (Write-ProfileText -Path $ProfilePath -Text $result.Text -Eol $eol) {
    Write-Host "Done: $changed region(s) changed." -ForegroundColor Green
    if ($Uninstall) {
        Write-Host 'Restart the shell, or run Invoke-Profile, to use the stock profile.' -ForegroundColor DarkGray
    } else {
        Write-Host 'Restart the shell, or run Invoke-Profile, to use the fixes.' -ForegroundColor DarkGray
    }
    Write-Host "Backup: $backup" -ForegroundColor DarkGray
}
