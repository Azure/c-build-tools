# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS
    Validates that Codes_SRS_ tags only appear in production code and Tests_SRS_ tags only appear in test files.

.DESCRIPTION
    This script checks that SRS tag placement follows the correct convention:
    - Codes_SRS_ tags must only appear in production code (.c files that are NOT test files)
    - Tests_SRS_ tags must only appear in test files (*_ut.c, *_int.c, or files in test directories)
    
    The script automatically excludes dependency directories to avoid validating third-party code.

.PARAMETER RepoRoot
    The root directory of the repository to validate.

.PARAMETER ExcludeFolders
    Comma-separated list of additional folders to exclude from validation.

.PARAMETER Fix
    This parameter is accepted for interface compatibility but does not perform any fixes.
    Fixing misplaced SRS tags requires human analysis to determine the correct placement.

.EXAMPLE
    .\validate_srs_tag_placement.ps1 -RepoRoot "C:\repo"
    
    Validates all source files and reports misplaced SRS tags.

.EXAMPLE
    .\validate_srs_tag_placement.ps1 -RepoRoot "C:\repo" -ExcludeFolders "deps,cmake,external"
    
    Validates with additional folder exclusions.

.NOTES
    Returns exit code 0 if all SRS tags are correctly placed, 1 if validation fails.
    Dependencies in deps/ and cmake/ directories are automatically excluded.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$RepoRoot,
    
    [Parameter(Mandatory=$false)]
    [string]$ExcludeFolders = "deps,cmake",
    
    [Parameter(Mandatory=$false)]
    [switch]$Fix
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Resolve RepoRoot to an absolute path
$RepoRoot = (Resolve-Path $RepoRoot).Path

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "SRS Tag Placement Validation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Repository Root: $RepoRoot" -ForegroundColor White
Write-Host "Fix Mode: $($Fix.IsPresent) (Note: Fix mode is not supported for this validation)" -ForegroundColor White
Write-Host ""

if ($Fix.IsPresent) {
    Write-Host "[INFO] The -Fix option does not automatically fix misplaced SRS tags." -ForegroundColor Yellow
    Write-Host "[INFO] Determining correct tag placement requires human analysis." -ForegroundColor Yellow
    Write-Host ""
}

# Parse excluded directories (default: deps, cmake)
$excludeDirs = $ExcludeFolders -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

Write-Host "Excluded directories: $($excludeDirs -join ', ')" -ForegroundColor White
Write-Host ""

# Initialize counters
$totalFiles = 0
$skippedFiles = 0
$violations = @()

# Patterns
$codesSrsPattern = '(?:\/\*|\/\/)\s*Codes_SRS_'
$testsSrsPattern = '(?:\/\*|\/\/)\s*Tests_SRS_'

# Determine if a file is a test file based on naming convention and path
function Test-IsTestFile {
    param([string]$FilePath)
    
    $fileName = [System.IO.Path]::GetFileName($FilePath)
    
    # Check file name patterns
    if ($fileName -match '_ut\.c$' -or $fileName -match '_int\.c$' -or $fileName -match '_it\.c$') {
        return $true
    }
    
    # Check if file is in a test directory
    if ($FilePath -match '[/\\]tests?[/\\]' -or $FilePath -match '[/\\]_ut[/\\]' -or $FilePath -match '[/\\]_int[/\\]') {
        # But exclude reals implementations (they are production-like code used in tests)
        if ($FilePath -match '[/\\]reals[/\\]') {
            return $false
        }
        # Check if the file name suggests it's a test file
        if ($fileName -match '_ut\.c$' -or $fileName -match '_int\.c$') {
            return $true
        }
    }
    
    return $false
}

# Get all .c files in the repository
Write-Host "Searching for C source files..." -ForegroundColor White
$allFiles = Get-ChildItem -Path $RepoRoot -Recurse -Filter "*.c" -ErrorAction SilentlyContinue

Write-Host "Found $($allFiles.Count) C source files" -ForegroundColor White
Write-Host ""

foreach ($file in $allFiles) {
    # Check if file should be excluded
    $relativePath = $file.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
    $isExcluded = $false
    
    foreach ($excludeDir in $excludeDirs) {
        if ($relativePath -like "$excludeDir\*" -or $relativePath -like "$excludeDir/*") {
            $isExcluded = $true
            $skippedFiles++
            break
        }
    }
    
    if ($isExcluded) {
        continue
    }
    
    $totalFiles++
    
    # Read file content
    try {
        $lines = Get-Content -Path $file.FullName -ErrorAction Stop
    }
    catch {
        Write-Host "  [WARN] Cannot read file: $($file.FullName)" -ForegroundColor Yellow
        continue
    }
    
    $isTestFile = Test-IsTestFile -FilePath $file.FullName
    
    $lineNumber = 0
    foreach ($line in $lines) {
        $lineNumber++
        
        if ($isTestFile) {
            # Test files should NOT have Codes_SRS_ tags
            if ($line -match $codesSrsPattern) {
                $violations += [PSCustomObject]@{
                    FilePath = $relativePath
                    LineNumber = $lineNumber
                    Content = $line.Trim()
                    Violation = "Codes_SRS_ tag found in test file (should use Tests_SRS_)"
                }
            }
        }
        else {
            # Production files should NOT have Tests_SRS_ tags
            if ($line -match $testsSrsPattern) {
                $violations += [PSCustomObject]@{
                    FilePath = $relativePath
                    LineNumber = $lineNumber
                    Content = $line.Trim()
                    Violation = "Tests_SRS_ tag found in production file (should use Codes_SRS_)"
                }
            }
        }
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Validation Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total C source files checked: $totalFiles" -ForegroundColor White
Write-Host "Files skipped (excluded directories): $skippedFiles" -ForegroundColor White

if ($violations.Count -gt 0) {
    Write-Host "Violations found: $($violations.Count)" -ForegroundColor Red
    Write-Host ""
    
    # Group violations by type
    $codesInTests = $violations | Where-Object { $_.Violation -like "Codes_SRS_*" }
    $testsInProd = $violations | Where-Object { $_.Violation -like "Tests_SRS_*" }
    
    if ($codesInTests.Count -gt 0) {
        Write-Host "Codes_SRS_ tags in test files ($($codesInTests.Count) violations):" -ForegroundColor Yellow
        foreach ($v in $codesInTests) {
            Write-Host "  $($v.FilePath):$($v.LineNumber): $($v.Content)" -ForegroundColor White
        }
        Write-Host ""
    }
    
    if ($testsInProd.Count -gt 0) {
        Write-Host "Tests_SRS_ tags in production files ($($testsInProd.Count) violations):" -ForegroundColor Yellow
        foreach ($v in $testsInProd) {
            Write-Host "  $($v.FilePath):$($v.LineNumber): $($v.Content)" -ForegroundColor White
        }
        Write-Host ""
    }
    
    Write-Host "Convention:" -ForegroundColor Cyan
    Write-Host "  - Codes_SRS_ tags belong exclusively in production code (.c files)" -ForegroundColor Cyan
    Write-Host "  - Tests_SRS_ tags belong exclusively in test files (*_ut.c, *_int.c)" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host "[VALIDATION FAILED]" -ForegroundColor Red
    exit 1
}
else {
    Write-Host "Violations found: 0" -ForegroundColor Green
    Write-Host ""
    Write-Host "[VALIDATION PASSED]" -ForegroundColor Green
    exit 0
}
