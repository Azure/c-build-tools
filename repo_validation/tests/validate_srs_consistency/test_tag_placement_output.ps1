# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Test helper: Runs repo_validator srs_consistency check and verifies that tag placement
# violation output includes file names.

param(
    [Parameter(Mandatory=$true)]
    [string]$ValidatorPath,

    [Parameter(Mandatory=$true)]
    [string]$FixtureRoot,

    [Parameter(Mandatory=$true)]
    [string]$ExpectedFileNames
)

$ErrorActionPreference = "Stop"

# Split comma-separated file names into array
$fileNames = $ExpectedFileNames -split ","

# Run the validator as a subprocess to capture output
$output = & $ValidatorPath --repo-root $FixtureRoot --check srs_consistency 2>&1 | Out-String

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
