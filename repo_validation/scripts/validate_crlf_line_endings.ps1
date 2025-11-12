# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS
    Validates that all source code files end with a newline (CRLF on Windows).

.DESCRIPTION
    This script checks all source code files (.h, .hpp, .c, .cpp, .cs) in the repository
    to ensure they end with a proper newline character sequence (CRLF). Files that end
    abruptly without a newline will be reported as validation failures.
    
    The script automatically excludes dependency directories (deps/, dependencies/) to
    avoid modifying third-party code.
    
    When the -Fix switch is provided, the script will automatically correct files
    by appending a CRLF newline at the end.

.PARAMETER RepoRoot
    The root directory of the repository to validate.

.PARAMETER Fix
    If specified, automatically fix files that do not end with a newline.

.EXAMPLE
    .\validate_crlf_line_endings.ps1 -RepoRoot "C:\repo"
    
    Validates all source files and reports errors.

.EXAMPLE
    .\validate_crlf_line_endings.ps1 -RepoRoot "C:\repo" -Fix
    
    Validates and automatically fixes all source files that don't end with a newline.

.NOTES
    Returns exit code 0 if all files are valid (or were fixed), 1 if validation fails.
    Dependencies in deps/ and dependencies/ directories are automatically excluded.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$RepoRoot,
    
    [Parameter(Mandatory=$false)]
    [string]$ExcludeFolders = "",
    
    [Parameter(Mandatory=$false)]
    [switch]$Fix
)

# Set error action preference
$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "File Ending Newline Validation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Repository Root: $RepoRoot" -ForegroundColor White
Write-Host "Fix Mode: $($Fix.IsPresent)" -ForegroundColor White
Write-Host ""

# Define file extensions to check
$extensions = @("*.h", "*.hpp", "*.c", "*.cpp", "*.cs")

# Base excluded directories (always excluded)
$baseExcludeDirs = @("deps", "dependencies", ".git", "cmake", "build")

# Parse and add custom excluded directories
$customExcludeDirs = @()
if ($ExcludeFolders -ne "") {
    $customExcludeDirs = $ExcludeFolders -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    Write-Host "Custom excluded directories: $($customExcludeDirs -join ', ')" -ForegroundColor Yellow
}

# Combine base and custom exclusions
$excludeDirs = $baseExcludeDirs + $customExcludeDirs
Write-Host "Total excluded directories: $($excludeDirs -join ', ')" -ForegroundColor White
Write-Host ""

# Initialize counters
$totalFiles = 0
$invalidFiles = @()
$fixedFiles = @()
$skippedFiles = 0

# Get all source files in the repository
Write-Host "Searching for source files..." -ForegroundColor Yellow
Write-Host "Excluding directories: $($excludeDirs -join ', ')" -ForegroundColor Yellow
Write-Host ""

foreach ($extension in $extensions) {
    $files = Get-ChildItem -Path $RepoRoot -Filter $extension -Recurse -File -ErrorAction SilentlyContinue
    
    foreach ($file in $files) {
        # Check if file is in an excluded directory
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
        
        # Read the file as bytes to check for exact line endings
        try {
            $content = [System.IO.File]::ReadAllBytes($file.FullName)
            
            # Skip empty files
            if ($content.Length -eq 0) {
                continue
            }
            
            # Check if file ends with any form of newline
            # Valid endings: CRLF (0x0D 0x0A), LF (0x0A), or CR (0x0D)
            $endsWithNewline = $false
            $needsFixing = $false
            $lastByte = $content[$content.Length - 1]
            
            if ($lastByte -eq 0x0A) {
                # Ends with LF
                $endsWithNewline = $true
                # Check if it's CRLF (preferred) or just LF
                if ($content.Length -ge 2) {
                    $secondLastByte = $content[$content.Length - 2]
                    if ($secondLastByte -ne 0x0D) {
                        # It's LF only, should be CRLF
                        $needsFixing = $true
                    }
                }
                else {
                    # Single byte file ending with LF, should be CRLF
                    $needsFixing = $true
                }
            }
            elseif ($lastByte -eq 0x0D) {
                # Ends with CR only (old Mac style) - needs LF
                $endsWithNewline = $true
                $needsFixing = $true
            }
            else {
                # Does not end with any newline character
                $endsWithNewline = $false
                $needsFixing = $true
            }
            
            if (-not $endsWithNewline -or $needsFixing) {
                $invalidFiles += $file.FullName
                Write-Host "  [FAIL] $($file.FullName)" -ForegroundColor Red
                
                # Provide helpful information about the actual ending
                if (-not $endsWithNewline) {
                    Write-Host "         File does not end with a newline (ends abruptly)" -ForegroundColor Yellow
                }
                elseif ($lastByte -eq 0x0A -and $needsFixing) {
                    Write-Host "         File ends with LF only (should be CRLF)" -ForegroundColor Yellow
                }
                elseif ($lastByte -eq 0x0D) {
                    Write-Host "         File ends with CR only (should be CRLF)" -ForegroundColor Yellow
                }
                
                # Attempt to fix if -Fix flag is set
                if ($Fix) {
                    try {
                        $bytesToAppend = @()
                        $newContent = $content
                        
                        if (-not $endsWithNewline) {
                            # No newline at all - append CRLF
                            $bytesToAppend = @(0x0D, 0x0A)
                        }
                        elseif ($lastByte -eq 0x0A) {
                            # Ends with LF - insert CR before it
                            $newContent = $content[0..($content.Length - 2)]
                            $bytesToAppend = @(0x0D, 0x0A)
                        }
                        elseif ($lastByte -eq 0x0D) {
                            # Ends with CR only - append LF
                            $bytesToAppend = @(0x0A)
                        }
                        
                        # Combine and write back
                        $finalContent = $newContent + $bytesToAppend
                        [System.IO.File]::WriteAllBytes($file.FullName, $finalContent)
                        
                        Write-Host "         [FIXED] File has been corrected with CRLF" -ForegroundColor Green
                        $fixedFiles += $file.FullName
                    }
                    catch {
                        Write-Host "         [ERROR] Failed to fix file: $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
            }
        }
        catch {
            Write-Host "  [ERROR] Failed to read file: $($file.FullName)" -ForegroundColor Red
            Write-Host "          Error: $($_.Exception.Message)" -ForegroundColor Red
            $invalidFiles += $file.FullName
        }
    }
}

# Print summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Validation Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total source files checked: $totalFiles" -ForegroundColor White
Write-Host "Files skipped (dependencies): $skippedFiles" -ForegroundColor Cyan

if ($Fix) {
    Write-Host "Files fixed: $($fixedFiles.Count)" -ForegroundColor $(if ($fixedFiles.Count -gt 0) { "Green" } else { "White" })
    $remainingInvalid = $invalidFiles.Count - $fixedFiles.Count
    Write-Host "Files without proper newline (could not fix): $remainingInvalid" -ForegroundColor $(if ($remainingInvalid -eq 0) { "Green" } else { "Red" })
}
else {
    Write-Host "Files without proper newline: $($invalidFiles.Count)" -ForegroundColor $(if ($invalidFiles.Count -eq 0) { "Green" } else { "Red" })
}

if ($Fix -and $fixedFiles.Count -gt 0) {
    Write-Host ""
    Write-Host "The following files were fixed:" -ForegroundColor Green
    foreach ($file in $fixedFiles) {
        Write-Host "  - $file" -ForegroundColor Green
    }
}

# Determine remaining invalid files (those that weren't fixed or couldn't be fixed)
$remainingInvalidFiles = @()
if ($Fix) {
    $remainingInvalidFiles = $invalidFiles | Where-Object { $_ -notin $fixedFiles }
}
else {
    $remainingInvalidFiles = $invalidFiles
}

if ($remainingInvalidFiles.Count -gt 0) {
    Write-Host ""
    Write-Host "The following files do not end with a proper newline:" -ForegroundColor Red
    foreach ($file in $remainingInvalidFiles) {
        Write-Host "  - $file" -ForegroundColor Red
    }
    Write-Host ""
    if (-not $Fix) {
        Write-Host "To fix these files automatically, run with -Fix parameter." -ForegroundColor Yellow
        Write-Host "Or manually ensure they end with a newline (CRLF on Windows)." -ForegroundColor Yellow
        Write-Host "In Visual Studio: ensure cursor can go one line past the last line of code." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "[VALIDATION FAILED]" -ForegroundColor Red -BackgroundColor Black
    exit 1
}
else {
    Write-Host ""
    if ($Fix -and $fixedFiles.Count -gt 0) {
        Write-Host "[VALIDATION PASSED] All files fixed successfully" -ForegroundColor Green -BackgroundColor Black
    }
    else {
        Write-Host "[VALIDATION PASSED]" -ForegroundColor Green -BackgroundColor Black
    }
    exit 0
}
