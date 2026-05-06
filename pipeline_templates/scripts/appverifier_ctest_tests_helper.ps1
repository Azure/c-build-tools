#Copyright(C) Microsoft Corporation.All rights reserved.

<#
  .SYNOPSIS
  Enable or disable Application Verifier for binaries listed by ctest.

  .DESCRIPTION
  This can enable Application Verifier for all tests (with optional arguments to filter tests) from ctest.
  An optional argument can also be provided to select which app verifier options are used

  .PARAMETER on
  When set, this enables Application Verifier for the tests listed by ctest, otherwise, this disables Application Verifier for all images

  .PARAMETER appVerifierEnable
  Select which Application Verifier layers to enable. By default this enables: exceptions handles heaps leak memory threadpool tls

  .PARAMETER appVerifierAdditionalProperties
  Select additional Application Verifier properties which will be passed to "-with" on the command line.
  See: https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/application-verifier-testing-applications#using-the-command-line

  .PARAMETER ctestArgs
  Arguments to pass to ctest. By default ctest is run with "-N" which will just list all tests. This option may be used to filter the tests

  .PARAMETER binaryNameSuffix
  Suffix for binary names of tests. E.g. if ctest returns some test names like foo, bar, and the binaries are foo_x.exe and bar_x.exe then this should be "_x.exe"

  .INPUTS
  None. You cannot pipe objects to appverifier_ctest_tests_helper.ps1.

  .OUTPUTS
  None. appverifier_ctest_tests_helper.ps1 does not generate any output.

  .EXAMPLE
  PS> .\appverifier_ctest_tests_helper.ps1
  By default, disables app verifier for all processes

  PS> .\appverifier_ctest_tests_helper.ps1 -on
  Enables app verifier for all test binaries found in ctest
#>

param(
    [Parameter()][switch]$on,
    [Parameter()][string]$appVerifierEnable = "exceptions handles heaps leak memory threadpool tls",
    [Parameter()][string]$appVerifierAdditionalProperties = "",
    [Parameter()][string]$ctestArgs = "",
    [Parameter()][string]$binaryNameSuffix,
    # Path to appverif.exe. Normally set by discover_native_tools.yml as the
    # $(appverifPath) pipeline variable. If empty / unresolved / pointing at a
    # non-existent file, the script probes PATH and known install locations as a
    # fallback so it remains usable when invoked outside the discover-tools flow.
    [Parameter()][string]$appverifPath = ""
)

# Resolve appverif.exe location: caller-provided path > PATH > known install locations.
# Some agent images install Application Verifier outside of PATH (the standalone
# installer drops it under "Program Files (x86)\Application Verifier" rather than
# System32), so PATH alone is not sufficient.
$appverifExe = $null
if ($appverifPath -and (Test-Path $appverifPath)) {
    $appverifExe = $appverifPath
} else {
    $appverifFromPath = Get-Command appverif.exe -ErrorAction SilentlyContinue
    if ($appverifFromPath) {
        $appverifExe = $appverifFromPath.Source
    } else {
        $candidates = @(
            (Join-Path $env:windir 'System32\appverif.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Application Verifier\appverif.exe'),
            (Join-Path $env:ProgramFiles 'Application Verifier\appverif.exe')
        ) | Where-Object { $_ -and (Test-Path $_) }
        if ($candidates.Count -gt 0) { $appverifExe = $candidates[0] }
    }
}

if (-not $appverifExe) {
    Write-Output "Application Verifier (appverif.exe) not found via PATH or known install locations. Skipping."
    exit 0
}

Write-Output "Using Application Verifier at: $appverifExe"

if ($on)
{
    $allTests = & "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\ctest.exe" -N $ctestArgs.Split()
    $testsArray = $allTests.Split([Environment]::NewLine,[Stringsplitoptions]::RemoveEmptyEntries).trim()

    foreach ($t in $testsArray)
    {
        Write-Output "Parsing line: $t"
        # Filter only lines like "Test #42: test_name_ut"
        if ($t -match ':' -and $t -match '#')
        {
            $testName = ($t -split ":")[1].Trim()
            $exeName = "$($testName)$($binaryNameSuffix)"
            if ($on)
            {
                Write-Output "Enabling appverifier for $exeName"
                & $appverifExe -enable $appVerifierEnable.Split() -for $exeName -with exceptiononstop=true $appVerifierAdditionalProperties.Split()
            }
        }
    }
}
else
{
    Write-Output "Disabling all appverifier settings"
    & $appverifExe -disable * -for *
}
