# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS
    Validates that test functions contain AAA (Arrange, Act, Assert) comments.

.DESCRIPTION
    This script checks all unit test files (*_ut.c) to ensure that test functions 
    (TEST_FUNCTION, TEST_METHOD, CTEST_FUNCTION) contain AAA comments in the correct 
    order: Arrange, Act, Assert.
    
    Note: Integration test files (*_int.c) are not checked by this validation because
    integration tests often have more complex structures that don't fit the AAA pattern.
    
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
    [AllowEmptyString()]
    [string]$ExcludeFolders = "deps,cmake",
    
    [Parameter(Mandatory=$false)]
    [switch]$Fix
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Resolve the RepoRoot to an absolute path
$RepoRoot = (Resolve-Path $RepoRoot).Path.TrimEnd('\', '/')

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

# Define file patterns to check (unit tests only, not integration tests)
$filePatterns = @("*_ut.c")

# Parse excluded directories (default: deps, cmake)
$excludeDirs = $ExcludeFolders -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

Write-Host "Excluded directories: $($excludeDirs -join ', ')" -ForegroundColor White
Write-Host "File patterns: $($filePatterns -join ', ')" -ForegroundColor White
Write-Host ""

# Initialize counters
$totalFiles = 0
$totalTestFunctions = 0
$testFunctionsWithViolations = [System.Collections.ArrayList]::new()
$skippedFiles = 0
$exemptedTestFunctions = 0

# Pre-compile regex patterns for performance
$testFunctionRegex = [regex]::new('^\s*(TEST_FUNCTION|TEST_METHOD|CTEST_FUNCTION)\s*\(\s*(\w+)\s*\)', [System.Text.RegularExpressions.RegexOptions]::Multiline)
# AAA comment patterns - require word boundary after the keyword to avoid matching //ASSERT_... as assert comment
$arrangeRegex = [regex]::new('//+\s*arrange\b|/\*\s*arrange\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$actRegex = [regex]::new('//+\s*act\b|/\*\s*act\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$assertRegex = [regex]::new('//+\s*assert\b|/\*\s*assert\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$noAaaRegex = [regex]::new('//\s*no-aaa|/\*\s*no-aaa', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
# Helper function start pattern - finds potential function definitions
# Matches: optional "static", return type (common C types or THANDLE/custom types), optional pointer, function name, (
# Function names can contain uppercase letters (e.g., test_onReadRecordSegments_failure)
# Macro exclusion is done separately in the processing loop
$helperFuncStartRegex = [regex]::new('^(?:static\s+)?(?:void|int|bool|char|unsigned|signed|long|short|float|double|size_t|uint\d+_t|int\d+_t|THANDLE\s*\([^)]+\))\s*\*?\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\(', [System.Text.RegularExpressions.RegexOptions]::Multiline)
$funcCallRegex = [regex]::new('(?<!\w)(\w+)\s*\(', [System.Text.RegularExpressions.RegexOptions]::None)

# Find the end of a function signature (handles nested parentheses in types like THANDLE(...))
# Returns index of opening brace, or -1 if not a function definition
function Find-FunctionEnd {
    param(
        [string]$content,
        [int]$parenStart  # Index of opening paren after function name
    )
    
    $len = $content.Length
    $parenCount = 1
    $pos = $parenStart + 1
    
    # Find matching closing paren
    while ($parenCount -gt 0 -and $pos -lt $len) {
        $char = $content[$pos]
        if ($char -eq '(') { $parenCount++ }
        elseif ($char -eq ')') { $parenCount-- }
        $pos++
    }
    
    if ($parenCount -ne 0) { return -1 }
    
    # Skip whitespace and newlines, look for opening brace
    while ($pos -lt $len) {
        $char = $content[$pos]
        if ($char -eq '{') { return $pos }
        if ($char -match '\s') { $pos++; continue }
        return -1  # Found non-whitespace, non-brace - not a function definition
    }
    
    return -1
}

# Function body extraction with string-literal awareness
# Skips braces inside double-quoted strings and character literals
function Get-FunctionBody {
    param(
        [string]$content,
        [int]$startIndex
    )
    
    $braceStart = $content.IndexOf('{', $startIndex)
    if ($braceStart -eq -1) { return $null }
    
    $braceCount = 1
    $pos = $braceStart + 1
    $len = $content.Length
    
    while ($braceCount -gt 0 -and $pos -lt $len) {
        $char = $content[$pos]
        
        # Skip string literals
        if ($char -eq '"') {
            $pos++
            while ($pos -lt $len) {
                if ($content[$pos] -eq '\' -and ($pos + 1) -lt $len) {
                    $pos += 2  # Skip escaped character
                } elseif ($content[$pos] -eq '"') {
                    $pos++
                    break
                } else {
                    $pos++
                }
            }
            continue
        }
        
        # Skip character literals
        if ($char -eq "'") {
            $pos++
            while ($pos -lt $len) {
                if ($content[$pos] -eq '\' -and ($pos + 1) -lt $len) {
                    $pos += 2  # Skip escaped character
                } elseif ($content[$pos] -eq "'") {
                    $pos++
                    break
                } else {
                    $pos++
                }
            }
            continue
        }
        
        # Count braces
        if ($char -eq '{') {
            $braceCount++
        } elseif ($char -eq '}') {
            $braceCount--
        }
        $pos++
    }
    
    if ($braceCount -eq 0) {
        return $content.Substring($braceStart, $pos - $braceStart)
    }
    return $null
}

# Build line number lookup table for fast line number queries
function Build-LineTable {
    param([string]$content)
    
    $lines = [System.Collections.ArrayList]::new()
    [void]$lines.Add(0)  # Line 1 starts at position 0
    
    $pos = 0
    while (($pos = $content.IndexOf("`n", $pos)) -ne -1) {
        $pos++
        [void]$lines.Add($pos)
    }
    return $lines
}

# Fast line number lookup using binary search
function Get-LineFromTable {
    param([System.Collections.ArrayList]$lineTable, [int]$position)
    
    $low = 0
    $high = $lineTable.Count - 1
    
    while ($low -le $high) {
        $mid = [int](($low + $high) / 2)
        if ($lineTable[$mid] -le $position) {
            if ($mid -eq $lineTable.Count - 1 -or $lineTable[$mid + 1] -gt $position) {
                return $mid + 1
            }
            $low = $mid + 1
        } else {
            $high = $mid - 1
        }
    }
    return 1
}

# Check AAA in a code block - returns positions or -1 if not found
function Find-AAAPositions {
    param([string]$block)
    
    $arr = $arrangeRegex.Match($block)
    $act = $actRegex.Match($block)
    $ast = $assertRegex.Match($block)
    
    return @(
        $(if ($arr.Success) { $arr.Index } else { -1 }),
        $(if ($act.Success) { $act.Index } else { -1 }),
        $(if ($ast.Success) { $ast.Index } else { -1 })
    )
}

# Process a single file - returns array of violations
function Process-TestFile {
    param(
        [string]$content,
        [string]$relativePath,
        [string]$fullPath
    )
    
    $violations = [System.Collections.ArrayList]::new()
    $lineTable = Build-LineTable -content $content
    $exempted = 0
    $total = 0
    
    # Find all test functions
    $testMatches = $testFunctionRegex.Matches($content)
    if ($testMatches.Count -eq 0) {
        return @{ Violations = $violations; Total = 0; Exempted = 0 }
    }
    
    # Build helper function position map and AAA cache (lazy - only if needed)
    $helperPositions = $null
    $helperAAACache = $null
    
    foreach ($testMatch in $testMatches) {
        $total++
        $testMacro = $testMatch.Groups[1].Value
        $testName = $testMatch.Groups[2].Value
        
        # Get line containing the TEST_FUNCTION
        # The regex may match leading whitespace/newlines, so find the actual line
        # by looking for the line containing the match end (after the closing paren)
        $matchEnd = $testMatch.Index + $testMatch.Length
        $lineStart = $content.LastIndexOf("`n", [Math]::Max(0, $matchEnd - 1)) + 1
        # Skip past any \r character that may be before \n on Windows
        while ($lineStart -lt $content.Length -and $content[$lineStart] -eq "`r") {
            $lineStart++
        }
        $lineEnd = $content.IndexOf("`n", $matchEnd)
        if ($lineEnd -eq -1) { $lineEnd = $content.Length }
        $testLine = $content.Substring($lineStart, $lineEnd - $lineStart)
        
        # Check exemption
        if ($noAaaRegex.IsMatch($testLine)) {
            $exempted++
            continue
        }
        
        # Get function body
        $body = Get-FunctionBody -content $content -startIndex $testMatch.Index
        if (-not $body) { continue }
        
        # Check AAA in body
        $positions = Find-AAAPositions -block $body
        $hasAll = ($positions[0] -ge 0) -and ($positions[1] -ge 0) -and ($positions[2] -ge 0)
        
        # If all found, check order
        if ($hasAll) {
            if ($positions[0] -lt $positions[1] -and $positions[1] -lt $positions[2]) {
                continue  # Valid
            }
            # Wrong order
            $lineNum = Get-LineFromTable -lineTable $lineTable -position $testMatch.Index
            [void]$violations.Add(@{
                RelativePath = $relativePath
                TestName = $testName
                TestMacro = $testMacro
                Line = $lineNum
                Issue = "AAA comments are not in correct order (should be: arrange, act, assert)"
            })
            continue
        }
        
        # Not all found - check helpers (lazy init of positions and AAA cache)
        if ($null -eq $helperPositions) {
            $helperPositions = @{}
            $helperAAACache = @{}  # Cache AAA positions for helpers
            $helperMatches = $helperFuncStartRegex.Matches($content)
            foreach ($hm in $helperMatches) {
                $fn = $hm.Groups[1].Value
                if ($fn -notmatch '^(TEST_FUNCTION|TEST_METHOD|CTEST_FUNCTION|if|while|for|switch|else|do|TEST_DEFINE_ENUM_TYPE|TEST_SUITE_INITIALIZE|TEST_SUITE_CLEANUP|TEST_FUNCTION_INITIALIZE|TEST_FUNCTION_CLEANUP)$') {
                    # Find the opening paren position
                    $parenPos = $hm.Index + $hm.Length - 1  # Last char is '('
                    $bracePos = Find-FunctionEnd -content $content -parenStart $parenPos
                    if ($bracePos -ge 0) {
                        $helperPositions[$fn] = $bracePos
                    }
                }
            }
        }
        
        # Find called helpers and check their cached AAA
        $callMatches = $funcCallRegex.Matches($body)
        
        foreach ($call in $callMatches) {
            $fn = $call.Groups[1].Value
            if ($helperPositions.ContainsKey($fn)) {
                # Check cache first
                if (-not $helperAAACache.ContainsKey($fn)) {
                    $helperBody = Get-FunctionBody -content $content -startIndex $helperPositions[$fn]
                    if ($helperBody) {
                        $helperAAACache[$fn] = Find-AAAPositions -block $helperBody
                    } else {
                        $helperAAACache[$fn] = @(-1, -1, -1)
                    }
                }
                $hPos = $helperAAACache[$fn]
                if ($hPos[0] -ge 0) { $positions[0] = 0 }
                if ($hPos[1] -ge 0) { $positions[1] = 0 }
                if ($hPos[2] -ge 0) { $positions[2] = 0 }
            }
            # Early exit if all found
            if ($positions[0] -ge 0 -and $positions[1] -ge 0 -and $positions[2] -ge 0) { break }
        }
        
        # Check what's missing
        $missing = @()
        if ($positions[0] -lt 0) { $missing += "arrange" }
        if ($positions[1] -lt 0) { $missing += "act" }
        if ($positions[2] -lt 0) { $missing += "assert" }
        
        if ($missing.Count -gt 0) {
            $lineNum = Get-LineFromTable -lineTable $lineTable -position $testMatch.Index
            [void]$violations.Add(@{
                RelativePath = $relativePath
                TestName = $testName
                TestMacro = $testMacro
                Line = $lineNum
                Issue = "Missing AAA comment(s): $($missing -join ', ')"
            })
        }
    }
    
    return @{ Violations = $violations; Total = $total; Exempted = $exempted }
}

# Get all test files in the repository
Write-Host "Searching for test files..." -ForegroundColor White
$allFiles = @()
foreach ($pattern in $filePatterns) {
    $allFiles += Get-ChildItem -Path $RepoRoot -Recurse -Filter $pattern -ErrorAction SilentlyContinue
}

# Filter excluded files upfront
$filesToProcess = [System.Collections.ArrayList]::new()
$skippedFiles = 0
foreach ($file in $allFiles) {
    $relativePath = $file.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
    $isExcluded = $false
    foreach ($excludeDir in $excludeDirs) {
        if ($relativePath -like "$excludeDir\*" -or $relativePath -like "$excludeDir/*") {
            $isExcluded = $true
            $skippedFiles++
            break
        }
    }
    if (-not $isExcluded) {
        [void]$filesToProcess.Add(@{ FullName = $file.FullName; RelativePath = $relativePath })
    }
}

$totalFiles = $filesToProcess.Count
Write-Host "Found $($allFiles.Count) test files, processing $totalFiles (excluded $skippedFiles)" -ForegroundColor White
Write-Host ""

# Check if we can use parallel processing (PowerShell 7+)
$useParallel = $PSVersionTable.PSVersion.Major -ge 7

if ($useParallel) {
    # Process files in parallel for better performance (PowerShell 7+)
    $results = $filesToProcess | ForEach-Object -Parallel {
        $fileInfo = $_
        $relativePath = $fileInfo.RelativePath
        $fullPath = $fileInfo.FullName
        
        # Read file content
        try {
            $content = [System.IO.File]::ReadAllText($fullPath)
        }
        catch {
            return @{ Violations = @(); Total = 0; Exempted = 0; Error = $fullPath }
        }
        
        if ([string]::IsNullOrWhiteSpace($content)) {
            return @{ Violations = @(); Total = 0; Exempted = 0 }
        }
        
        # Inline all the processing logic (can't call functions across parallel boundaries)
        $testFunctionRegex = [regex]::new('^\s*(TEST_FUNCTION|TEST_METHOD|CTEST_FUNCTION)\s*\(\s*(\w+)\s*\)', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $arrangeRegex = [regex]::new('//+\s*arrange\b|/\*\s*arrange\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $actRegex = [regex]::new('//+\s*act\b|/\*\s*act\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $assertRegex = [regex]::new('//+\s*assert\b|/\*\s*assert\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $noAaaRegex = [regex]::new('//\s*no-aaa|/\*\s*no-aaa', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $helperFuncStartRegex = [regex]::new('^(?:static\s+)?(?:void|int|bool|char|unsigned|signed|long|short|float|double|size_t|uint\d+_t|int\d+_t|THANDLE\s*\([^)]+\))\s*\*?\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\(', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $funcCallRegex = [regex]::new('(?<!\w)(\w+)\s*\(', [System.Text.RegularExpressions.RegexOptions]::None)
        
        # Find-FunctionEnd inline
        $FindFunctionEnd = {
            param([string]$content, [int]$parenStart)
            $len = $content.Length
            $parenCount = 1
            $pos = $parenStart + 1
            while ($parenCount -gt 0 -and $pos -lt $len) {
                $char = $content[$pos]
                if ($char -eq '(') { $parenCount++ }
                elseif ($char -eq ')') { $parenCount-- }
                $pos++
            }
            if ($parenCount -ne 0) { return -1 }
            while ($pos -lt $len) {
                $char = $content[$pos]
                if ($char -eq '{') { return $pos }
                if ($char -match '\s') { $pos++; continue }
                return -1
            }
            return -1
        }
        
        # Get-FunctionBody inline (with string-literal awareness)
        $GetFunctionBody = {
            param([string]$content, [int]$startIndex)
            $braceStart = $content.IndexOf('{', $startIndex)
            if ($braceStart -eq -1) { return $null }
            $braceCount = 1
            $pos = $braceStart + 1
            $len = $content.Length
            while ($braceCount -gt 0 -and $pos -lt $len) {
                $char = $content[$pos]
                # Skip string literals
                if ($char -eq '"') {
                    $pos++
                    while ($pos -lt $len) {
                        if ($content[$pos] -eq '\' -and ($pos + 1) -lt $len) {
                            $pos += 2
                        } elseif ($content[$pos] -eq '"') {
                            $pos++
                            break
                        } else {
                            $pos++
                        }
                    }
                    continue
                }
                # Skip character literals
                if ($char -eq "'") {
                    $pos++
                    while ($pos -lt $len) {
                        if ($content[$pos] -eq '\' -and ($pos + 1) -lt $len) {
                            $pos += 2
                        } elseif ($content[$pos] -eq "'") {
                            $pos++
                            break
                        } else {
                            $pos++
                        }
                    }
                    continue
                }
                # Count braces
                if ($char -eq '{') { $braceCount++ }
                elseif ($char -eq '}') { $braceCount-- }
                $pos++
            }
            if ($braceCount -eq 0) { return $content.Substring($braceStart, $pos - $braceStart) }
            return $null
        }
        
        # Build line table
        $lineTable = [System.Collections.ArrayList]::new()
        [void]$lineTable.Add(0)
        $pos = 0
        while (($pos = $content.IndexOf("`n", $pos)) -ne -1) {
            $pos++
            [void]$lineTable.Add($pos)
        }
        
        # Get line from table
        $GetLineFromTable = {
            param([System.Collections.ArrayList]$lineTable, [int]$position)
            $low = 0
            $high = $lineTable.Count - 1
            while ($low -le $high) {
                $mid = [int](($low + $high) / 2)
                if ($lineTable[$mid] -le $position) {
                    if ($mid -eq $lineTable.Count - 1 -or $lineTable[$mid + 1] -gt $position) {
                        return $mid + 1
                    }
                    $low = $mid + 1
                } else {
                    $high = $mid - 1
                }
            }
            return 1
        }
        
        $violations = @()
        $total = 0
        $exempted = 0
        
        $testMatches = $testFunctionRegex.Matches($content)
        if ($testMatches.Count -eq 0) {
            return @{ Violations = @(); Total = 0; Exempted = 0 }
        }
        
        $helperPositions = $null
        $helperAAACache = $null
        
        foreach ($testMatch in $testMatches) {
            $total++
            $testMacro = $testMatch.Groups[1].Value
            $testName = $testMatch.Groups[2].Value
            
            $matchEnd = $testMatch.Index + $testMatch.Length
            $lineStart = $content.LastIndexOf("`n", [Math]::Max(0, $matchEnd - 1)) + 1
            while ($lineStart -lt $content.Length -and $content[$lineStart] -eq "`r") { $lineStart++ }
            $lineEnd = $content.IndexOf("`n", $matchEnd)
            if ($lineEnd -eq -1) { $lineEnd = $content.Length }
            $testLine = $content.Substring($lineStart, $lineEnd - $lineStart)
            
            if ($noAaaRegex.IsMatch($testLine)) {
                $exempted++
                continue
            }
            
            $body = & $GetFunctionBody $content $testMatch.Index
            if (-not $body) { continue }
            
            $arr = $arrangeRegex.Match($body)
            $act = $actRegex.Match($body)
            $ast = $assertRegex.Match($body)
            $positions = @(
                $(if ($arr.Success) { $arr.Index } else { -1 }),
                $(if ($act.Success) { $act.Index } else { -1 }),
                $(if ($ast.Success) { $ast.Index } else { -1 })
            )
            
            $hasAll = ($positions[0] -ge 0) -and ($positions[1] -ge 0) -and ($positions[2] -ge 0)
            
            if ($hasAll) {
                if ($positions[0] -lt $positions[1] -and $positions[1] -lt $positions[2]) {
                    continue
                }
                $lineNum = & $GetLineFromTable $lineTable $testMatch.Index
                $violations += @{
                    RelativePath = $relativePath
                    TestName = $testName
                    TestMacro = $testMacro
                    Line = $lineNum
                    Issue = "AAA comments are not in correct order (should be: arrange, act, assert)"
                }
                continue
            }
            
            # Check helpers
            if ($null -eq $helperPositions) {
                $helperPositions = @{}
                $helperAAACache = @{}
                $helperMatches = $helperFuncStartRegex.Matches($content)
                foreach ($hm in $helperMatches) {
                    $fn = $hm.Groups[1].Value
                    if ($fn -notmatch '^(TEST_FUNCTION|TEST_METHOD|CTEST_FUNCTION|if|while|for|switch|else|do|TEST_DEFINE_ENUM_TYPE|TEST_SUITE_INITIALIZE|TEST_SUITE_CLEANUP|TEST_FUNCTION_INITIALIZE|TEST_FUNCTION_CLEANUP)$') {
                        $parenPos = $hm.Index + $hm.Length - 1
                        $bracePos = & $FindFunctionEnd $content $parenPos
                        if ($bracePos -ge 0) {
                            $helperPositions[$fn] = $bracePos
                        }
                    }
                }
            }
            
            $callMatches = $funcCallRegex.Matches($body)
            foreach ($call in $callMatches) {
                $fn = $call.Groups[1].Value
                if ($helperPositions.ContainsKey($fn)) {
                    if (-not $helperAAACache.ContainsKey($fn)) {
                        $helperBody = & $GetFunctionBody $content $helperPositions[$fn]
                        if ($helperBody) {
                            $hArr = $arrangeRegex.Match($helperBody)
                            $hAct = $actRegex.Match($helperBody)
                            $hAst = $assertRegex.Match($helperBody)
                            $helperAAACache[$fn] = @(
                                $(if ($hArr.Success) { $hArr.Index } else { -1 }),
                                $(if ($hAct.Success) { $hAct.Index } else { -1 }),
                                $(if ($hAst.Success) { $hAst.Index } else { -1 })
                            )
                        } else {
                            $helperAAACache[$fn] = @(-1, -1, -1)
                        }
                    }
                    $hPos = $helperAAACache[$fn]
                    if ($hPos[0] -ge 0) { $positions[0] = 0 }
                    if ($hPos[1] -ge 0) { $positions[1] = 0 }
                    if ($hPos[2] -ge 0) { $positions[2] = 0 }
                }
                if ($positions[0] -ge 0 -and $positions[1] -ge 0 -and $positions[2] -ge 0) { break }
            }
            
            $missing = @()
            if ($positions[0] -lt 0) { $missing += "arrange" }
            if ($positions[1] -lt 0) { $missing += "act" }
            if ($positions[2] -lt 0) { $missing += "assert" }
            
            if ($missing.Count -gt 0) {
                $lineNum = & $GetLineFromTable $lineTable $testMatch.Index
                $violations += @{
                    RelativePath = $relativePath
                    TestName = $testName
                    TestMacro = $testMacro
                    Line = $lineNum
                    Issue = "Missing AAA comment(s): $($missing -join ', ')"
                }
            }
        }
        
        return @{ Violations = $violations; Total = $total; Exempted = $exempted }
    } -ThrottleLimit ([Environment]::ProcessorCount)
} else {
    # Sequential processing for PowerShell 5.1
    $results = @()
    foreach ($fileInfo in $filesToProcess) {
        $relativePath = $fileInfo.RelativePath
        $fullPath = $fileInfo.FullName
        
        # Read file content
        try {
            $content = [System.IO.File]::ReadAllText($fullPath)
        }
        catch {
            $results += @{ Violations = @(); Total = 0; Exempted = 0; Error = $fullPath }
            continue
        }
        
        if ([string]::IsNullOrWhiteSpace($content)) {
            $results += @{ Violations = @(); Total = 0; Exempted = 0 }
            continue
        }
        
        # Process file using the shared Process-TestFile function
        $result = Process-TestFile -content $content -relativePath $relativePath -fullPath $fullPath
        $results += $result
    }
}

# Aggregate results
$totalTestFunctions = 0
$exemptedTestFunctions = 0
$testFunctionsWithViolations = [System.Collections.ArrayList]::new()

foreach ($result in $results) {
    if ($result.Error) {
        Write-Host "  [WARN] Cannot read file: $($result.Error)" -ForegroundColor Yellow
        continue
    }
    $totalTestFunctions += $result.Total
    $exemptedTestFunctions += $result.Exempted
    foreach ($v in $result.Violations) {
        [void]$testFunctionsWithViolations.Add([PSCustomObject]$v)
    }
}

# Print violations after parallel processing completes
foreach ($v in $testFunctionsWithViolations) {
    Write-Host "  [FAIL] $($v.RelativePath)" -ForegroundColor Red
    Write-Host "         Line $($v.Line): $($v.TestMacro)($($v.TestName))" -ForegroundColor Yellow
    Write-Host "         $($v.Issue)" -ForegroundColor Yellow
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
