# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS
    Validates that source files do not contain tab characters.

.DESCRIPTION
    This script checks all source code files (.h, .hpp, .c, .cpp, .cs) to ensure they
    do not contain tab characters (ASCII 9). Tabs should be replaced with spaces for
    consistent code formatting across different editors and tools.
    
    The script automatically excludes dependency directories to avoid modifying third-party code.
    
    When the -Fix switch is provided, the script will automatically replace all tabs
    with 4 spaces.

.PARAMETER RepoRoot
    The root directory of the repository to validate.

.PARAMETER ExcludeFolders
    Comma-separated list of additional folders to exclude from validation.

.PARAMETER Fix
    If specified, automatically replace tabs with 4 spaces.

.EXAMPLE
    .\validate_no_tabs.ps1 -RepoRoot "C:\repo"
    
    Validates all source files and reports files containing tabs.

.EXAMPLE
    .\validate_no_tabs.ps1 -RepoRoot "C:\repo" -Fix
    
    Validates and automatically replaces tabs with 4 spaces in all source files.

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
Write-Host "Tab Character Validation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Repository Root: $RepoRoot" -ForegroundColor White
Write-Host "Fix Mode: $($Fix.IsPresent)" -ForegroundColor White
Write-Host ""

# Define file extensions to check
$extensions = @("*.h", "*.hpp", "*.c", "*.cpp", "*.cs")

# Parse excluded directories (default: deps, cmake)
$excludeDirs = $ExcludeFolders -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

Write-Host "Excluded directories: $($excludeDirs -join ', ')" -ForegroundColor White
Write-Host ""

# Initialize counters
$totalFiles = 0
$filesWithTabs = @()
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
    
    # Read file content as raw text to preserve encoding
    try {
        $content = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
    }
    catch {
        Write-Host "  [WARN] Cannot read file: $($file.FullName)" -ForegroundColor Yellow
        continue
    }
    
    # Check if file contains tabs (ASCII 9)
    if ($content -match "`t") {
        # Count tabs for reporting
        $tabCount = ([regex]::Matches($content, "`t")).Count
        
        Write-Host "  [FAIL] $($file.FullName)" -ForegroundColor Red
        Write-Host "         Contains $tabCount tab character(s)" -ForegroundColor Yellow
        
        $filesWithTabs += [PSCustomObject]@{
            FilePath = $file.FullName
            TabCount = $tabCount
        }
        
        if ($Fix) {
            try {
                # Replace all tabs with 4 spaces
                $fixedContent = $content -replace "`t", "    "
                
                # Write back to file, preserving encoding
                # Use UTF8 without BOM for consistency
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($file.FullName, $fixedContent, $utf8NoBom)
                
                Write-Host "         [FIXED] Replaced $tabCount tab(s) with spaces" -ForegroundColor Green
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

if ($filesWithTabs.Count -gt 0 -and -not $Fix) {
    Write-Host "Files with tabs: $($filesWithTabs.Count)" -ForegroundColor Red
    Write-Host ""
    Write-Host "The following files contain tab characters:" -ForegroundColor Yellow
    
    # Show all files
    foreach ($item in $filesWithTabs) {
        Write-Host "  - $($item.FilePath) ($($item.TabCount) tab(s))" -ForegroundColor White
    }
    
    Write-Host ""
    Write-Host "To fix these files automatically, run with -Fix parameter." -ForegroundColor Cyan
    Write-Host "This will replace all tabs with 4 spaces." -ForegroundColor Cyan
    Write-Host ""
}

$unfixedFiles = $filesWithTabs.Count - $fixedFiles.Count

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
