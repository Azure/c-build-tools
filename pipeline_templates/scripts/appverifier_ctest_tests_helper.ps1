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

  .PARAMETER appverifPath
  Optional explicit path to appverif.exe. When omitted, the script falls back (in order) to the
  APPVERIF_PATH env var, the ADO-injected APPVERIFPATH env var (from the pipeline variable
  emitted by discover_native_tools.yml), and finally the system PATH. If none resolve to an
  existing file the script logs a warning and exits 0 (preserves existing skip-when-missing
  behavior on build pools that do not have AppVerifier installed, e.g. legacy ARM64 pools).

  .PARAMETER ctestPath
  Optional explicit path to ctest.exe (used in the -on path to enumerate tests). When omitted,
  the script falls back to the ADO-injected CTESTPATH env var (from discover_native_tools.yml)
  and finally to a hardcoded VS 2022 Enterprise location. If ctest cannot be found in -on mode
  the script fails loudly so the AppVerifier gate cannot silently enable zero binaries.

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
    [Parameter()][string]$appverifPath = "",
    [Parameter()][string]$ctestPath = ""
)

# Treat unresolved ADO macro literals (e.g. "$(appverifPath)" passed when the pipeline
# variable was never set) and empty/whitespace strings as "not provided".
function Resolve-OptionalPath
{
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    if ($Value -match '^\$\(.+\)$') { return $null }
    return $Value
}

# Resolve appverif.exe in priority order:
#   1. -appverifPath parameter (passed by run_ctests_with_appverifier.yml /
#      disable_appverifier.yml from the $(appverifPath) discovered by discover_native_tools.yml)
#   2. APPVERIF_PATH env var (manual override)
#   3. APPVERIFPATH env var (ADO-injected from pipeline variable 'appverifPath')
#   4. Get-Command appverif.exe (PATH lookup; legacy build pools)
$resolvedAppverifPath = Resolve-OptionalPath $appverifPath
if (-not $resolvedAppverifPath) { $resolvedAppverifPath = Resolve-OptionalPath $env:APPVERIF_PATH }
if (-not $resolvedAppverifPath) { $resolvedAppverifPath = Resolve-OptionalPath $env:APPVERIFPATH }
if (-not $resolvedAppverifPath)
{
    $appverifCmd = Get-Command appverif.exe -ErrorAction SilentlyContinue
    if ($appverifCmd) { $resolvedAppverifPath = $appverifCmd.Source }
}
if ($resolvedAppverifPath -and -not (Test-Path $resolvedAppverifPath))
{
    Write-Host "##vso[task.logissue type=warning]Resolved AppVerifier path '$resolvedAppverifPath' does not exist; ignoring."
    $resolvedAppverifPath = $null
}

if (-not $resolvedAppverifPath) {
    # Surface as an ADO warning so the build summary makes the silent skip visible.
    Write-Host "##vso[task.logissue type=warning]Application Verifier (appverif.exe) is not available on this machine. AppVerifier steps will be skipped."
    Write-Output "Application Verifier (appverif) is not installed on this machine. Skipping."
    exit 0
}
Write-Output "Using Application Verifier at: $resolvedAppverifPath"

if ($on)
{
    # Resolve ctest.exe in priority order:
    #   1. -ctestPath parameter (passed from $(ctestPath) discovered by discover_native_tools.yml)
    #   2. CTESTPATH env var (ADO-injected from pipeline variable 'ctestPath')
    #   3. Hardcoded VS 2022 Enterprise path (legacy fallback)
    $resolvedCtestPath = Resolve-OptionalPath $ctestPath
    if (-not $resolvedCtestPath) { $resolvedCtestPath = Resolve-OptionalPath $env:CTESTPATH }
    if (-not $resolvedCtestPath)
    {
        $resolvedCtestPath = "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\ctest.exe"
    }
    if (-not (Test-Path $resolvedCtestPath))
    {
        # In -on mode this MUST fail loudly: silently enumerating zero tests would leave the
        # AppVerifier gate green while no binaries were actually instrumented.
        Write-Host "##vso[task.logissue type=error]ctest.exe not found at '$resolvedCtestPath'. Cannot enumerate tests for AppVerifier instrumentation."
        exit 1
    }
    Write-Output "Using CTest at: $resolvedCtestPath"

    $allTests = & $resolvedCtestPath -N $ctestArgs.Split()
    $testsArray = $allTests.Split([Environment]::NewLine,[Stringsplitoptions]::RemoveEmptyEntries).trim()

    foreach ($t in $testsArray)
    {
        Write-Output "Parsing line: $t"
        # Filter only lines like "Test #42: test_name_ut"
        if ($t -match ':' -and $t -match '#')
        {
            $testName = ($t -split ":")[1].Trim()
            $exeName = "$($testName)$($binaryNameSuffix)"
            Write-Output "Enabling appverifier for $exeName"
            & $resolvedAppverifPath -enable $appVerifierEnable.Split() -for $exeName -with exceptiononstop=true $appVerifierAdditionalProperties.Split()
        }
    }
}
else
{
    Write-Output "Disabling all appverifier settings"
    & $resolvedAppverifPath -disable * -for *
}
