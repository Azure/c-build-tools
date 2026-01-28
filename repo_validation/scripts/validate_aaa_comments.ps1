# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS
    Validates that test functions contain AAA (Arrange, Act, Assert) comments.

.DESCRIPTION
    This script checks all unit test files (*_ut.c) and integration test files (*_int.c)
    to ensure that test functions (TEST_FUNCTION, TEST_METHOD, CTEST_FUNCTION) contain
    AAA comments in the correct order: Arrange, Act, Assert.
    
    The script accepts various comment styles:
      - // arrange, // act, // assert
      - /// arrange, /// act, /// assert
      - /* arrange */, /* act */, /* assert */
    
    Comments are case-insensitive.
    
    The script automatically excludes dependency directories to avoid checking third-party code.
    
    Test functions can be exempted from this validation by adding '// no-aaa' or '/* no-aaa */'
    to the TEST_FUNCTION line.
    
    AAA comments can also be located in helper functions that are called by the test function.
    The script will check functions defined in the same file for the missing AAA comments.

.PARAMETER RepoRoot
    The root directory of the repository to validate.

.PARAMETER ExcludeFolders
    Comma-separated list of additional folders to exclude from validation.

.PARAMETER Fix
    This parameter is accepted for compatibility but has no effect.
    AAA comments cannot be automatically added as they require understanding of the test logic.

.EXAMPLE
    .\validate_aaa_comments.ps1 -RepoRoot "C:\repo"
    
    Validates all test files and reports test functions missing AAA comments.

.EXAMPLE
    .\validate_aaa_comments.ps1 -RepoRoot "C:\repo" -ExcludeFolders "deps,cmake,external"
    
    Validates test files excluding specified directories.

.NOTES
    Returns exit code 0 if all test functions have proper AAA comments, 1 if validation fails.
    Dependencies in deps/ and cmake/ directories are automatically excluded by default.
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
Write-Host "AAA Comment Validation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Repository Root: $RepoRoot" -ForegroundColor White
Write-Host ""

if ($Fix) {
    Write-Host "[INFO] -Fix parameter was specified but this validation does not support auto-fix." -ForegroundColor Yellow
    Write-Host "       AAA comments require understanding of test logic and must be added manually." -ForegroundColor Yellow
    Write-Host ""
}

# Define file patterns to check (unit tests and integration tests)
$filePatterns = @("*_ut.c", "*_int.c")

# Parse excluded directories (default: deps, cmake)
$excludeDirs = $ExcludeFolders -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

Write-Host "Excluded directories: $($excludeDirs -join ', ')" -ForegroundColor White
Write-Host "File patterns: $($filePatterns -join ', ')" -ForegroundColor White
Write-Host ""

# Initialize counters
$totalFiles = 0
$totalTestFunctions = 0
$testFunctionsWithViolations = @()
$skippedFiles = 0
$exemptedTestFunctions = 0

# Regex patterns for test function declarations
$testFunctionPattern = '^\s*(TEST_FUNCTION|TEST_METHOD|CTEST_FUNCTION)\s*\(\s*(\w+)\s*\)'

# Regex pattern for AAA comments (case-insensitive)
# Matches: // arrange, /// arrange, /* arrange */, etc.
$arrangePattern = '(?i)(//+\s*arrange|/\*\s*arrange)'
$actPattern = '(?i)(//+\s*act|/\*\s*act)'
$assertPattern = '(?i)(//+\s*assert|/\*\s*assert)'

# Regex pattern for no-aaa exemption
$noAaaPattern = '(?i)(//\s*no-aaa|/\*\s*no-aaa)'

# Function to extract function body given the start position
function Get-FunctionBody {
    param(
        [string]$content,
        [int]$startIndex
    )
    
    # Find the opening brace
    $braceStart = $content.IndexOf('{', $startIndex)
    if ($braceStart -eq -1) {
        return $null
    }
    
    # Track nested braces
    $braceCount = 1
    $currentIndex = $braceStart + 1
    $contentLength = $content.Length
    
    while ($braceCount -gt 0 -and $currentIndex -lt $contentLength) {
        $char = $content[$currentIndex]
        
        # Skip string literals
        if ($char -eq '"') {
            $currentIndex++
            while ($currentIndex -lt $contentLength) {
                if ($content[$currentIndex] -eq '\') {
                    $currentIndex += 2  # Skip escaped character
                    continue
                }
                if ($content[$currentIndex] -eq '"') {
                    $currentIndex++
                    break
                }
                $currentIndex++
            }
            continue
        }
        
        # Skip character literals
        if ($char -eq "'") {
            $currentIndex++
            while ($currentIndex -lt $contentLength) {
                if ($content[$currentIndex] -eq '\') {
                    $currentIndex += 2  # Skip escaped character
                    continue
                }
                if ($content[$currentIndex] -eq "'") {
                    $currentIndex++
                    break
                }
                $currentIndex++
            }
            continue
        }
        
        # Skip single-line comments
        if ($char -eq '/' -and ($currentIndex + 1) -lt $contentLength -and $content[$currentIndex + 1] -eq '/') {
            while ($currentIndex -lt $contentLength -and $content[$currentIndex] -ne "`n") {
                $currentIndex++
            }
            continue
        }
        
        # Skip multi-line comments (but we still want to check for AAA in comments)
        # Actually, don't skip - we need to check comments for AAA patterns
        
        if ($char -eq '{') {
            $braceCount++
        }
        elseif ($char -eq '}') {
            $braceCount--
        }
        
        $currentIndex++
    }
    
    if ($braceCount -eq 0) {
        return $content.Substring($braceStart, $currentIndex - $braceStart)
    }
    
    return $null
}

# Function to extract all non-test function definitions from file content
function Get-HelperFunctions {
    param(
        [string]$content
    )
    
    $helpers = @{}
    
    # Pattern to match C function definitions (simplified)
    # Matches: return_type function_name(params) { ... }
    # Excludes TEST_FUNCTION, TEST_METHOD, CTEST_FUNCTION
    $functionDefPattern = '(?m)^[\w\s\*]+\s+(\w+)\s*\([^)]*\)\s*\{'
    
    $matches = [regex]::Matches($content, $functionDefPattern)
    
    foreach ($match in $matches) {
        $funcName = $match.Groups[1].Value
        
        # Skip test function macros
        if ($funcName -match '^(TEST_FUNCTION|TEST_METHOD|CTEST_FUNCTION)$') {
            continue
        }
        
        # Skip common non-function patterns
        if ($funcName -match '^(if|while|for|switch|else)$') {
            continue
        }
        
        $body = Get-FunctionBody -content $content -startIndex $match.Index
        if ($body) {
            $helpers[$funcName] = $body
        }
    }
    
    return $helpers
}

# Function to extract function calls from a code block
function Get-FunctionCalls {
    param(
        [string]$codeBlock
    )
    
    $calls = @()
    
    # Pattern to match function calls: function_name(
    $callPattern = '(?<!\w)(\w+)\s*\('
    
    $matches = [regex]::Matches($codeBlock, $callPattern)
    
    foreach ($match in $matches) {
        $funcName = $match.Groups[1].Value
        
        # Skip keywords and common macros
        if ($funcName -notmatch '^(if|while|for|switch|return|sizeof|typeof|ASSERT_\w+|STRICT_EXPECTED_CALL|EXPECTED_CALL|REGISTER_\w+|MU_\w+|TEST_\w+|MOCK_\w+|THANDLE_\w+)$') {
            $calls += $funcName
        }
    }
    
    return $calls | Select-Object -Unique
}

# Function to check AAA comments in code block
function Test-AAAComments {
    param(
        [string]$codeBlock,
        [hashtable]$helperFunctions,
        [int]$depth = 0
    )
    
    # Prevent infinite recursion
    if ($depth -gt 3) {
        return @{
            HasArrange = $false
            HasAct = $false
            HasAssert = $false
            ArrangePos = -1
            ActPos = -1
            AssertPos = -1
        }
    }
    
    $result = @{
        HasArrange = $false
        HasAct = $false
        HasAssert = $false
        ArrangePos = -1
        ActPos = -1
        AssertPos = -1
    }
    
    # Check for AAA comments in this block
    $arrangeMatch = [regex]::Match($codeBlock, $arrangePattern)
    $actMatch = [regex]::Match($codeBlock, $actPattern)
    $assertMatch = [regex]::Match($codeBlock, $assertPattern)
    
    if ($arrangeMatch.Success) {
        $result.HasArrange = $true
        $result.ArrangePos = $arrangeMatch.Index
    }
    
    if ($actMatch.Success) {
        $result.HasAct = $true
        $result.ActPos = $actMatch.Index
    }
    
    if ($assertMatch.Success) {
        $result.HasAssert = $true
        $result.AssertPos = $assertMatch.Index
    }
    
    # If all found, return early
    if ($result.HasArrange -and $result.HasAct -and $result.HasAssert) {
        return $result
    }
    
    # Check helper functions for missing comments
    $calls = Get-FunctionCalls -codeBlock $codeBlock
    
    foreach ($call in $calls) {
        if ($helperFunctions.ContainsKey($call)) {
            $helperBody = $helperFunctions[$call]
            $helperResult = Test-AAAComments -codeBlock $helperBody -helperFunctions $helperFunctions -depth ($depth + 1)
            
            if (-not $result.HasArrange -and $helperResult.HasArrange) {
                $result.HasArrange = $true
                $result.ArrangePos = 0  # Mark as found in helper
            }
            
            if (-not $result.HasAct -and $helperResult.HasAct) {
                $result.HasAct = $true
                $result.ActPos = 0  # Mark as found in helper
            }
            
            if (-not $result.HasAssert -and $helperResult.HasAssert) {
                $result.HasAssert = $true
                $result.AssertPos = 0  # Mark as found in helper
            }
            
            # If all found, return early
            if ($result.HasArrange -and $result.HasAct -and $result.HasAssert) {
                return $result
            }
        }
    }
    
    return $result
}

# Function to check AAA order
function Test-AAAOrder {
    param(
        [int]$arrangePos,
        [int]$actPos,
        [int]$assertPos
    )
    
    # If any position is 0, it was found in a helper function
    # In that case, we can't verify order, so assume it's correct
    if ($arrangePos -eq 0 -or $actPos -eq 0 -or $assertPos -eq 0) {
        return $true
    }
    
    # Check that arrange comes before act, and act comes before assert
    return ($arrangePos -lt $actPos) -and ($actPos -lt $assertPos)
}

# Function to get line number from position
function Get-LineNumber {
    param(
        [string]$content,
        [int]$position
    )
    
    $lineNumber = 1
    for ($i = 0; $i -lt $position -and $i -lt $content.Length; $i++) {
        if ($content[$i] -eq "`n") {
            $lineNumber++
        }
    }
    return $lineNumber
}

# Get all test files in the repository
Write-Host "Searching for test files..." -ForegroundColor White
$allFiles = @()
foreach ($pattern in $filePatterns) {
    $allFiles += Get-ChildItem -Path $RepoRoot -Recurse -Filter $pattern -ErrorAction SilentlyContinue
}

Write-Host "Found $($allFiles.Count) test files to check" -ForegroundColor White
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
        $content = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
    }
    catch {
        Write-Host "  [WARN] Cannot read file: $($file.FullName)" -ForegroundColor Yellow
        continue
    }
    
    # Skip files that are empty or null
    if ([string]::IsNullOrWhiteSpace($content)) {
        continue
    }
    
    # Get helper functions from this file
    $helperFunctions = Get-HelperFunctions -content $content
    
    # Find all test function declarations
    $testMatches = [regex]::Matches($content, $testFunctionPattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    
    foreach ($testMatch in $testMatches) {
        $totalTestFunctions++
        $testMacro = $testMatch.Groups[1].Value
        $testName = $testMatch.Groups[2].Value
        $testLine = Get-LineNumber -content $content -position $testMatch.Index
        
        # Get the full line to check for no-aaa exemption
        $lineStart = $content.LastIndexOf("`n", [Math]::Max(0, $testMatch.Index - 1)) + 1
        $lineEnd = $content.IndexOf("`n", $testMatch.Index)
        if ($lineEnd -eq -1) { $lineEnd = $content.Length }
        $fullLine = $content.Substring($lineStart, $lineEnd - $lineStart)
        
        # Check for no-aaa exemption
        if ($fullLine -match $noAaaPattern) {
            $exemptedTestFunctions++
            continue
        }
        
        # Get the function body
        $functionBody = Get-FunctionBody -content $content -startIndex $testMatch.Index
        
        if (-not $functionBody) {
            Write-Host "  [WARN] Could not parse function body: $testName in $($file.Name)" -ForegroundColor Yellow
            continue
        }
        
        # Check for AAA comments
        $aaaResult = Test-AAAComments -codeBlock $functionBody -helperFunctions $helperFunctions
        
        $missing = @()
        if (-not $aaaResult.HasArrange) { $missing += "arrange" }
        if (-not $aaaResult.HasAct) { $missing += "act" }
        if (-not $aaaResult.HasAssert) { $missing += "assert" }
        
        $violation = $null
        
        if ($missing.Count -gt 0) {
            $violation = @{
                FilePath = $file.FullName
                RelativePath = $relativePath
                TestName = $testName
                TestMacro = $testMacro
                Line = $testLine
                Issue = "Missing AAA comment(s): $($missing -join ', ')"
            }
        }
        elseif (-not (Test-AAAOrder -arrangePos $aaaResult.ArrangePos -actPos $aaaResult.ActPos -assertPos $aaaResult.AssertPos)) {
            $violation = @{
                FilePath = $file.FullName
                RelativePath = $relativePath
                TestName = $testName
                TestMacro = $testMacro
                Line = $testLine
                Issue = "AAA comments are not in correct order (should be: arrange, act, assert)"
            }
        }
        
        if ($violation) {
            $testFunctionsWithViolations += [PSCustomObject]$violation
            Write-Host "  [FAIL] $relativePath" -ForegroundColor Red
            Write-Host "         Line $($violation.Line): $($violation.TestMacro)($($violation.TestName))" -ForegroundColor Yellow
            Write-Host "         $($violation.Issue)" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Validation Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total test files checked: $totalFiles" -ForegroundColor White
Write-Host "Files skipped (excluded directories): $skippedFiles" -ForegroundColor White
Write-Host "Total test functions found: $totalTestFunctions" -ForegroundColor White
Write-Host "Test functions exempted (no-aaa): $exemptedTestFunctions" -ForegroundColor White

if ($testFunctionsWithViolations.Count -gt 0) {
    Write-Host "Test functions with violations: $($testFunctionsWithViolations.Count)" -ForegroundColor Red
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "TEST FUNCTIONS MISSING AAA COMMENTS" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Each test function should contain AAA comments in order:" -ForegroundColor Yellow
    Write-Host "  // arrange (or /// arrange, /* arrange */)" -ForegroundColor White
    Write-Host "  // act" -ForegroundColor White
    Write-Host "  // assert" -ForegroundColor White
    Write-Host ""
    Write-Host "To exempt a test from this requirement, add '// no-aaa' to the TEST_FUNCTION line:" -ForegroundColor Yellow
    Write-Host "  TEST_FUNCTION(test_name) // no-aaa" -ForegroundColor White
    Write-Host ""
    
    # Group by file for cleaner output
    $groupedViolations = $testFunctionsWithViolations | Group-Object -Property RelativePath
    
    foreach ($group in $groupedViolations) {
        Write-Host "  $($group.Name)" -ForegroundColor White
        foreach ($violation in $group.Group) {
            Write-Host "    Line $($violation.Line): $($violation.TestMacro)($($violation.TestName))" -ForegroundColor Gray
            Write-Host "      $($violation.Issue)" -ForegroundColor Yellow
        }
        Write-Host ""
    }
    
    Write-Host "[VALIDATION FAILED]" -ForegroundColor Red
    exit 1
}
else {
    Write-Host ""
    Write-Host "[VALIDATION PASSED]" -ForegroundColor Green
    exit 0
}
