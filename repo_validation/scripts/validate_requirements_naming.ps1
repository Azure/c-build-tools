# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS
    Validates that requirement documents in devdoc folders follow the naming convention {module_name}_requirements.md.

.DESCRIPTION
    This script checks all markdown files in devdoc directories to ensure that files containing
    SRS (Software Requirements Specification) tags follow the naming convention: {module_name}_requirements.md
    
    A file is considered a requirements document if it contains SRS tags matching the pattern:
    SRS_{MODULE}_{DEVID}_{REQID} (e.g., SRS_MY_MODULE_01_001)
    
    The script automatically excludes dependency directories to avoid modifying third-party code.
    
    When the -Fix switch is provided, the script will automatically rename files to follow
    the {module_name}_requirements.md convention.

.PARAMETER RepoRoot
    The root directory of the repository to validate.

.PARAMETER ExcludeFolders
    Comma-separated list of additional folders to exclude from validation.

.PARAMETER Fix
    If specified, automatically rename files that don't follow the naming convention.

.EXAMPLE
    .\validate_requirements_naming.ps1 -RepoRoot "C:\repo"
    
    Validates all requirement documents and reports errors.

.EXAMPLE
    .\validate_requirements_naming.ps1 -RepoRoot "C:\repo" -Fix
    
    Validates and automatically renames requirement documents that don't follow the convention.

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
Write-Host "Requirements Document Naming Validation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Repository Root: $RepoRoot" -ForegroundColor White
Write-Host "Fix Mode: $($Fix.IsPresent)" -ForegroundColor White
Write-Host ""

# Parse excluded directories (default: deps, cmake)
$excludeDirs = @()
if ($ExcludeFolders -eq "") {
    # Use defaults if not specified
    $excludeDirs = @("deps", "cmake")
}
else {
    $excludeDirs = $ExcludeFolders -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
}

Write-Host "Excluded directories: $($excludeDirs -join ', ')" -ForegroundColor White
Write-Host ""

# Initialize counters
$totalFiles = 0
$invalidFiles = @()
$fixedFiles = @()
$skippedFiles = 0

# SRS tag pattern to identify requirements documents
$srsPattern = 'SRS_[A-Z0-9_]+_\d{2}_\d{3}'

Write-Host "Searching for requirement documents in devdoc folders..." -ForegroundColor White

# Get all markdown files in devdoc directories
$allFiles = Get-ChildItem -Path $RepoRoot -Recurse -Filter "*.md" -ErrorAction SilentlyContinue | Where-Object {
    $_.Directory.Name -eq "devdoc"
}

Write-Host "Found $($allFiles.Count) markdown files in devdoc folders" -ForegroundColor White
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
    
    # Read file content to check for SRS tags
    try {
        $content = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
    }
    catch {
        Write-Host "  [WARN] Cannot read file: $($file.FullName)" -ForegroundColor Yellow
        continue
    }
    
    # Check if file contains SRS tags
    if ($content -match $srsPattern) {
        # This is a requirements document - check naming convention
        if ($file.Name -notmatch "_requirements\.md$") {
            # Extract module name from current filename (remove .md extension)
            $currentBaseName = $file.BaseName
            $newFileName = "${currentBaseName}_requirements.md"
            $newFilePath = Join-Path -Path $file.Directory.FullName -ChildPath $newFileName
            
            Write-Host "  [FAIL] $($file.FullName)" -ForegroundColor Red
            Write-Host "         Should be renamed to: $newFileName" -ForegroundColor Yellow
            
            $invalidFiles += $file.FullName
            
            if ($Fix) {
                try {
                    # Check if target file already exists
                    if (Test-Path $newFilePath) {
                        Write-Host "         [ERROR] Target file already exists: $newFileName" -ForegroundColor Red
                        Write-Host "         Skipping rename to avoid overwriting existing file." -ForegroundColor Yellow
                    }
                    else {
                        Rename-Item -Path $file.FullName -NewName $newFileName -ErrorAction Stop
                        Write-Host "         [FIXED] Renamed to: $newFileName" -ForegroundColor Green
                        $fixedFiles += $file.FullName
                    }
                }
                catch {
                    Write-Host "         [ERROR] Failed to rename: $_" -ForegroundColor Red
                }
            }
        }
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Validation Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total markdown files in devdoc: $totalFiles" -ForegroundColor White
Write-Host "Files skipped (excluded directories): $skippedFiles" -ForegroundColor White

if ($Fix -and $fixedFiles.Count -gt 0) {
    Write-Host "Files renamed successfully: $($fixedFiles.Count)" -ForegroundColor Green
}

if ($invalidFiles.Count -gt 0 -and -not $Fix) {
    Write-Host "Files with incorrect naming: $($invalidFiles.Count)" -ForegroundColor Red
    Write-Host ""
    Write-Host "The following requirement documents should be renamed:" -ForegroundColor Yellow
    foreach ($file in $invalidFiles) {
        $fileName = Split-Path -Leaf $file
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
        $newName = "${baseName}_requirements.md"
        Write-Host "  - $file" -ForegroundColor White
        Write-Host "    Should be: $newName" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "To fix these files automatically, run with -Fix parameter." -ForegroundColor Cyan
    Write-Host ""
}

$unfixedFiles = $invalidFiles.Count - $fixedFiles.Count

if ($unfixedFiles -eq 0) {
    Write-Host "[VALIDATION PASSED]" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "[VALIDATION FAILED]" -ForegroundColor Red
    if ($Fix) {
        Write-Host "$unfixedFiles file(s) could not be fixed automatically." -ForegroundColor Yellow
    }
    exit 1
}
