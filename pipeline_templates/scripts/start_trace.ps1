#Copyright (C) Microsoft Corporation. All rights reserved.

<#
  .SYNOPSIS
  Starts a logman trace

  .DESCRIPTION
  This script stops and deletes a previously existing trace with the same name and then
  starts a specifically named (testgate) logman trace used by the gated build to collect ETW events

  .PARAMETER TraceFile
  Specifies the trace file for event collection

  .EXAMPLE
  PS> .\start_trace.ps1 -TraceFile "d:\x\log.etl"

  Description:
  ---------------------------------------
  This script will start a predefined logman trace
#>

Param(
    $TraceFile = ".\x.etl",
    $ProviderFile = "providers.txt"
)

try
{
    # print the current state first
    Write-Output "Current logman state ..."
    logman

    . ".\run_awdump.ps1" #this imports the Run-Awdump function

    # then stop or reboot machine if it doesn't complete in 10 seconds
    Write-Output "Stopping any old trace (or dump logman and kernel) ..."

    $timeout = 10 # 10 seconds

    # Run logman stop in a job 
    # note: using timers and callbacks did not work as timers execute on the same thread, while jobs execute as background.
    
    $job = Start-Job -ScriptBlock {
        logman stop testgate
    }

    # Wait for the job to complete or timeout
    $job | Wait-Job -Timeout $timeout

    # Check if the job is still running
    if ($job.State -eq 'Running') {
        # Job is still running, handle the timeout
        Write-Host "Timeout reached. Will do:`nRun-Awdump -ProcessName `"`logman.exe`"` `nRun-AwdumpKernel`nand then restart the machine! Expect the build to (eventually) fail... "
        Run-Awdump -ProcessName "logman.exe"
        Write-Host "Running Run-AwdumpKernel to produce a kernel dump"
        Run-AwdumpKernel
        Write-Host "Dumps (logman and kernel exist). Will wait 5 minutes [because it might take time to upload the dump] then restart the machine"
        Start-Sleep -Seconds 300
        Write-Host "Restarting the machine now..."
        Restart-Computer -Force
    } else {
        # Job completed, clean up
        Remove-Job -Job $job
        Write-Output "Logman stopped naturally."
    }
}
catch
{
    Write-Output "An error occurred: $_"
}

Write-Output "Deleting any old trace ..."

try
{
    logman delete testgate
}
catch
{
    Write-Warning "logman delete testgate failed"
}

Write-Output "Creating trace ..."

logman create trace testgate -pf "$ProviderFile" -o "$TraceFile" -v mmddhhmm -ow -max 256 -nb 16 256 -bs 64 -f bin -ct perf -cnf 60:00

Write-Output "Starting trace ..."

logman start testgate

Write-Output "Logman state is ..."

logman

Write-Output "Everything is OK"
