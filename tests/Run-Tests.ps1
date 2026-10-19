#Requires -Version 5.1
<#
.SYNOPSIS
    Integration tests for dist/install.ps1.

.DESCRIPTION
    Every test runs against a throwaway sandbox: a scratch profile, a scratch AllHosts
    profile and a scratch install directory, all under the system temp directory. The
    real profile is never touched: every path handed to the installer is checked to be
    inside the temp root first, and the run is aborted if any path escapes.

    Test 3 is the important one. It runs the installer the way a user does from the
    internet -- by feeding its text to Invoke-Expression -- which is the path with no
    $PSScriptRoot.

.NOTES
    Do not name a parameter $Args anywhere in this file. $Args is an automatic
    variable: a parameter of that name silently receives nothing, so calls look
    successful while no arguments reach the target script.
#>
[CmdletBinding()]
param(
    [string]$InstallerPath,
    [switch]$KeepSandbox
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if (-not $InstallerPath) { $InstallerPath = Join-Path $root 'dist\install.ps1' }

$stockProfile = Join-Path $PSScriptRoot 'fixtures\stock-profile.ps1'

if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
    throw "Installer not found: $InstallerPath"
}
if (-not (Test-Path -LiteralPath $stockProfile -PathType Leaf)) {
    throw "Fixture not found: $stockProfile"
}

$script:tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$script:pass = 0
$script:fail = 0
$script:failures = [System.Collections.Generic.List[string]]::new()

function Assert-SandboxPath {
    <#
    .SYNOPSIS
        Hard guard: refuse to let any test target a path outside the temp root.

    .DESCRIPTION
        This exists because an earlier version of this harness used a parameter named
        $Args, which is automatic and therefore always empty. The installer then ran
        with its default paths and modified the real profile. Checking every path here
        turns that class of mistake into a loud failure instead of a silent edit.
    #>
    param([string]$Path, [string]$What)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "SAFETY: empty $What path"
    }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($script:tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "SAFETY: $What path escapes the temp root and would touch a real file: $full"
    }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    Write-Host ''
    Write-Host "== $Name" -ForegroundColor Cyan
    try {
        & $Body
        Write-Host '   PASS' -ForegroundColor Green
        $script:pass++
    } catch {
        Write-Host "   FAIL: $($_.Exception.Message)" -ForegroundColor Red
        $script:fail++
        $script:failures.Add("$Name -> $($_.Exception.Message)")
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-Sandbox {
    $dir = Join-Path $script:tempRoot "pptest-$([Guid]::NewGuid().ToString('n').Substring(0,8))"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $sb = [pscustomobject]@{
        Root       = $dir
        Profile    = Join-Path $dir 'Microsoft.PowerShell_profile.ps1'
        AllHosts   = Join-Path $dir 'profile.ps1'
        InstallDir = Join-Path $dir 'install'
    }
    Copy-Item -LiteralPath $stockProfile -Destination $sb.Profile -Force
    Copy-Item -LiteralPath $stockProfile -Destination $sb.AllHosts -Force
    return $sb
}

function Invoke-Script {
    <#
    .SYNOPSIS
        Runs a script in a child PowerShell with the given arguments.

    .DESCRIPTION
        Arguments are passed through a -Command invocation rather than -File, because
        -File treats '-Confirm:$false' as a literal string instead of binding it.
        Every path argument is sandbox-checked before the child is started.
    #>
    param(
        [string]$Path,
        [string[]]$Arguments = @()
    )

    # The script itself lives in the repo, outside the temp root, and that is expected.
    # Only the paths being handed to it as targets must stay inside the sandbox.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "script not found: $Path"
    }
    foreach ($a in $Arguments) {
        # Value arguments that look like paths must be sandboxed. Flags are skipped.
        if ($a -notmatch '^-') {
            if ($a -match '^[A-Za-z]:\\' -or $a -match '^\\\\') {
                Assert-SandboxPath -Path $a -What 'argument'
            }
        }
    }

    $shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }

    # Quote each argument. Paths contain no quotes or backticks, so simple quoting is safe.
    $quoted = foreach ($a in $Arguments) {
        if ($a -match '^-[A-Za-z]+:') { $a }          # switch form, e.g. -Confirm:$false
        elseif ($a -match '^-[A-Za-z]+$') { $a }      # bare switch
        else { "'" + ($a -replace "'", "''") + "'" }  # value
    }
    $cmd = "& '$Path' " + ($quoted -join ' ')

    $out = & $shell -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1
    return [pscustomobject]@{
        Output   = ($out | Out-String)
        ExitCode = $LASTEXITCODE
    }
}

function Get-RegionCount {
    param([string]$Path)
    $t = Get-Content -LiteralPath $Path -Raw
    $n = 0
    foreach ($r in 'TI', 'CHOCO', 'EDITOR', 'LAZY', 'NOUPDATE') {
        if ($t.Contains("# >>> LKS-PERF-$r-BEGIN") -and $t.Contains("# <<< LKS-PERF-$r-END")) { $n++ }
    }
    return $n
}

function Get-Normalised {
    param([string]$Text)
    ($Text -replace "`r`n", "`n")
}

function Invoke-Installed {
    # Convenience: call the installer with sandbox paths, always.
    param([pscustomobject]$Sandbox, [string[]]$Extra = @())

    $base = @(
        '-ProfilePath', $Sandbox.Profile,
        '-AllHostsPath', $Sandbox.AllHosts,
        '-InstallDir', $Sandbox.InstallDir,
        '-Confirm:$false'
    )
    return Invoke-Script -Path $InstallerPath -Arguments ($base + $Extra)
}

function Assert-SandboxIsolated {
    <#
    .SYNOPSIS
        Verifies the sandbox paths really are distinct from the real profile paths.
    #>
    param([pscustomobject]$Sandbox)

    foreach ($p in $Sandbox.Profile, $Sandbox.AllHosts, $Sandbox.InstallDir) {
        Assert-SandboxPath -Path $p -What 'sandbox'
    }
    Assert-True ($Sandbox.Profile -ne $PROFILE.CurrentUserCurrentHost) 'sandbox profile equals the real profile'
    Assert-True ($Sandbox.AllHosts -ne $PROFILE.CurrentUserAllHosts) 'sandbox AllHosts equals the real AllHosts'
}

Write-Host ''
Write-Host 'Profile-perf installer integration tests' -ForegroundColor Cyan
Write-Host "  installer : $InstallerPath"
Write-Host "  fixture   : $stockProfile"
Write-Host "  sandboxes : under $script:tempRoot"
Write-Host "  real profile (never touched) : $($PROFILE.CurrentUserCurrentHost)"

$sandboxes = [System.Collections.Generic.List[string]]::new()

# ---------------------------------------------------------------------------
Test-Case 'Test 0: sandbox isolation guard works' {
    # The guard itself must reject a real path, otherwise every other test is unsafe.
    $rejected = $false
    try {
        Assert-SandboxPath -Path $PROFILE.CurrentUserCurrentHost -What 'real'
    } catch {
        $rejected = $true
    }
    Assert-True $rejected 'the sandbox guard failed to reject the real profile path'
}

# ---------------------------------------------------------------------------
Test-Case 'Test 1: installer parses' {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($InstallerPath, [ref]$null, [ref]$errs)
    Assert-True (-not $errs -or $errs.Count -eq 0) 'installer has syntax errors'
}

# ---------------------------------------------------------------------------
Test-Case 'Test 2: install into a clean sandbox' {
    $sb = New-Sandbox
    $sandboxes.Add($sb.Root)
    Assert-SandboxIsolated -Sandbox $sb

    $r = Invoke-Installed -Sandbox $sb
    Assert-True ($null -ne $r.Output) 'no output'

    Assert-True ((Get-RegionCount $sb.Profile) -eq 5) "expected 5 regions, got $(Get-RegionCount $sb.Profile)"
    Assert-True (Test-Path (Join-Path $sb.InstallDir 'Repair-ProfilePerf.ps1')) 'repair script not installed'
    Assert-True (Test-Path (Join-Path $sb.InstallDir 'Guard.ps1')) 'guard not installed'
    Assert-True (Test-Path (Join-Path $sb.InstallDir 'Uninstall-ProfilePerf.ps1')) 'uninstaller not installed'
    Assert-True (Test-Path (Join-Path $sb.InstallDir 'ProfilePerf.json')) 'manifest not installed'

    $allHosts = Get-Content -LiteralPath $sb.AllHosts -Raw
    Assert-True ($allHosts.Contains('# >>> LKS-PERF-GUARD-BEGIN')) 'guard not added to AllHosts'
    Assert-True ($allHosts.Contains($sb.InstallDir)) 'guard does not point at the install dir'
    Assert-True (-not ($allHosts -match 'LksPerfRepairPath\s*=\s*Join-Path \$PSScriptRoot')) 'guard still uses $PSScriptRoot'

    foreach ($f in $sb.Profile, $sb.AllHosts) {
        $e = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$e)
        Assert-True (-not $e -or $e.Count -eq 0) "$(Split-Path -Leaf $f) has syntax errors"
    }
}

# ---------------------------------------------------------------------------
Test-Case 'Test 3: install via irm|iex simulation (no PSScriptRoot)' {
    $sb = New-Sandbox
    $sandboxes.Add($sb.Root)
    Assert-SandboxIsolated -Sandbox $sb

    # Reading the text and feeding it to scriptblock::Create is exactly what
    # 'irm <url> | iex' does, and it provides no $PSScriptRoot.
    $text = Get-Content -LiteralPath $InstallerPath -Raw
    Assert-True (-not [string]::IsNullOrWhiteSpace($text)) 'installer text is empty'

    $prop = ([scriptblock]::Create($text))
    Assert-True ($null -ne $prop) 'scriptblock::Create returned nothing'

    # Run in-process; the sandbox guard above has already proven the paths are safe.
    & $prop -ProfilePath $sb.Profile -AllHostsPath $sb.AllHosts -InstallDir $sb.InstallDir -Confirm:$false | Out-Null

    Assert-True ((Get-RegionCount $sb.Profile) -eq 5) "expected 5 regions via iex, got $(Get-RegionCount $sb.Profile)"
    Assert-True (Test-Path (Join-Path $sb.InstallDir 'Repair-ProfilePerf.ps1')) 'repair script not written via iex'
    Assert-True ($null -ne $prop.Ast) 'scriptblock has no AST'
}

# ---------------------------------------------------------------------------
Test-Case 'Test 4: idempotency (second install changes nothing)' {
    $sb = New-Sandbox
    $sandboxes.Add($sb.Root)
    Assert-SandboxIsolated -Sandbox $sb

    [void](Invoke-Installed -Sandbox $sb)
    $profAfter1 = Get-Content -LiteralPath $sb.Profile -Raw
    $allAfter1 = Get-Content -LiteralPath $sb.AllHosts -Raw

    [void](Invoke-Installed -Sandbox $sb)
    $profAfter2 = Get-Content -LiteralPath $sb.Profile -Raw
    $allAfter2 = Get-Content -LiteralPath $sb.AllHosts -Raw

    Assert-True ((Get-RegionCount $sb.Profile) -eq 5) 'region count wrong after second install'
    Assert-True ($profAfter1 -eq $profAfter2) 'profile changed on second install'

    $guard1 = ([regex]::Matches($allAfter1, '# >>> LKS-PERF-GUARD-BEGIN')).Count
    $guard2 = ([regex]::Matches($allAfter2, '# >>> LKS-PERF-GUARD-BEGIN')).Count
    Assert-True ($guard1 -eq 1) "guard appears $guard1 times after first install"
    Assert-True ($guard2 -eq 1) "guard appears $guard2 times after second install"
    Assert-True ($allAfter1.Length -eq $allAfter2.Length) "AllHosts grew on reinstall ($($allAfter1.Length) -> $($allAfter2.Length))"
}

# ---------------------------------------------------------------------------
Test-Case 'Test 5: profile update wipes fixes, guard notices, repair restores' {
    $sb = New-Sandbox
    $sandboxes.Add($sb.Root)
    Assert-SandboxIsolated -Sandbox $sb

    [void](Invoke-Installed -Sandbox $sb)
    Assert-True ((Get-RegionCount $sb.Profile) -eq 5) 'setup failed'

    # Simulate 'Update-Profile': the stock file overwrites the patched profile.
    Copy-Item -LiteralPath $stockProfile -Destination $sb.Profile -Force
    Assert-True ((Get-RegionCount $sb.Profile) -eq 0) 'simulated update did not wipe regions'

    $guardPath = Join-Path $sb.InstallDir 'Guard.ps1'
    $shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }

    $probe = @"
`$PROFILE = [pscustomobject]@{ CurrentUserCurrentHost = '$($sb.Profile)'; CurrentUserAllHosts = '$($sb.AllHosts)' }
. '$guardPath'
'RESULT=' + (Test-ProfilePerfFixes)
"@
    $before = & $shell -NoProfile -Command $probe 2>&1 | Out-String
    Assert-True ($before -match 'RESULT=False') "guard should report False after wipe; got: $($before.Trim())"

    [void](Invoke-Script -Path (Join-Path $sb.InstallDir 'Repair-ProfilePerf.ps1') -Arguments @('-ProfilePath', $sb.Profile, '-Confirm:$false'))
    Assert-True ((Get-RegionCount $sb.Profile) -eq 5) "repair restored $(Get-RegionCount $sb.Profile)/5"

    $after = & $shell -NoProfile -Command $probe 2>&1 | Out-String
    Assert-True ($after -match 'RESULT=True') "guard should report True after repair; got: $($after.Trim())"
}

# ---------------------------------------------------------------------------
Test-Case 'Test 6: Repair-ProfilePerf -Check reports all applied' {
    $sb = New-Sandbox
    $sandboxes.Add($sb.Root)
    Assert-SandboxIsolated -Sandbox $sb

    [void](Invoke-Installed -Sandbox $sb)
    $r = Invoke-Script -Path (Join-Path $sb.InstallDir 'Repair-ProfilePerf.ps1') -Arguments @('-ProfilePath', $sb.Profile, '-Check')
    Assert-True ($r.Output -match '5 of 5 regions applied') "unexpected status output: $($r.Output)"
    Assert-True ($r.Output -match 'All fixes are applied') 'missing success line'
}

# ---------------------------------------------------------------------------
Test-Case 'Test 7: refuses an unrelated profile without -Force' {
    $sb = New-Sandbox
    $sandboxes.Add($sb.Root)
    Assert-SandboxIsolated -Sandbox $sb

    Set-Content -LiteralPath $sb.Profile -Value "# my own profile`nfunction Thing { 'x' }`n" -Encoding utf8
    $beforeText = Get-Content -LiteralPath $sb.Profile -Raw

    $r = Invoke-Installed -Sandbox $sb
    Assert-True ($r.Output -match 'does not look like a profile') "should have refused; got: $($r.Output.Trim())"
    Assert-True ((Get-RegionCount $sb.Profile) -eq 0) 'profile was modified despite refusal'
    Assert-True ((Get-Content -LiteralPath $sb.Profile -Raw) -eq $beforeText) 'profile content changed'

    # -Force bypasses the shape pre-check, so the run proceeds far enough to write its
    # payload scripts. It must still not corrupt the profile: the patch step is driven
    # by the stock CTT anchors, and this profile has none, so nothing is written.
    $r2 = Invoke-Installed -Sandbox $sb -Extra @('-Force')
    Assert-True ($r2.Output -notmatch 'does not look like a profile') "the pre-check ran despite -Force: $($r2.Output.Trim())"
    Assert-True ((Get-Content -LiteralPath $sb.Profile -Raw) -eq $beforeText) 'profile changed even though it has no patchable regions'

    $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($sb.Profile, [ref]$null, [ref]$e)
    Assert-True (-not $e -or $e.Count -eq 0) 'profile no longer parses'
}

# ---------------------------------------------------------------------------
Test-Case 'Test 8: uninstall restores the stock profile exactly' {
    $sb = New-Sandbox
    $sandboxes.Add($sb.Root)
    Assert-SandboxIsolated -Sandbox $sb

    $original = Get-Normalised (Get-Content -LiteralPath $sb.Profile -Raw)

    [void](Invoke-Installed -Sandbox $sb)
    Assert-True ((Get-RegionCount $sb.Profile) -eq 5) 'install failed'

    [void](Invoke-Script -Path (Join-Path $sb.InstallDir 'Uninstall-ProfilePerf.ps1') -Arguments @('-Confirm:$false'))

    $after = Get-Normalised (Get-Content -LiteralPath $sb.Profile -Raw)
    Assert-True ((Get-RegionCount $sb.Profile) -eq 0) "regions remain after uninstall: $(Get-RegionCount $sb.Profile)"

    # The strongest check available: apply + revert must be exact inverses.
    if ($original -ne $after) {
        $n = [Math]::Min($original.Length, $after.Length)
        $i = 0
        while ($i -lt $n -and $original[$i] -eq $after[$i]) { $i++ }
        throw "profile not restored exactly: first difference at index $i (lengths $($original.Length) vs $($after.Length))"
    }

    Assert-True (-not (Get-Content -LiteralPath $sb.AllHosts -Raw).Contains('LKS-PERF-GUARD-BEGIN')) 'guard still in AllHosts'
    Assert-True (-not (Test-Path -LiteralPath $sb.InstallDir)) 'install directory not removed'
}

# ---------------------------------------------------------------------------
Test-Case 'Test 9: uninstall is safe when nothing is installed' {
    $sb = New-Sandbox
    $sandboxes.Add($sb.Root)
    Assert-SandboxIsolated -Sandbox $sb

    $beforeText = Get-Content -LiteralPath $sb.Profile -Raw
    [void](Invoke-Script -Path $InstallerPath -Arguments @(
            '-ProfilePath', $sb.Profile,
            '-AllHostsPath', $sb.AllHosts,
            '-InstallDir', $sb.InstallDir,
            '-Uninstall', '-Confirm:$false'
        ))

    $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($sb.Profile, [ref]$null, [ref]$e)
    Assert-True (-not $e -or $e.Count -eq 0) 'profile broken by uninstall-when-absent'
    Assert-True ((Get-RegionCount $sb.Profile) -eq 0) 'regions appeared from nowhere'
    Assert-True ((Get-Content -LiteralPath $sb.Profile -Raw) -eq $beforeText) 'profile was modified'
}

# ---------------------------------------------------------------------------
Test-Case 'Test 10: patched profile loads with lazy wrappers active' {
    $sb = New-Sandbox
    $sandboxes.Add($sb.Root)
    Assert-SandboxIsolated -Sandbox $sb

    [void](Invoke-Installed -Sandbox $sb)

    $shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $probe = @"
`$Profile = '$($sb.Profile)'
. '$($sb.Profile)'
'ICONSLOADED=' + [bool](Get-Module Terminal-Icons)
'GCI=' + (Get-Command Get-ChildItem).CommandType
'REFRESH=' + [bool](Get-Command refreshenv -ErrorAction SilentlyContinue)
"@
    $out = & $shell -NoProfile -Command $probe 2>&1 | Out-String
    Assert-True ($out -match 'ICONSLOADED=False') "Terminal-Icons should be lazy; got: $($out.Trim())"
    Assert-True ($out -match 'REFRESH=True') "refreshenv proxy missing; got: $($out.Trim())"
}

# ---------------------------------------------------------------------------

if (-not $KeepSandbox) {
    foreach ($d in $sandboxes) {
        if ($d.StartsWith($script:tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ''
Write-Host '===========================================' -ForegroundColor Cyan
Write-Host ("  passed: {0}   failed: {1}" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) {
    Write-Host ''
    foreach ($f in $script:failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
Write-Host ''
exit 0
