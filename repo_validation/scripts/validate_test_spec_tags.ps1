# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS
    Validates that unit test functions are tagged with at least one SRS spec tag.

.DESCRIPTION
    This script checks all unit test files (*_ut.c) to ensure that each TEST_FUNCTION
    is tagged with at least one Tests_SRS_* specification tag in a comment immediately
    preceding the test function.
    
    The expected pattern is:
      /*Tests_SRS_MODULE_XX_YYY: [ description ]*/
      TEST_FUNCTION(test_name)
    
    Or using C++ style comments:
      // Tests_SRS_MODULE_XX_YYY: [ description ]
      TEST_FUNCTION(test_name)
    
    Multiple Tests_SRS_ tags can precede a single TEST_FUNCTION.
    
    The script automatically excludes dependency directories to avoid validating third-party code.
    
    Lines with "// no-srs" or "/* no-srs */" comments at the end of TEST_FUNCTION will be ignored
    by the validation, allowing intentional exemption from tagging requirements.
    
    When the -Fix switch is provided, the script will NOT automatically fix missing tags
    as determining which specification requirements a test covers requires human analysis.
    The script will only report violations.

.PARAMETER RepoRoot
    The root directory of the repository to validate.

.PARAMETER ExcludeFolders
    Comma-separated list of additional folders to exclude from validation.

.PARAMETER Fix
    This parameter is accepted for interface compatibility but does not perform any fixes.
    Fixing missing spec tags requires human analysis to determine which requirements are tested.

.EXAMPLE
    .\validate_test_spec_tags.ps1 -RepoRoot "C:\repo"
    
    Validates all unit test files and reports test functions missing spec tags.

.EXAMPLE
    .\validate_test_spec_tags.ps1 -RepoRoot "C:\repo" -ExcludeFolders "deps,cmake,external"
    
    Validates with additional folder exclusions.

.NOTES
    Returns exit code 0 if all test functions have spec tags, 1 if validation fails.
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

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Unit Test Spec Tag Validation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Repository Root: $RepoRoot" -ForegroundColor White
Write-Host "Fix Mode: $($Fix.IsPresent) (Note: Fix mode is not supported for this validation)" -ForegroundColor White
Write-Host ""

if ($Fix.IsPresent) {
    Write-Host "[INFO] The -Fix option does not automatically fix missing spec tags." -ForegroundColor Yellow
    Write-Host "[INFO] Determining which specification requirements a test covers requires human analysis." -ForegroundColor Yellow
    Write-Host ""
}

# Define file pattern for unit tests
$testPattern = "*_ut.c"

# Parse excluded directories (default: deps, cmake)
$excludeDirs = $ExcludeFolders -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

Write-Host "Excluded directories: $($excludeDirs -join ', ')" -ForegroundColor White
Write-Host ""

# Initialize counters
$totalFiles = 0
$totalTestFunctions = 0
$testsWithTags = 0
$testsWithoutTags = @()
$skippedFiles = 0
$exemptedTests = 0

# Get all unit test files in the repository
Write-Host "Searching for unit test files..." -ForegroundColor White
$allFiles = Get-ChildItem -Path $RepoRoot -Recurse -Filter $testPattern -ErrorAction SilentlyContinue

Write-Host "Found $($allFiles.Count) unit test files to check" -ForegroundColor White
Write-Host ""

foreach ($file in $allFiles) {
    # Check if file should be excluded
    $relativePath = $file.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
    $isExcluded = $false
    
    foreach ($excludeDir in $excludeDirs) {
        # Check both path separator types for compatibility
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
        $content = Get-Content -Path $file.FullName -ErrorAction Stop
    }
    catch {
        Write-Host "  [WARN] Cannot read file: $($file.FullName)" -ForegroundColor Yellow
        continue
    }
    
    # Skip files that are empty
    if ($content.Count -eq 0) {
        continue
    }
    
    # Find all TEST_FUNCTION declarations and check for preceding spec tags
    for ($i = 0; $i -lt $content.Count; $i++) {
        $line = $content[$i]
        
        # Check for TEST_FUNCTION declaration
        if ($line -match '^\s*TEST_FUNCTION\s*\(') {
            $totalTestFunctions++
            
            # Extract the test function name for reporting
            $testName = ""
            if ($line -match 'TEST_FUNCTION\s*\(\s*([^\)]+)\s*\)') {
                $testName = $matches[1].Trim()
            }
            
            # Check if line has // no-srs or /* no-srs */ exemption (case-insensitive)
            if ($line -match '(?i)(//\s*no-srs|/\*\s*no-srs\s*\*/)') {
                $exemptedTests++
                $testsWithTags++  # Count as having tags since it's exempted
                continue
            }
            
            # Look backwards for Tests_SRS_ tags
            # We need to find at least one Tests_SRS_ tag in the comments preceding this TEST_FUNCTION
            # The tags should be in comments immediately before the TEST_FUNCTION (possibly spanning multiple lines)
            
            $foundSpecTag = $false
            $searchIndex = $i - 1
            
            # Search backwards through preceding lines looking for spec tags
            # Continue while we find comments, blank lines, or spec tags
            while ($searchIndex -ge 0) {
                $prevLine = $content[$searchIndex]
                
                # Check if this line contains a Tests_SRS_ tag
                if ($prevLine -match 'Tests_SRS_[A-Z0-9_]+_\d{2}_\d{3}') {
                    $foundSpecTag = $true
                }
                
                # If the line is a blank line, continue searching
                if ($prevLine -match '^\s*$') {
                    $searchIndex--
                    continue
                }
                
                # If the line is a C-style comment (/* ... */ or part of multi-line comment)
                # or C++ style comment (// ...)
                # These patterns indicate we're still in the "comment block" area before the test
                if ($prevLine -match '^\s*/\*' -or 
                    $prevLine -match '\*/\s*$' -or 
                    $prevLine -match '^\s*\*' -or
                    $prevLine -match '^\s*//') {
                    $searchIndex--
                    continue
                }
                
                # If we hit something else (like a closing brace, code, etc.), stop searching
                break
            }
            
            if ($foundSpecTag) {
                $testsWithTags++
            }
            else {
                $lineNumber = $i + 1  # Convert to 1-based line number
                $testsWithoutTags += [PSCustomObject]@{
                    FilePath = $relativePath
                    FullPath = $file.FullName
                    LineNumber = $lineNumber
                    TestName = $testName
                }
            }
        }
    }
}

# Report results
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Validation Results" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Files checked: $totalFiles" -ForegroundColor White
Write-Host "Files skipped (excluded): $skippedFiles" -ForegroundColor White
Write-Host "Total TEST_FUNCTION declarations: $totalTestFunctions" -ForegroundColor White
Write-Host "Tests with spec tags: $testsWithTags" -ForegroundColor Green
Write-Host "Tests exempted (no-srs): $exemptedTests" -ForegroundColor Yellow
Write-Host "Tests missing spec tags: $($testsWithoutTags.Count)" -ForegroundColor $(if ($testsWithoutTags.Count -gt 0) { "Red" } else { "Green" })
Write-Host ""

if ($testsWithoutTags.Count -gt 0) {
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "TEST FUNCTIONS MISSING SPEC TAGS" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Each TEST_FUNCTION should be preceded by at least one Tests_SRS_* specification tag." -ForegroundColor Yellow
    Write-Host "Example:" -ForegroundColor Yellow
    Write-Host '  /*Tests_SRS_MODULE_01_001: [ Description of requirement ]*/' -ForegroundColor Gray
    Write-Host '  TEST_FUNCTION(test_name)' -ForegroundColor Gray
    Write-Host ""
    Write-Host "To exempt a test from this requirement, add '// no-srs' to the TEST_FUNCTION line:" -ForegroundColor Yellow
    Write-Host '  TEST_FUNCTION(test_name) // no-srs' -ForegroundColor Gray
    Write-Host ""
    
    foreach ($violation in $testsWithoutTags) {
        Write-Host "  $($violation.FilePath):$($violation.LineNumber)" -ForegroundColor Red
        Write-Host "    TEST_FUNCTION($($violation.TestName))" -ForegroundColor White
    }
    
    Write-Host ""
    Write-Host "[FAILED] $($testsWithoutTags.Count) test function(s) are missing spec tags." -ForegroundColor Red
    Write-Host "Please add appropriate Tests_SRS_* tags before each test function," -ForegroundColor Red
    Write-Host "or add '// no-srs' to exempt a test from this requirement." -ForegroundColor Red
    exit 1
}

Write-Host "[PASSED] All $totalTestFunctions test function(s) have spec tags or are exempted." -ForegroundColor Green
exit 0
