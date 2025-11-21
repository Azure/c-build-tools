# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS
    Validates that source files use the correct ENABLE_MOCKS pattern.

.DESCRIPTION
    This script checks all source code files (.h, .c, .cpp) to ensure they do not use
    the deprecated #define ENABLE_MOCKS and #undef ENABLE_MOCKS patterns.
    
    Instead, files should use the modern include-based pattern:
      #include "umock_c/umock_c_ENABLE_MOCKS.h"  // ============================== ENABLE_MOCKS
      #include "umock_c/umock_c_DISABLE_MOCKS.h" // ============================== DISABLE_MOCKS
    
    The script automatically excludes dependency directories to avoid modifying third-party code.
    
    When the -Fix switch is provided, the script will automatically replace the deprecated
    #define/#undef patterns with the correct include statements.

.PARAMETER RepoRoot
    The root directory of the repository to validate.

.PARAMETER ExcludeFolders
    Comma-separated list of additional folders to exclude from validation.

.PARAMETER Fix
    If specified, automatically replace deprecated patterns with include statements.

.EXAMPLE
    .\validate_enable_mocks_pattern.ps1 -RepoRoot "C:\repo"
    
    Validates all source files and reports files using deprecated ENABLE_MOCKS patterns.

.EXAMPLE
    .\validate_enable_mocks_pattern.ps1 -RepoRoot "C:\repo" -Fix
    
    Validates and automatically replaces deprecated patterns with include statements.

.NOTES
    Returns exit code 0 if all files are valid (or were fixed), 1 if validation fails.
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
Write-Host "ENABLE_MOCKS Pattern Validation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Repository Root: $RepoRoot" -ForegroundColor White
Write-Host "Fix Mode: $($Fix.IsPresent)" -ForegroundColor White
Write-Host ""

# Define file extensions to check (only C/C++ source/header files)
$extensions = @("*.h", "*.c", "*.cpp")

# Parse excluded directories (default: deps, cmake)
$excludeDirs = $ExcludeFolders -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

Write-Host "Excluded directories: $($excludeDirs -join ', ')" -ForegroundColor White
Write-Host ""

# Initialize counters
$totalFiles = 0
$filesWithViolations = @()
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
    
    # Skip files that are already empty or null
    if ([string]::IsNullOrWhiteSpace($content)) {
        continue
    }
    
    # Check for deprecated patterns
    # Pattern 1: #define ENABLE_MOCKS (with optional whitespace)
    # Pattern 2: #undef ENABLE_MOCKS (with optional whitespace)
    $hasDefinePattern = $content -match '(?m)^\s*#\s*define\s+ENABLE_MOCKS\s*$'
    $hasUndefPattern = $content -match '(?m)^\s*#\s*undef\s+ENABLE_MOCKS\s*$'
    
    if ($hasDefinePattern -or $hasUndefPattern) {
        # Count occurrences for reporting
        $defineMatches = ([regex]::Matches($content, '(?m)^\s*#\s*define\s+ENABLE_MOCKS\s*$')).Count
        $undefMatches = ([regex]::Matches($content, '(?m)^\s*#\s*undef\s+ENABLE_MOCKS\s*$')).Count
        $totalViolations = $defineMatches + $undefMatches
        
        Write-Host "  [FAIL] $($file.FullName)" -ForegroundColor Red
        if ($defineMatches -gt 0) {
            Write-Host "         Found $defineMatches '#define ENABLE_MOCKS' statement(s)" -ForegroundColor Yellow
        }
        if ($undefMatches -gt 0) {
            Write-Host "         Found $undefMatches '#undef ENABLE_MOCKS' statement(s)" -ForegroundColor Yellow
        }
        
        $filesWithViolations += [PSCustomObject]@{
            FilePath = $file.FullName
            DefineCount = $defineMatches
            UndefCount = $undefMatches
        }
        
        if ($Fix) {
            try {
                # Replace #define ENABLE_MOCKS with include statement
                $fixedContent = $content -replace '(?m)^\s*#\s*define\s+ENABLE_MOCKS\s*$', '#include "umock_c/umock_c_ENABLE_MOCKS.h" // ============================== ENABLE_MOCKS'
                
                # Replace #undef ENABLE_MOCKS with include statement
                $fixedContent = $fixedContent -replace '(?m)^\s*#\s*undef\s+ENABLE_MOCKS\s*$', '#include "umock_c/umock_c_DISABLE_MOCKS.h" // ============================== DISABLE_MOCKS'
                
                # Write back to file, preserving encoding
                # Use UTF8 without BOM for consistency
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($file.FullName, $fixedContent, $utf8NoBom)
                
                Write-Host "         [FIXED] Replaced $totalViolations deprecated pattern(s)" -ForegroundColor Green
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

if ($filesWithViolations.Count -gt 0 -and -not $Fix) {
    Write-Host "Files with violations: $($filesWithViolations.Count)" -ForegroundColor Red
    Write-Host ""
    Write-Host "The following files use deprecated ENABLE_MOCKS patterns:" -ForegroundColor Yellow
    
    # Show all files
    foreach ($item in $filesWithViolations) {
        $details = @()
        if ($item.DefineCount -gt 0) {
            $details += "#define: $($item.DefineCount)"
        }
        if ($item.UndefCount -gt 0) {
            $details += "#undef: $($item.UndefCount)"
        }
        Write-Host "  - $($item.FilePath) ($($details -join ', '))" -ForegroundColor White
    }
    
    Write-Host ""
    Write-Host "Files should use:" -ForegroundColor Cyan
    Write-Host '  #include "umock_c/umock_c_ENABLE_MOCKS.h"  // ============================== ENABLE_MOCKS' -ForegroundColor White
    Write-Host '  #include "umock_c/umock_c_DISABLE_MOCKS.h" // ============================== DISABLE_MOCKS' -ForegroundColor White
    Write-Host ""
    Write-Host "To fix these files automatically, run with -Fix parameter." -ForegroundColor Cyan
    Write-Host ""
}

$unfixedFiles = $filesWithViolations.Count - $fixedFiles.Count

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
