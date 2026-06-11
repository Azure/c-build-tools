# Copyright (c) Microsoft. All rights reserved.

<#
.SYNOPSIS
    Watchdog that captures process dumps of test exes that approach their per-test timeout.

.DESCRIPTION
    Polls every -PollIntervalSec seconds. While the -WatchedPid is alive, considers a set of
    candidate processes:
      - Direct children of -WatchedPid whose process name matches -NamePattern.
      - The -WatchedPid itself, if -IncludeWatched is set and its name matches -NamePattern
        (use this when wrapping a single test exe directly).
    For each candidate, computes age in seconds. When age exceeds -DumpThresholdSec, captures a
    full-memory dump using awdump.exe (preferred, found via the MonAgentCore install directory)
    or procdump.exe (fallback - downloaded from sysinternals if not present, signature-checked
    before being executed).

    Exits cleanly when the watched process exits.

.PARAMETER WatchedPid
    PID of the process to watch. The watchdog exits when this process is gone.
    Children of this process whose name matches -NamePattern are candidates for dumping.

.PARAMETER DumpThresholdSec
    Process age (in seconds) at which a dump is captured. Defaults to 1200 (20 minutes).

.PARAMETER DumpDir
    Directory where dumps and the hang_summary.txt log are written.

.PARAMETER PollIntervalSec
    How often to poll. Defaults to 30 seconds.

.PARAMETER NamePattern
    Regex applied to process Name. Only matching processes are eligible for dumping.
    Defaults to '_exe_'.

.PARAMETER IncludeWatched
    If set, the -WatchedPid itself is also a dump candidate (in addition to its children).
    Use this when the wrapper launches the test exe directly (single-exe scenario) rather
    than launching ctest.

.PARAMETER KillAfterDump
    If set, each candidate process is killed after its dump has been captured. Use this in
    single-exe scenarios (combined with -IncludeWatched) so the wrapped test exits promptly
    after we've captured evidence -- otherwise the surrounding ADO job timeout can kill the
    entire task before the dump artifact gets published. Not appropriate under ctest, where
    killing a child test would corrupt ctest's bookkeeping and skip remaining tests.

.EXAMPLE
    PS> .\test_hang_watchdog.ps1 -WatchedPid 12345 -DumpDir C:\dumps -DumpThresholdSec 1200
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [int]$WatchedPid,

    [Parameter(Mandatory = $true)]
    [string]$DumpDir,

    [Parameter(Mandatory = $false)]
    [int]$DumpThresholdSec = 1200,

    [Parameter(Mandatory = $false)]
    [int]$PollIntervalSec = 30,

    [Parameter(Mandatory = $false)]
    [string]$NamePattern = '_exe_',

    [Parameter(Mandatory = $false)]
    [switch]$IncludeWatched,

    [Parameter(Mandatory = $false)]
    [switch]$KillAfterDump
)

$ErrorActionPreference = 'Continue'

if (-not (Test-Path $DumpDir)) {
    New-Item -ItemType Directory -Path $DumpDir -Force | Out-Null
}

$summaryFile = Join-Path $DumpDir 'hang_summary.txt'
"=== test_hang_watchdog started at $(Get-Date -Format o) (WatchedPid=$WatchedPid, threshold=${DumpThresholdSec}s, poll=${PollIntervalSec}s, includeWatched=$IncludeWatched, killAfterDump=$KillAfterDump) ===" | Add-Content $summaryFile

# Locate awdump.exe via MonAgentCore install directory
# Reference: https://eng.ms/docs/products/azure-watson/azurewatson/dumpcreationwithawdump
function Find-Awdump {
    try {
        $monAgent = Get-CimInstance -ClassName Win32_Process -Filter "Name='MonAgentCore.exe'" -ErrorAction Stop |
            Select-Object -First 1
        if ($null -eq $monAgent -or [string]::IsNullOrWhiteSpace($monAgent.ExecutablePath)) {
            return $null
        }
        $candidate = Join-Path ([System.IO.Path]::GetDirectoryName($monAgent.ExecutablePath)) 'awdump.exe'
        if (Test-Path $candidate) { return $candidate } else { return $null }
    }
    catch {
        return $null
    }
}

# Locate procdump.exe (PATH first, then download from sysinternals if missing).
# After download or for a cached copy, verify Authenticode signature is Microsoft-signed.
function Find-Procdump {
    $cmd = Get-Command procdump.exe -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }

    $candidate = Join-Path $DumpDir 'procdump.exe'
    if (-not (Test-Path $candidate)) {
        try {
            Invoke-WebRequest -Uri 'https://live.sysinternals.com/procdump.exe' -OutFile $candidate -UseBasicParsing -ErrorAction Stop
        }
        catch {
            return $null
        }
    }

    try {
        $sig = Get-AuthenticodeSignature -FilePath $candidate -ErrorAction Stop
        $signerIsMicrosoft = ($null -ne $sig.SignerCertificate) -and ($sig.SignerCertificate.Subject -match 'O=Microsoft Corporation')
        if ($sig.Status -ne 'Valid' -or -not $signerIsMicrosoft) {
            "$(Get-Date -Format o) PROCDUMP_SIGCHECK_FAIL path=$candidate status=$($sig.Status) subject=$($sig.SignerCertificate.Subject)" | Add-Content $summaryFile
            Remove-Item -Path $candidate -Force -ErrorAction SilentlyContinue
            return $null
        }
        return $candidate
    }
    catch {
        "$(Get-Date -Format o) PROCDUMP_SIGCHECK_ERROR path=$candidate err=$($_.Exception.Message)" | Add-Content $summaryFile
        Remove-Item -Path $candidate -Force -ErrorAction SilentlyContinue
        return $null
    }
}

# Capture a full-memory dump of $procId using whichever tool is available.
# Returns @{Success; Tool; DumpFile}. On success the dump file is always under $DumpDir
# so the wrapper can count *.dmp to know whether to publish the artifact.
function Invoke-Dump {
    param ([int]$procId, [string]$exeName)

    $dumpFile = Join-Path $DumpDir ("{0}_{1}.dmp" -f $exeName, $procId)

    $awdumpPath = Find-Awdump
    if ($null -ne $awdumpPath) {
        # awdump's default destination depends on its configuration; force it to write under $DumpDir
        # by running it with -WorkingDirectory $DumpDir and then picking up any new *.dmp.
        $beforeDumps = @(Get-ChildItem -Path $DumpDir -Filter '*.dmp' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        Start-Process -FilePath $awdumpPath -ArgumentList @('create', $procId, '-bypass') -WorkingDirectory $DumpDir -Wait -NoNewWindow | Out-Null
        $newDump = Get-ChildItem -Path $DumpDir -Filter '*.dmp' -File -ErrorAction SilentlyContinue |
            Where-Object { $beforeDumps -notcontains $_.FullName } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($null -ne $newDump) {
            if ($newDump.FullName -ne $dumpFile) {
                Move-Item -Path $newDump.FullName -Destination $dumpFile -Force -ErrorAction SilentlyContinue
            }
            $success = (Test-Path $dumpFile) -and ((Get-Item $dumpFile -ErrorAction SilentlyContinue).Length -gt 0)
            if ($success) {
                return @{ Success = $true; Tool = 'awdump'; DumpFile = $dumpFile }
            }
        }
        # awdump didn't produce a dump under $DumpDir; fall through to procdump so we still publish something.
    }

    $procdumpPath = Find-Procdump
    if ($null -ne $procdumpPath) {
        # procdump's exit code is the count of dumps written, not 0/1 success. Check the file instead.
        Start-Process -FilePath $procdumpPath -ArgumentList @('-accepteula', '-ma', $procId, $dumpFile) -Wait -NoNewWindow | Out-Null
        $success = (Test-Path $dumpFile) -and ((Get-Item $dumpFile).Length -gt 0)
        return @{ Success = $success; Tool = 'procdump'; DumpFile = $dumpFile }
    }

    return @{ Success = $false; Tool = 'none'; DumpFile = '' }
}

$alreadyDumped = New-Object 'System.Collections.Generic.HashSet[int]'

# Inner watched-pid check granularity: how often we poll for the watched pid being gone,
# independent of how often we re-scan candidates. Keeping this small means the watchdog
# notices the wrapper's exe finishing within ~1s instead of up to $PollIntervalSec.
$watchedCheckIntervalSec = 1

while ($true) {
    # Sleep in $watchedCheckIntervalSec increments up to a full poll tick so we notice the
    # watched pid is gone quickly even when $PollIntervalSec is large.
    $elapsedThisTick = 0
    while ($elapsedThisTick -lt $PollIntervalSec) {
        Start-Sleep -Seconds $watchedCheckIntervalSec
        if ($null -eq (Get-Process -Id $WatchedPid -ErrorAction SilentlyContinue)) {
            "=== watched pid $WatchedPid is gone at $(Get-Date -Format o); exiting ===" | Add-Content $summaryFile
            return
        }
        $elapsedThisTick += $watchedCheckIntervalSec
    }

    $now = Get-Date
    $candidates = @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $WatchedPid" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $NamePattern })
    if ($IncludeWatched) {
        $self = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $WatchedPid" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $NamePattern }
        if ($null -ne $self) { $candidates += $self }
    }

    foreach ($p in $candidates) {
        if ($alreadyDumped.Contains([int]$p.ProcessId)) { continue }
        if ($null -eq $p.CreationDate) { continue }

        $ageSec = ($now - $p.CreationDate).TotalSeconds
        if ($ageSec -lt $DumpThresholdSec) { continue }

        "$(Get-Date -Format o) HANG_DETECTED pid=$($p.ProcessId) name=$($p.Name) age=$([math]::Round($ageSec,1))s cmd=$($p.CommandLine)" | Add-Content $summaryFile
        $result = Invoke-Dump -procId ([int]$p.ProcessId) -exeName ([System.IO.Path]::GetFileNameWithoutExtension($p.Name))
        "$(Get-Date -Format o) DUMP_RESULT pid=$($p.ProcessId) tool=$($result.Tool) success=$($result.Success) file=$($result.DumpFile)" | Add-Content $summaryFile

        # Mark as dumped regardless of success - we don't want to spam dumps every poll if the tool is broken
        [void]$alreadyDumped.Add([int]$p.ProcessId)

        # Optionally kill the candidate after dumping so the wrapped exe exits promptly and the
        # surrounding ADO task gets a chance to publish the dump artifact before the job timeout.
        # Only do this if the dump itself succeeded -- otherwise we'd lose the hang evidence by
        # killing a process we couldn't capture.
        if ($KillAfterDump -and $result.Success) {
            try {
                Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop
                "$(Get-Date -Format o) KILLED_AFTER_DUMP pid=$($p.ProcessId)" | Add-Content $summaryFile
            }
            catch {
                "$(Get-Date -Format o) KILL_AFTER_DUMP_FAILED pid=$($p.ProcessId) err=$($_.Exception.Message)" | Add-Content $summaryFile
            }
        }
    }
}
