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
    logman
    # then stop
    logman stop testgate
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
