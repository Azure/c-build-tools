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

  .INPUTS
  None. You cannot pipe objects to restore_data.ps1.

  .OUTPUTS
  None. restore_data.ps1 does not generate any output.

  .EXAMPLE
  PS> .\recover_blocks.ps1
#>

param(
    [Parameter()][switch]$on,
    [Parameter()][string]$appVerifierEnable = "exceptions handles heaps leak memory threadpool tls",
    [Parameter()][string]$appVerifierAdditionalProperties = "",
    [Parameter()][string]$ctestArgs = "",
)

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
            $exeName = "$($testName)_exe_ebs.exe"
            if ($on)
            {
                Write-Output "Enabling appverifier for $exeName"
                & appverif -enable $appVerifierEnable.Split() -for $exeName -with exceptiononstop=true $appVerifierAdditionalProperties.Split()
            }
        }
    }
}
else
{
    Write-Output "Disabling all appverifier settings"
    & appverif -disable * -for *
}
