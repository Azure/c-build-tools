# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS
    Validates that all SRS requirement tags are unique across all markdown files.

.DESCRIPTION
    This script checks that Software Requirements Specification (SRS) tags are used only once
    across all requirement documents (*.md in devdoc/ folders).

    The script:
    1. Finds all SRS tags in requirement markdown files
    2. Reports any duplicate SRS tags found
    3. Returns an error if duplicates are found (does not attempt to fix)

    This script will NEVER fix duplicates automatically - it only reports them as errors.
    Manual intervention is required to resolve duplicate SRS tags.

.PARAMETER RepoRoot
    The root directory of the repository to validate.

.PARAMETER ExcludeFolders
    Comma-separated list of additional folders to exclude from validation.

.PARAMETER Fix
    Ignored - this script never fixes duplicates automatically.

.EXAMPLE
    .\validate_srs_uniqueness.ps1 -RepoRoot "C:\repo"

    Validates all SRS tags for uniqueness and reports duplicates as errors.

.NOTES
    Returns exit code 0 if all SRS tags are unique, 1 if duplicates are found.
    This script deliberately does not support automatic fixing of duplicates.
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

# Validate repository root exists
if (-not (Test-Path $RepoRoot)) {
    Write-Error "Repository root path '$RepoRoot' does not exist"
    exit 1
}

Write-Host "========================================"
Write-Host "SRS Tag Uniqueness Validation"
Write-Host "========================================"
Write-Host "Repository Root: $RepoRoot"
if ($Fix) {
    Write-Host "Fix Mode: Requested but IGNORED - this script never auto-fixes duplicates"
} else {
    Write-Host "Fix Mode: False"
}
Write-Host ""

# Parse excluded directories (default: deps, cmake)
$defaultExcludes = @("deps", "cmake")
$additionalExcludes = if ($ExcludeFolders) { $ExcludeFolders -split "," | ForEach-Object { $_.Trim() } } else { @() }
$allExcludes = $defaultExcludes + $additionalExcludes
Write-Host "Excluded directories: $($allExcludes -join ', ')"
Write-Host ""

function Test-IsExcluded {
    param([string]$Path, [string]$RepoRoot, [array]$ExcludeDirs)
    
    $relativePath = $Path.Substring($RepoRoot.Length).TrimStart('\', '/')
    foreach ($excludeDir in $ExcludeDirs) {
        if ($relativePath -like "$excludeDir\*" -or $relativePath -like "$excludeDir/*") {
            return $true
        }
    }
    return $false
}

function Get-SrsTagsFromMarkdown {
    param([string]$Content, [string]$FilePath)

    $srsTags = @()
    
    # Pattern to match SRS tags: **SRS_MODULE_ID_NUM: [ text ]**
    $pattern = '\*\*SRS_([A-Z0-9_]+)_(\d{2})_(\d{3}):\s*\[\s*(.*?)\s*\]\s*\*\*'
    
    $tagMatches = [regex]::Matches($Content, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    
    foreach ($match in $tagMatches) {
        $module = $match.Groups[1].Value
        $devId = $match.Groups[2].Value
        $reqId = $match.Groups[3].Value
        $text = $match.Groups[4].Value
        
        $srsTag = "SRS_${module}_${devId}_${reqId}"
        
        $srsTags += [PSCustomObject]@{
            Tag = $srsTag
            Text = $text
            FilePath = $FilePath
            LineNumber = ($Content.Substring(0, $match.Index) -split "`n").Length
        }
    }
    
    return $srsTags
}

Write-Host "Scanning requirement documents..."

# Find all markdown files in devdoc directories
$markdownFiles = Get-ChildItem -Path $RepoRoot -Filter "*.md" -Recurse | Where-Object { 
    $_.Directory.Name -eq "devdoc" -and -not (Test-IsExcluded -Path $_.FullName -RepoRoot $RepoRoot -ExcludeDirs $allExcludes)
}

Write-Host "Found $($markdownFiles.Count) requirement documents"

# Dictionary to track SRS tags and their locations
$srsTagLocations = @{}
$duplicateFound = $false
$totalTags = 0

foreach ($mdFile in $markdownFiles) {
    $content = Get-Content $mdFile.FullName -Raw -Encoding UTF8
    $srsTags = Get-SrsTagsFromMarkdown -Content $content -FilePath $mdFile.FullName
    
    foreach ($srsTag in $srsTags) {
        $totalTags++
        
        if ($srsTagLocations.ContainsKey($srsTag.Tag)) {
            # Duplicate found!
            $duplicateFound = $true
            $firstLocation = $srsTagLocations[$srsTag.Tag]
            
            Write-Host ""
            Write-Host "  [ERROR] Duplicate SRS tag: $($srsTag.Tag)" -ForegroundColor Red
            Write-Host "          First occurrence: $([System.IO.Path]::GetFileName($firstLocation.FilePath)):$($firstLocation.LineNumber)" -ForegroundColor Red
            Write-Host "          Duplicate found in: $([System.IO.Path]::GetFileName($srsTag.FilePath)):$($srsTag.LineNumber)" -ForegroundColor Red
        } else {
            # First occurrence of this tag
            $srsTagLocations[$srsTag.Tag] = $srsTag
        }
    }
}

Write-Host ""
Write-Host "========================================"
Write-Host "Validation Summary"
Write-Host "========================================"
Write-Host "Total requirement documents scanned: $($markdownFiles.Count)"
Write-Host "Total SRS tags found: $totalTags"
Write-Host "Unique SRS tags: $($srsTagLocations.Count)"

if ($duplicateFound) {
    Write-Host ""
    Write-Host "[VALIDATION FAILED]" -ForegroundColor Red
    Write-Host "Duplicate SRS tags were found. Each SRS tag must be unique across all requirement documents." -ForegroundColor Red
    Write-Host "Please manually resolve the duplicates by:" -ForegroundColor Yellow
    Write-Host "1. Assigning new unique SRS IDs to duplicate requirements" -ForegroundColor Yellow
    Write-Host "2. Or consolidating duplicate requirements if they are truly the same" -ForegroundColor Yellow
    exit 1
} else {
    Write-Host ""
    Write-Host "[VALIDATION PASSED]" -ForegroundColor Green
    exit 0
}