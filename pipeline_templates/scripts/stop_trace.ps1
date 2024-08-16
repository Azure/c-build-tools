#Copyright (C) Microsoft Corporation. All rights reserved.

<#
  .SYNOPSIS
  Stops the logman trace

  .DESCRIPTION
  This script stops a specific logman trace used by the gated build to collect ETW events

  .EXAMPLE
  PS> .\stop_trace.ps1

  Description:
  ---------------------------------------
  This script will stop and delete the logman trace session
#>

Write-Output "Stopping trace ..."

try
{
    # print the current state first
    Write-Output "Current logman state ..."
    logman

    . ".\run_awdump.ps1" #this imports the Run-Awdump function

    # then stop or reboot machine if it doesn't complete in 10 seconds
    Write-Output "Stopping any old trace (or dump logman and kernel) ..."

    $timeout = 10000 # 10 seconds

    # Setup a timer
    $timer = New-Object System.Timers.Timer
    $timer.Interval = $timeout
    $timer.AutoReset = $false

    # Define the action to take when the timer elapses
    $timerEvent = Register-ObjectEvent -InputObject $timer -EventName Elapsed -Action {
        Write-Host "Timeout reached. Will awdump logman... Restarting the machine! Expect the build to (eventually) fail... "
        Run-Awdump -ProcessName "logman.exe"
        Write-Host "Running Run-AwdumpKernel to produce a kernel dump"
        Run-AwdumpKernel
        Write-Host "Dumps (logman and kernel exist). Will wait 5 minutes [because it might take time to upload the dump] then restart the machine"
        Start-Sleep -Seconds 300
        Write-Host "Restarting the machine now..."
        Restart-Computer -Force
    }

    # Start the timer
    $timer.Start()

    # timer watches over logman stop... 
    logman stop testgate

    # If we get here, that means the event was not fired, that can only mean that logman stopped naturally. Undo the watchdog.
    Unregister-Event -SourceIdentifier $timerEvent.Name
    $timer.Dispose()
}
catch
{
    Write-Warning "logman stop testgate failed"
}

Write-Output "Deleting trace ..."

try
{
    logman delete testgate
}
catch
{
    Write-Warning "logman delete testgate failed"
}

Write-Output "Logman state is ..."

logman

Write-Output "Everything is OK"
