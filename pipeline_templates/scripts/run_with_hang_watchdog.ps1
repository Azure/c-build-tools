# Copyright (c) Microsoft. All rights reserved.

<#
.SYNOPSIS
    Launches an arbitrary executable (e.g. ctest, a single test exe) alongside the
    test_hang_watchdog.ps1 watchdog, captures dumps for hung processes, and forwards
    the executable's exit code.

.DESCRIPTION
    Designed to be invoked from a CI pipeline task OR from a developer shell. The wrapper:
      1. Launches the requested executable with the requested arguments and working directory,
         inheriting stdout/stderr so the surrounding log looks the same as a bare invocation.
      2. Launches test_hang_watchdog.ps1 as a hidden background process targeting the new pid.
      3. Waits for the executable to exit, then gives the watchdog a brief grace period to wind down.
      4. Prints the watchdog's hang_summary.txt (if any) and reports how many dumps were captured.
      5. Returns the executable's exit code.

    When invoked in an Azure DevOps task, also emits ##vso[] commands so:
      - A warning shows up in the build summary if any dumps were captured.
      - The HangDumpsCaptured task variable is set to 'true' (consumed by upload_logs_on_fail.yml
        to conditionally publish the test_hang_dumps artifact).

.PARAMETER Executable
    Full path to the executable to run (e.g. ctest.exe, or a single test exe).

.PARAMETER Arguments
    Argument string passed to the executable. May contain embedded quotes; passed as-is to
    System.Diagnostics.ProcessStartInfo.Arguments.

.PARAMETER WorkingDirectory
    Working directory for the executable. Defaults to the current directory.

.PARAMETER DumpDir
    Directory where dumps and hang_summary.txt are written. Defaults to
    "$env:BUILD_ARTIFACTSTAGINGDIRECTORY\test_hang_dumps" when that env var is set,
    otherwise "$env:TEMP\test_hang_dumps".

.PARAMETER WatchdogScript
    Full path to test_hang_watchdog.ps1. Defaults to the watchdog next to this script.

.PARAMETER DumpThresholdSec
    Process age (seconds) at which the watchdog captures a dump. Default 1200.

.PARAMETER PollIntervalSec
    Watchdog poll interval (seconds). Default 30.

.PARAMETER NamePattern
    Regex applied to candidate process names. Default '_exe_'.

.PARAMETER IncludeWatched
    If set, the launched executable itself (not just its children) is a dump candidate.
    Use this when wrapping a single test exe directly, not when wrapping ctest.

.PARAMETER KillAfterDump
    If set, each candidate process is killed immediately after a successful dump. Intended for
    single-exe runs so the wrapped exe exits promptly and the artifact-publishing step gets to
    run before the surrounding ADO job timeout reaps the entire task. Leave false under ctest --
    killing a child would skip remaining tests and confuse ctest's reporting.

.EXAMPLE
    # CI-style: wrap a ctest invocation
    PS> .\run_with_hang_watchdog.ps1 `
            -Executable 'C:\...\ctest.exe' `
            -Arguments '-j 16 -C Debug -V --output-on-failure -E _perf' `
            -WorkingDirectory C:\src\cmake `
            -DumpThresholdSec 1200

.EXAMPLE
    # Single-exe: wrap a developer-test invocation, dumping if the test exe itself runs > 60s
    PS> .\run_with_hang_watchdog.ps1 `
            -Executable C:\bin\my_test_int_exe_myproject.exe `
            -DumpThresholdSec 60 -PollIntervalSec 5 -IncludeWatched
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$Executable,

    [Parameter(Mandatory = $false)]
    [string]$Arguments = '',

    [Parameter(Mandatory = $false)]
    [string]$WorkingDirectory = '',

    [Parameter(Mandatory = $false)]
    [string]$DumpDir = '',

    [Parameter(Mandatory = $false)]
    [string]$WatchdogScript = '',

    [Parameter(Mandatory = $false)]
    [int]$DumpThresholdSec = 1200,

    [Parameter(Mandatory = $false)]
    [int]$PollIntervalSec = 30,

    [Parameter(Mandatory = $false)]
    [string]$NamePattern = '_exe_',

    [Parameter(Mandatory = $false)]
    [bool]$IncludeWatched = $false,

    [Parameter(Mandatory = $false)]
    [bool]$KillAfterDump = $false
)

$ErrorActionPreference = 'Stop'

if (-not $WorkingDirectory) {
    $WorkingDirectory = (Get-Location).Path
}

if (-not $DumpDir) {
    if ($env:BUILD_ARTIFACTSTAGINGDIRECTORY) {
        $DumpDir = Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY 'test_hang_dumps'
    }
    else {
        $DumpDir = Join-Path $env:TEMP 'test_hang_dumps'
    }
}
if (-not (Test-Path $DumpDir)) { New-Item -ItemType Directory -Path $DumpDir -Force | Out-Null }

if (-not $WatchdogScript) {
    $WatchdogScript = Join-Path $PSScriptRoot 'test_hang_watchdog.ps1'
}
if (-not (Test-Path $WatchdogScript)) {
    throw "Watchdog script not found at: $WatchdogScript"
}

# Resolve executable: accept either a full path or a name on PATH
$resolvedExecutable = $Executable
if (-not (Test-Path -LiteralPath $resolvedExecutable -ErrorAction SilentlyContinue)) {
    $cmd = Get-Command $Executable -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        $resolvedExecutable = $cmd.Source
    }
    else {
        throw "Executable not found at: $Executable (and not on PATH)"
    }
}

Write-Host "Launching: $resolvedExecutable $Arguments"

# Launch the executable with stdout/stderr inherited so the surrounding log is unchanged.
# System.Diagnostics.Process is cleaner than Start-Process for args containing embedded quotes.
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $resolvedExecutable
$psi.Arguments = $Arguments
$psi.UseShellExecute = $false
$psi.WorkingDirectory = $WorkingDirectory
$childProc = [System.Diagnostics.Process]::Start($psi)

Write-Host "Child pid: $($childProc.Id) - launching test_hang_watchdog (threshold ${DumpThresholdSec}s, poll ${PollIntervalSec}s, includeWatched=$IncludeWatched, killAfterDump=$KillAfterDump)"

# Start-Process -ArgumentList joins string[] with spaces and does NOT quote individual
# values, so paths containing spaces would be split into multiple arguments. Build a single
# argument string with path-valued args pre-quoted to preserve them.
$watchdogArgs = @(
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', "`"$WatchdogScript`"",
    '-WatchedPid', $childProc.Id,
    '-DumpDir', "`"$DumpDir`"",
    '-DumpThresholdSec', $DumpThresholdSec,
    '-PollIntervalSec', $PollIntervalSec,
    '-NamePattern', "`"$NamePattern`""
)
if ($IncludeWatched) { $watchdogArgs += '-IncludeWatched' }
if ($KillAfterDump)  { $watchdogArgs += '-KillAfterDump' }

$watchdogProc = Start-Process -FilePath 'powershell.exe' -ArgumentList ($watchdogArgs -join ' ') -PassThru -WindowStyle Hidden

# Block until the wrapped executable finishes.
$childProc.WaitForExit()
$childExitCode = $childProc.ExitCode
Write-Host "Wrapped executable exited with $childExitCode"

# Watchdog now polls for watched-pid-gone every 1s internally, so it should exit within a
# couple of seconds of the wrapped exe finishing regardless of $PollIntervalSec.
$watchdogTimeoutMs = 10 * 1000
if (-not $watchdogProc.WaitForExit($watchdogTimeoutMs)) {
    Write-Host "Watchdog (pid $($watchdogProc.Id)) did not exit in time; killing it"
    try { $watchdogProc.Kill() } catch {}
}

$summaryFile = Join-Path $DumpDir 'hang_summary.txt'
$dumpCount = 0
if (Test-Path $summaryFile) {
    Write-Host "--- test_hang_watchdog summary ---"
    Get-Content $summaryFile | ForEach-Object { Write-Host $_ }
    $dumpCount = (Get-ChildItem $DumpDir -Filter '*.dmp' -ErrorAction SilentlyContinue | Measure-Object).Count
}

# Surface results when running under Azure DevOps.
if ($env:TF_BUILD) {
    if ($dumpCount -gt 0) {
        Write-Host "##vso[task.logissue type=warning]Captured $dumpCount hang dump(s) under $DumpDir; see test_hang_dumps artifact."
        Write-Host "##vso[task.setvariable variable=HangDumpsCaptured]true"
    }
}
else {
    if ($dumpCount -gt 0) {
        Write-Host "WARNING: Captured $dumpCount hang dump(s) under $DumpDir"
    }
}

exit $childExitCode
