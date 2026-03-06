# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Test helper: Runs validate_srs_consistency.ps1 and verifies that tag placement
# violation output includes file names.

param(
    [Parameter(Mandatory=$true)]
    [string]$ScriptPath,

    [Parameter(Mandatory=$true)]
    [string]$FixtureRoot,

    [Parameter(Mandatory=$true)]
    [string]$ExpectedFileNames
)

$ErrorActionPreference = "Stop"

# Split comma-separated file names into array
$fileNames = $ExpectedFileNames -split ","

# Run the validation script as a subprocess to capture Write-Host output
$output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -RepoRoot $FixtureRoot 2>&1 | Out-String

$failed = $false
foreach ($fileName in $fileNames) {
    $pattern = [regex]::Escape($fileName) + ":"
    if ($output -notmatch $pattern) {
        Write-Host "[FAIL] Output missing file name '$fileName'" -ForegroundColor Red
        $failed = $true
    }
}

if ($failed) {
    Write-Host ""
    Write-Host "Captured output:"
    Write-Host $output
    exit 1
}

Write-Host "[PASS] Tag placement violation output includes expected file names" -ForegroundColor Green
exit 0
