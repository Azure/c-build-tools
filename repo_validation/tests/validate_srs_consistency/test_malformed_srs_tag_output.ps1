# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Test helper: Runs validate_srs_consistency.ps1 and verifies that malformed SRS tag
# detection output includes the expected tag and file name.

param(
    [Parameter(Mandatory=$true)]
    [string]$ScriptPath,

    [Parameter(Mandatory=$true)]
    [string]$FixtureRoot,

    [Parameter(Mandatory=$true)]
    [string]$ExpectedTag
)

$ErrorActionPreference = "Stop"

# Run the validation script as a subprocess to capture Write-Host output
$output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -RepoRoot $FixtureRoot 2>&1 | Out-String

$exitCode = $LASTEXITCODE

if ($exitCode -eq 0) {
    Write-Host "[FAIL] Script exited with code 0, expected failure (exit code 1)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Captured output:"
    Write-Host $output
    exit 1
}

# Verify that the malformed tag was reported
if ($output -notmatch [regex]::Escape($ExpectedTag)) {
    Write-Host "[FAIL] Output missing expected malformed tag '$ExpectedTag'" -ForegroundColor Red
    Write-Host ""
    Write-Host "Captured output:"
    Write-Host $output
    exit 1
}

# Verify the "Malformed SRS Tags" section appears
if ($output -notmatch "Malformed SRS Tags") {
    Write-Host "[FAIL] Output missing 'Malformed SRS Tags' section header" -ForegroundColor Red
    Write-Host ""
    Write-Host "Captured output:"
    Write-Host $output
    exit 1
}

Write-Host "[PASS] Malformed SRS tag detection correctly identifies '$ExpectedTag'" -ForegroundColor Green
exit 0
