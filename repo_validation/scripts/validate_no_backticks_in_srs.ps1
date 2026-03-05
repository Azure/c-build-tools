# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS
    Validates that SRS requirements in code comments do not contain raw backticks.

.DESCRIPTION
    This script checks all source code files (.h, .hpp, .c, .cpp) to ensure that
    SRS requirement comments do not contain raw markdown backticks. When requirements
    are copy-pasted from markdown documentation into code comments, the backticks
    should be stripped to show the rendered form.
    
    For example, this is WRONG (contains backticks):
        /*Codes_SRS_MODULE_01_001: [ The function shall call `do_something`. ]*/
    
    This is CORRECT (no backticks):
        /*Codes_SRS_MODULE_01_001: [ The function shall call do_something. ]*/
    
    The script automatically excludes dependency directories to avoid modifying third-party code.
    
    When the -Fix switch is provided, the script will automatically remove backticks from
    SRS requirement comments.

.PARAMETER RepoRoot
    The root directory of the repository to validate.

.PARAMETER ExcludeFolders
    Comma-separated list of additional folders to exclude from validation.

.PARAMETER Fix
    If specified, automatically remove backticks from SRS requirement comments.

.EXAMPLE
    .\validate_no_backticks_in_srs.ps1 -RepoRoot "C:\repo"
    
    Validates all source files and reports files containing backticks in SRS comments.

.EXAMPLE
    .\validate_no_backticks_in_srs.ps1 -RepoRoot "C:\repo" -Fix
    
    Validates and automatically removes backticks from SRS requirement comments.

.NOTES
    Returns exit code 0 if all files are valid (or were fixed), 1 if validation fails.
    Dependencies in deps/ and dependencies/ directories are automatically excluded.
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
Write-Host "SRS Backticks Validation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Repository Root: $RepoRoot" -ForegroundColor White
Write-Host "Fix Mode: $($Fix.IsPresent)" -ForegroundColor White
Write-Host ""

# Define file extensions to check
$extensions = @("*.h", "*.hpp", "*.c", "*.cpp")

# Parse excluded directories (default: deps, cmake)
$excludeDirs = $ExcludeFolders -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

Write-Host "Excluded directories: $($excludeDirs -join ', ')" -ForegroundColor White
Write-Host ""

# Initialize counters
$totalFiles = 0
$filesWithBackticks = @()
$fixedFiles = @()
$skippedFiles = 0

# Get all source files in the repository
Write-Host "Searching for source files..." -ForegroundColor White
$allFiles = @()
foreach ($ext in $extensions) {
    $allFiles += Get-ChildItem -Path $RepoRoot -Recurse -Filter $ext -ErrorAction SilentlyContinue
}

Write-Host "Found $($allFiles.Count) source files to check" -ForegroundColor White
Write-Host ""

# Pattern to match SRS requirements containing backticks
# Matches patterns like: SRS_MODULE_01_001: [ ... ` ... ]
# The pattern requires the standard SRS tag format: SRS_COMPONENT_NN_NNN
$srsWithBacktickPattern = 'SRS_[A-Z_]+_\d+_\d+\s*:\s*\[[^\]]*`[^\]]*\]'

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
        $content = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
    }
    catch {
        Write-Host "  [WARN] Cannot read file: $($file.FullName)" -ForegroundColor Yellow
        continue
    }
    
    if ([string]::IsNullOrEmpty($content)) {
        continue
    }
    
    # Check if file contains SRS requirements with backticks
    $matches = [regex]::Matches($content, $srsWithBacktickPattern)
    
    if ($matches.Count -gt 0) {
        Write-Host "  [FAIL] $($file.FullName)" -ForegroundColor Red
        Write-Host "         Contains $($matches.Count) SRS requirement(s) with backticks" -ForegroundColor Yellow
        
        foreach ($match in $matches) {
            # Truncate long matches for display
            $displayText = $match.Value
            if ($displayText.Length -gt 100) {
                $displayText = $displayText.Substring(0, 97) + "..."
            }
            Write-Host "         Found: $displayText" -ForegroundColor Yellow
        }
        
        $filesWithBackticks += [PSCustomObject]@{
            FilePath = $file.FullName
            MatchCount = $matches.Count
            Matches = $matches
        }
        
        if ($Fix) {
            try {
                # Remove backticks from within SRS requirement brackets
                # This regex finds SRS requirements and removes backticks from within the brackets
                $fixedContent = $content
                
                # Process each SRS requirement pattern and remove backticks within it
                # Match the standard SRS tag format and capture the brackets content
                $srsPattern = '(SRS_[A-Z_]+_\d+_\d+\s*:\s*\[)([^\]]*)(\])'
                $fixedContent = [regex]::Replace($fixedContent, $srsPattern, {
                    param($m)
                    $prefix = $m.Groups[1].Value
                    $middle = $m.Groups[2].Value -replace '`', ''
                    $suffix = $m.Groups[3].Value
                    return $prefix + $middle + $suffix
                })
                
                # Write back to file, preserving encoding
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($file.FullName, $fixedContent, $utf8NoBom)
                
                Write-Host "         [FIXED] Removed backticks from SRS requirements" -ForegroundColor Green
                $fixedFiles += $file.FullName
            }
            catch {
                Write-Host "         [ERROR] Failed to fix: $_" -ForegroundColor Red
            }
        }
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Validation Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total source files checked: $totalFiles" -ForegroundColor White
Write-Host "Files skipped (excluded directories): $skippedFiles" -ForegroundColor White

if ($Fix -and $fixedFiles.Count -gt 0) {
    Write-Host "Files fixed successfully: $($fixedFiles.Count)" -ForegroundColor Green
}

if ($filesWithBackticks.Count -gt 0 -and -not $Fix) {
    Write-Host "Files with backticks in SRS requirements: $($filesWithBackticks.Count)" -ForegroundColor Red
    Write-Host ""
    Write-Host "The following files contain backticks in SRS requirement comments:" -ForegroundColor Yellow
    
    foreach ($item in $filesWithBackticks) {
        Write-Host "  - $($item.FilePath) ($($item.MatchCount) occurrence(s))" -ForegroundColor White
    }
    
    Write-Host ""
    Write-Host "Requirements should appear in code comments in their rendered form," -ForegroundColor Cyan
    Write-Host "without markdown backticks. For example:" -ForegroundColor Cyan
    Write-Host "  WRONG:   [ The function shall call \`do_something\`. ]" -ForegroundColor Red
    Write-Host "  CORRECT: [ The function shall call do_something. ]" -ForegroundColor Green
    Write-Host ""
    Write-Host "To fix these files automatically, run with -Fix parameter." -ForegroundColor Cyan
    Write-Host ""
}

$unfixedFiles = $filesWithBackticks.Count - $fixedFiles.Count

if ($unfixedFiles -eq 0) {
    Write-Host "[VALIDATION PASSED]" -ForegroundColor Green
    exit 0
} else {
    Write-Host "[VALIDATION FAILED]" -ForegroundColor Red
    if ($Fix) {
        Write-Host "$unfixedFiles file(s) could not be fixed automatically." -ForegroundColor Yellow
    }
    exit 1
}
