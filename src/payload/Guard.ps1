# ===========================================================================
# >>> LKS-PERF-GUARD-BEGIN
#
# PowerShell profile startup-performance guard.
#
# WHY THIS LIVES IN profile.ps1 (AllHosts) AND NOT IN THE MAIN PROFILE:
#   Update-Profile replaces only Microsoft.PowerShell_profile.ps1
#   ($PROFILE.CurrentUserCurrentHost) with the stock copy from GitHub. This file is
#   loaded earlier and is never touched by that updater, so the reminder and the
#   repair command survive a profile update -- which is exactly when they are needed.
#   Putting this notice in the main profile would have it wiped by the same update
#   that wipes the fixes.
#
# WHAT IT CHECKS:
#   The startup fixes are wrapped in sentinel comments in the main profile. This
#   guard looks for those markers. If they are gone it says so and points at the
#   repair command. The check is a single file read, so it costs about a millisecond.
#
# Managed by Install-ProfilePerf.ps1. Remove this whole block (from the BEGIN marker
# above to the END marker below) to uninstall the guard by hand.
# ===========================================================================

$global:LksPerfProfilePath = $PROFILE.CurrentUserCurrentHost
$global:LksPerfInstallDir  = '@@INSTALL_DIR@@'
$global:LksPerfRepairPath  = Join-Path $global:LksPerfInstallDir 'Repair-ProfilePerf.ps1'
$global:LksPerfRegions     = @('TI', 'LAZY', 'EDITOR', 'NOUPDATE')

# Repair-ProfilePerf is a real file, so the helper below is installed on disk rather
# than defined here. That keeps this block small, since it runs at every shell start.
# The two sizes are how the '$$' in the replacement text is kept literal.

function Test-ProfilePerfFixes {
    <#
    .SYNOPSIS
        Returns $true when the startup-performance fixes are present in the profile.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Path = $global:LksPerfProfilePath)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }

    try {
        $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    } catch {
        return $false
    }

    foreach ($name in $global:LksPerfRegions) {
        if ($text -notmatch [regex]::Escape("# >>> LKS-PERF-$name-BEGIN")) { return $false }
    }

    return $true
}

function Get-ProfilePerfStatus {
    <#
    .SYNOPSIS
        Shows the applied/not-applied state of each managed region.
    #>
    [CmdletBinding()]
    param([string]$Path = $global:LksPerfProfilePath)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Warning "Profile not found: $Path"
        return
    }

    $text = Get-Content -LiteralPath $Path -Raw
    $rows = foreach ($name in @('TI', 'CHOCO', 'EDITOR', 'LAZY', 'NOUPDATE')) {
        $begin = $text.Contains("# >>> LKS-PERF-$name-BEGIN")
        $end = $text.Contains("# <<< LKS-PERF-$name-END")
        [pscustomobject]@{
            Region = $name
            State  = if ($begin -and $end) { 'applied' } elseif ($begin -or $end) { 'PARTIAL' } else { 'not applied' }
        }
    }
    $rows | Format-Table -AutoSize
}

function Repair-ProfilePerf {
    <#
    .SYNOPSIS
        Re-applies the profile startup-performance fixes.

    .DESCRIPTION
        Use this after Update-Profile, which pulls the stock profile from GitHub and
        overwrites the local copy along with the local fixes. The script it calls is
        idempotent: it only patches regions that are missing, writes a timestamped
        backup first, and validates syntax before saving.

    .PARAMETER Check
        Report whether the fixes are present without changing anything.
    #>
    [CmdletBinding()]
    param([switch]$Check)

    if (-not (Test-Path -LiteralPath $global:LksPerfRepairPath -PathType Leaf)) {
        Write-Warning "Repair script not found: $($global:LksPerfRepairPath)"
        Write-Host 'Reinstall with:  irm <install-url> | iex' -ForegroundColor Yellow
        return
    }

    $shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    $shellArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $global:LksPerfRepairPath)
    if ($Check) { $shellArgs += '-Check' }
    & $shell @shellArgs

    if (-not $Check) {
        Write-Host 'Reload the profile to activate:  Invoke-Profile' -ForegroundColor Cyan
    }
}

function Disable-ProfilePerfNotice {
    <#
    .SYNOPSIS
        Silences the startup perf-fix notice for this session.
    #>
    $global:LksPerfNoticeDisabled = $true
    Write-Host 'Startup perf notice disabled for this session.' -ForegroundColor Green
    Write-Host 'To make it permanent, add this line to the top of profile.ps1:' -ForegroundColor DarkGray
    Write-Host '    $global:LksPerfNoticeDisabled = $true' -ForegroundColor DarkGray
}

function Show-ProfilePerfNotice {
    <#
    .SYNOPSIS
        Prints the startup reminder about the profile perf fixes.
    #>
    [CmdletBinding()]
    param()

    if ($global:LksPerfNoticeDisabled) { return }

    # Only in a real console. Test-InteractiveShell lives in the main profile, which
    # loads after this file, so the check is inlined here.
    try {
        if ($Host.Name -ne 'ConsoleHost' -or
            [Console]::IsInputRedirected -or
            [Console]::IsOutputRedirected) {
            return
        }
    } catch {
        return
    }

    if (-not (Test-ProfilePerfFixes)) {
        Write-Host ''
        Write-Host '--------------------------------------------------------------' -ForegroundColor DarkYellow
        Write-Host ' Profile startup fixes are NOT active.' -ForegroundColor Yellow
        Write-Host ' The profile was updated (Update-Profile replaces it) and the' -ForegroundColor Yellow
        Write-Host ' local performance patches went with it.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host ' Re-apply them now:      ' -NoNewline -ForegroundColor Yellow
        Write-Host 'Repair-ProfilePerf' -ForegroundColor White
        Write-Host ' Then reload:            ' -NoNewline -ForegroundColor Yellow
        Write-Host 'Invoke-Profile' -ForegroundColor White
        Write-Host '--------------------------------------------------------------' -ForegroundColor DarkYellow
        Write-Host ''
        return
    }

    # Healthy: one quiet line so the commands stay discoverable without nagging.
    Write-Host "Profile perf fixes: active.  Update-Profile = pull upstream,  Repair-ProfilePerf = re-apply fixes,  Disable-ProfilePerfNotice = hide this." -ForegroundColor DarkGray
}

Show-ProfilePerfNotice
# <<< LKS-PERF-GUARD-END
# ===========================================================================
