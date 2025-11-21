# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS
    Validates that source files do not explicitly include vld.h.

.DESCRIPTION
    This script checks all source code files (.h, .hpp, .c, .cpp, .txt) to ensure they
    do not contain explicit #include directives for vld.h. VLD (Visual Leak Detector)
    should be integrated automatically through the build system, not included directly
    in source files.
    
    The script automatically excludes dependency directories to avoid modifying third-party code.
    
    When the -Fix switch is provided, the script will automatically remove lines that
    include vld.h.

.PARAMETER RepoRoot
    The root directory of the repository to validate.

.PARAMETER ExcludeFolders
    Comma-separated list of additional folders to exclude from validation.

.PARAMETER Fix
    If specified, automatically remove #include directives for vld.h.

.EXAMPLE
    .\validate_no_vld_include.ps1 -RepoRoot "C:\repo"
    
    Validates all source files and reports files containing vld.h includes.

.EXAMPLE
    .\validate_no_vld_include.ps1 -RepoRoot "C:\repo" -Fix
    
    Validates and automatically removes vld.h includes from all source files.

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
Write-Host "VLD Include Validation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Repository Root: $RepoRoot" -ForegroundColor White
Write-Host "Fix Mode: $($Fix.IsPresent)" -ForegroundColor White
Write-Host ""

# Define file extensions to check
$extensions = @("*.h", "*.hpp", "*.c", "*.cpp", "*.txt")

# Parse excluded directories (default: deps, cmake)
$excludeDirs = $ExcludeFolders -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

Write-Host "Excluded directories: $($excludeDirs -join ', ')" -ForegroundColor White
Write-Host ""

# Initialize counters
$totalFiles = 0
$filesWithVldInclude = @()
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

# Pattern to match vld.h includes (various forms)
# Matches: #include "vld.h", #include <vld.h>, #  include "vld.h", etc.
# However, if the line contains a "// force" or "// FORCE" comment, it will be ignored
$vldIncludePattern = '^\s*#\s*include\s*[<"]vld\.h[>"]'
$forceCommentPattern = '//\s*force\s*$'
$useVldIfdefPattern = '^\s*#\s*ifdef\s+USE_VLD\s*$'
$endifPattern = '^\s*#\s*endif\s*(?://.*)?$'

foreach ($file in $allFiles) {
    # Check if file should be excluded
    $relativePath = $file.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
    $isExcluded = $false
    
    foreach ($excludeDir in $excludeDirs) {
        # Check both path separator types for compatibility
        # While PowerShell often handles path separators interchangeably, the -like operator
        # with wildcards is literal about separators, so we check both to ensure exclusions
        # work regardless of how paths are constructed or normalized
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
    
    # Read file content as lines to detect and fix vld.h includes
    try {
        $lines = Get-Content -Path $file.FullName -ErrorAction Stop
    }
    catch {
        Write-Host "  [WARN] Cannot read file: $($file.FullName)" -ForegroundColor Yellow
        continue
    }
    
    # Check if file contains vld.h includes
    $matchingLines = @()
    $lineNumber = 0
    foreach ($line in $lines) {
        $lineNumber++
        if ($line -match $vldIncludePattern) {
            # Ignore lines with "// force" or "// FORCE" comment (case-insensitive)
            if ($line -notmatch '(?i)//\s*force\s*$') {
                $matchingLines += [PSCustomObject]@{
                    LineNumber = $lineNumber
                    Content = $line.Trim()
                }
            }
        }
    }
    
    if ($matchingLines.Count -gt 0) {
        Write-Host "  [FAIL] $($file.FullName)" -ForegroundColor Red
        Write-Host "         Contains $($matchingLines.Count) vld.h include(s)" -ForegroundColor Yellow
        
        foreach ($match in $matchingLines) {
            Write-Host "         Line $($match.LineNumber): $($match.Content)" -ForegroundColor Yellow
        }
        
        $filesWithVldInclude += [PSCustomObject]@{
            FilePath = $file.FullName
            MatchCount = $matchingLines.Count
            Matches = $matchingLines
        }
        
        if ($Fix) {
            try {
                # Process lines to remove vld.h includes and associated #ifdef USE_VLD/#endif blocks
                $fixedLines = @()
                $i = 0
                $removedCount = 0
                
                while ($i -lt $lines.Count) {
                    $currentLine = $lines[$i]
                    
                    # Check if this is an #ifdef USE_VLD line
                    if ($currentLine -match $useVldIfdefPattern) {
                        # Look ahead to find the vld.h include and endif
                        $j = $i + 1
                        $foundVldInclude = $false
                        $foundEndif = $false
                        $onlyVldInclude = $true
                        
                        # Scan forward to find what's inside this #ifdef block
                        while ($j -lt $lines.Count) {
                            $nextLine = $lines[$j]
                            
                            # Check if this is the vld.h include
                            if ($nextLine -match $vldIncludePattern) {
                                $foundVldInclude = $true
                                $j++
                                continue
                            }
                            
                            # Check if this is the #endif
                            if ($nextLine -match $endifPattern) {
                                $foundEndif = $true
                                break
                            }
                            
                            # Check if there's any non-whitespace content (other than comments)
                            if ($nextLine -match '^\s*$' -or $nextLine -match '^\s*//') {
                                # Empty line or comment line - ignore
                                $j++
                                continue
                            }
                            
                            # Found some other code - this block contains more than just vld.h
                            $onlyVldInclude = $false
                            break
                        }
                        
                        # If we found an #ifdef USE_VLD block that only contains vld.h include, remove the entire block
                        if ($foundVldInclude -and $foundEndif -and $onlyVldInclude) {
                            Write-Host "         Removing #ifdef USE_VLD block (lines $($i+1)-$($j+1))" -ForegroundColor Yellow
                            $removedCount++
                            $i = $j + 1  # Skip past the #endif
                            continue
                        }
                    }
                    
                    # Check if this line is a vld.h include (not inside a block we're removing)
                    if ($currentLine -match $vldIncludePattern) {
                        # Skip removal if line has "// force" or "// FORCE" comment (case-insensitive)
                        if ($currentLine -notmatch '(?i)//\s*force\s*$') {
                            $removedCount++
                            $i++
                            continue
                        }
                    }
                    
                    # Keep this line
                    $fixedLines += $currentLine
                    $i++
                }
                
                # Write back to file, preserving encoding
                # Use UTF8 without BOM for consistency
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                $fixedContent = ($fixedLines -join "`r`n") + "`r`n"
                [System.IO.File]::WriteAllText($file.FullName, $fixedContent, $utf8NoBom)
                
                Write-Host "         [FIXED] Removed $removedCount vld.h include(s) and associated blocks" -ForegroundColor Green
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

if ($filesWithVldInclude.Count -gt 0 -and -not $Fix) {
    Write-Host "Files with vld.h includes: $($filesWithVldInclude.Count)" -ForegroundColor Red
    Write-Host ""
    Write-Host "The following files contain explicit vld.h includes:" -ForegroundColor Yellow
    
    # Show all files
    foreach ($item in $filesWithVldInclude) {
        Write-Host "  - $($item.FilePath) ($($item.MatchCount) include(s))" -ForegroundColor White
    }
    
    Write-Host ""
    Write-Host "VLD (Visual Leak Detector) should be integrated through the build system," -ForegroundColor Cyan
    Write-Host "not included directly in source files. Use the add_vld_if_defined() CMake" -ForegroundColor Cyan
    Write-Host "function to enable VLD integration when the use_vld option is set." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "To fix these files automatically, run with -Fix parameter." -ForegroundColor Cyan
    Write-Host "This will remove all explicit #include directives for vld.h." -ForegroundColor Cyan
    Write-Host ""
}

$unfixedFiles = $filesWithVldInclude.Count - $fixedFiles.Count

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
