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

Write-Output "Stopping any old trace ..."

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
