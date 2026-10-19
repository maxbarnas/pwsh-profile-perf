# pwsh-profile-perf

Speeds up interactive PowerShell startup for profiles based on [Chris Titus Tech's
PowerShell profile](https://github.com/ChrisTitusTech/powershell-profile), by deferring
slow module imports until they are actually used.

Measured on the machine this was developed on: **1891 ms → ~1086 ms** to a usable
prompt, a 43% reduction.

## Install

```powershell
irm https://raw.githubusercontent.com/maxbarnas/pwsh-profile-perf/main/dist/install.ps1 | iex
```

That is the whole install. Nothing else to download, no modules to add.

To install from a local copy instead:

```powershell
.\dist\install.ps1
```

Check status at any time:

```powershell
.\Install-ProfilePerf.ps1 -Check
```

Uninstall:

```powershell
& "$HOME\.pwsh-profile-perf\Uninstall-ProfilePerf.ps1"
```

## What it fixes

| Problem | Cost | Fix |
|---|---|---|
| Terminal-Icons imported at startup | ~500 ms | imported on first directory listing |
| Chocolatey profile imported at startup | ~100–280 ms | imported on first `refreshenv` |
| `Resolve-Editor` probes 8 editors, `code` is 5th | ~185 ms | probes installed editors first |

The Terminal-Icons number is the surprising one. The module is not slow to find; the
cost is its module body. It dot-sources a 571 KB glyph table to build a 9253-entry
hashtable, converts both built-in colour themes to escape sequences, and then rewrites
about 184 KB of theme XML into `%APPDATA%` **on every single import**. The upstream
project knows about this ([issue #117](https://github.com/devblackops/Terminal-Icons/issues/117));
there is no version that makes it cheap.

It also switches off the profile's weekly self-update, because `Update-Profile` replaces
the whole profile with the stock copy from GitHub and would discard these fixes.

## How the lazy loading works

Terminal-Icons is imported by a thin `Get-ChildItem` wrapper the first time you list a
directory. The wrapper then removes itself, so later calls go straight to the real
cmdlet with no indirection left behind. Icons appear on the **first** listing.

The wrapper is deliberately a plain function rather than an advanced one. `$args`
preserves the caller's named parameters through `@args`, but
`[Parameter(ValueFromRemainingArguments)]` flattens them into positionals and breaks
`-Force`, `-Filter`, and `-Name`. That is verified against the unwrapped cmdlet across 25
call shapes.

Chocolatey works the same way around `refreshenv`.

## Staying fixed after a profile update

Each fix lives in a region bounded by sentinel comments:

```
LKS-PERF-TI-BEGIN / END         lazy Terminal-Icons
LKS-PERF-CHOCO-BEGIN / END      lazy Chocolatey profile
LKS-PERF-EDITOR-BEGIN / END     editor probe order
LKS-PERF-LAZY-BEGIN / END       the first-use wrappers
LKS-PERF-NOUPDATE-BEGIN / END   auto-update left off
```

Two things depend on those markers.

**A startup reminder** is written into `profile.ps1` (`$PROFILE.CurrentUserAllHosts`).
That file is chosen deliberately: `Update-Profile` only overwrites
`Microsoft.PowerShell_profile.ps1`, so a notice placed there would be destroyed by the
same update it exists to warn about. When the fixes are present it prints one quiet
line; when they are gone it prints a warning pointing at the repair command.

**A repair command** restores whatever is missing:

```powershell
Repair-ProfilePerf            # re-apply missing regions
Repair-ProfilePerf -Check     # status only
Get-ProfilePerfStatus         # per-region table
Disable-ProfilePerfNotice     # hide the startup line
```

`Repair-ProfilePerf` is idempotent, writes a timestamped backup, and parses the result
before saving, so a profile that would not parse is never written.

If you deliberately want the upstream profile:

```powershell
Update-Profile          # pulls the stock profile from GitHub
Repair-ProfilePerf      # re-apply the fixes
```

## Requirements

PowerShell 7+, or Windows PowerShell 5.1. Windows. The target profile must derive from
the CTT profile layout; on anything else the installer refuses to touch it and says so.
`-Force` overrides the pre-check, but the fixes still can only be applied where the
expected stock code exists.

## Repository layout

```
dist/install.ps1              generated single-file installer (the thing users download)
src/installer.body.ps1        installer source
src/uninstaller.body.ps1      uninstaller source
src/payload/Guard.ps1         startup reminder, installed into profile.ps1
src/payload/Repair-ProfilePerf.ps1   apply / revert / check engine
build/Build.ps1               assembles dist/install.ps1
tests/Run-Tests.ps1           11 integration tests
tests/fixtures/               stock CTT profile used as test input
```

## Building

```powershell
.\build\Build.ps1 -Version 1.1.0 -InstallUrl 'https://raw.githubusercontent.com/maxbarnas/pwsh-profile-perf/main/dist/install.ps1'
.\tests\Run-Tests.ps1
```

`Build.ps1` substitutes the version and install URL, embeds the payload scripts, and
refuses to emit a file that does not parse.

### Why the payloads are embedded as base64

The installer has to work when piped into `Invoke-Expression`, which rules out companion
files and makes `$PSScriptRoot` unavailable. So the payload scripts are embedded in the
installer itself.

They are base64 rather than pasted in verbatim for a specific reason: **PowerShell ends a
here-string at the first line beginning with the closing marker**, and the payloads
legitimately contain such lines. `Repair-ProfilePerf.ps1` has five `'@` lines at column 0.
Embedding it verbatim inside `@' ... '@` produces a file that does not parse. Base64
cannot contain a line starting with the terminator, so it round-trips safely.

## Tests

`tests/Run-Tests.ps1` runs 11 integration tests, each in a throwaway sandbox under the
system temp directory. Your real profile is never touched; every path passed to the
installer is checked to be inside the temp root first, and the run aborts if one escapes.

The suite covers: installing clean, installing via the `irm|iex` path with no
`$PSScriptRoot`, idempotency, an update wiping the fixes and the guard noticing, repair
restoring them, refusing an unrelated profile, and uninstall restoring the stock profile
**byte-for-byte**.

Two bugs found by these tests, both fixed, are worth knowing about if you extend this:

* `$Args` is an automatic variable. A test helper with a `$Args` parameter silently
  receives nothing, so the installer ran with its default paths and edited the real
  profile while every test appeared to pass. The harness now computes default paths and
  aborts if a target escapes the temp root.
* The `NOUPDATE` stock text is the bare call `Invoke-ScheduledProfileUpdate`, which also
  occurs inside the line `function Invoke-ScheduledProfileUpdate {`. An unanchored
  `.Replace()` rewrote the function declaration and produced a profile that would not
  parse. Region matching is now newline-anchored and replaces only the first occurrence.

## License

MIT. See [LICENSE](LICENSE).
