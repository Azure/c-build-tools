# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS
    Validates that SRS requirement text is consistent between markdown files and C code.

.DESCRIPTION
    This script checks that Software Requirements Specification (SRS) tags have identical
    text content in both requirement documents (*.md in devdoc/) and implementation files (*.c, *_ut.c, *_int.c).
    
    The script:
    1. Finds all SRS tags in requirement markdown files
    2. Locates corresponding SRS tags in C source files
    3. Strips markdown formatting (backticks, bold, italics) from markdown text
    4. Compares the text content for consistency
    5. Reports or fixes inconsistencies
    
    When the -Fix switch is provided, the script will update C code comments to match
    the requirement document text (after stripping markdown formatting).

.PARAMETER RepoRoot
    The root directory of the repository to validate.

.PARAMETER ExcludeFolders
    Comma-separated list of additional folders to exclude from validation.

.PARAMETER Fix
    If specified, automatically update C code comments to match requirement documents.

.EXAMPLE
    .\validate_srs_consistency.ps1 -RepoRoot "C:\repo"
    
    Validates all SRS tags and reports inconsistencies.

.EXAMPLE
    .\validate_srs_consistency.ps1 -RepoRoot "C:\repo" -Fix
    
    Validates and automatically fixes inconsistencies in C code comments.

.NOTES
    Returns exit code 0 if all requirements are consistent (or were fixed), 1 if validation fails.
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
Write-Host "SRS Requirement Consistency Validation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Repository Root: $RepoRoot" -ForegroundColor White
Write-Host "Fix Mode: $($Fix.IsPresent)" -ForegroundColor White
Write-Host ""

# Parse excluded directories (default: deps, cmake)
$excludeDirs = $ExcludeFolders -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

Write-Host "Excluded directories: $($excludeDirs -join ', ')" -ForegroundColor White
Write-Host ""

# Function to check if a path should be excluded
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

# Function to strip markdown formatting from text
function Remove-MarkdownFormatting {
    param([string]$Text)

    # Remove bold markers (**text**)
    # Handle cases with asterisks used in text (e.g., pointers like "char*" or multiplication "1 * 2")
    $Text = $Text -replace '\*\*([^*]+)\*\*', '$1'
    
    # Remove italics markers (*word*) - only match word boundaries to avoid C pointers
    $Text = $Text -replace '\*(\w+)\*', '$1'
    
    # Remove backticks
    $Text = $Text -replace '\`([^\`]+)\`', '$1'

    # Normalize whitespace (multiple spaces to single space)
    # Trim leading/trailing whitespace
    $Text = $Text.Trim()

    return $Text
}

# Function to extract SRS tags from markdown content
function Get-SrsTagsFromMarkdown {
    param([string]$Content, [string]$FilePath)
    
    $srsTags = @()
    
    # Pattern to match SRS tags in markdown: **SRS_MODULE_ID_NUM: [** text **]**
    $pattern = '\*\*SRS_([A-Z0-9_]+)_(\d{2})_(\d{3}):\s*\[\*\*\s*((?:(?!\*\*\]\*\*).)+?)\s*\*\*\]\*\*'

    $matches = [regex]::Matches($Content, $pattern)

    foreach ($match in $matches) {
        $module = $match.Groups[1].Value
        $devId = $match.Groups[2].Value
        $reqId = $match.Groups[3].Value
        $text = $match.Groups[4].Value
        
        $srsTag = "SRS_${module}_${devId}_${reqId}"
        $cleanText = Remove-MarkdownFormatting $text
        
        $srsTags += [PSCustomObject]@{
            Tag = $srsTag
            RawText = $text
            CleanText = $cleanText
            FilePath = $FilePath
        }
    }
    
    return $srsTags
}

# Function to extract SRS tags from C code
function Get-SrsTagsFromCCode {
    param([string]$Content, [string]$FilePath)
    
    $srsTags = @()
    
    # Pattern to match SRS tags in C comments: /* Codes_SRS_MODULE_ID_NUM: [ text ]*/
    # or /* Tests_SRS_MODULE_ID_NUM: [ text ]*/ (for test files)
    $blockPattern = '/\*+\s*(Codes|Tests)_SRS_([A-Z0-9_]+)_(\d{2})_(\d{3}):\s*\[(\s*)([^\]]*?)(\s*)(\]?)\s*\*+/'

    # Pattern for line comments: // Codes_SRS_MODULE_ID_NUM: [ text ]
    $linePattern = '//\s*(Codes|Tests)_SRS_([A-Z0-9_]+)_(\d{2})_(\d{3}):\s*\[(\s*)([^\]\s\r\n]+(?:\s+[^\]\s\r\n]+)*)(\s*)(\]?)'
    
    # Match both block and line comments
    $blockMatches = [regex]::Matches($Content, $blockPattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    $lineMatches = [regex]::Matches($Content, $linePattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    
    # Combine all matches
    $allMatches = @($blockMatches) + @($lineMatches)
    
    foreach ($match in $allMatches) {
        $prefix = $match.Groups[1].Value  # Captures "Tests" or "Codes"
        $module = $match.Groups[2].Value
        $devId = $match.Groups[3].Value
        $reqId = $match.Groups[4].Value
        $text = $match.Groups[6].Value  # Text content (group 5 is leading whitespace)
        
        $srsTag = "SRS_${module}_${devId}_${reqId}"
        
        # Normalize whitespace in C code text
        $cleanText = $text -replace '\s+', ' '
        $cleanText = $cleanText.Trim()
        
        $srsTags += [PSCustomObject]@{
            Tag = $srsTag
            Text = $cleanText
            Prefix = $prefix  # Store the original prefix (Tests or Codes)
            FilePath = $FilePath
            OriginalMatch = $match.Value
            MatchIndex = $match.Index
        }
    }
    
    return $srsTags
}

# Initialize counters
$totalRequirements = 0
$inconsistentRequirements = @()
$fixedRequirements = @()
$duplicateTagsCount = 0
$skippedFiles = 0

Write-Host "Phase 1: Scanning requirement documents..." -ForegroundColor White

# Get all markdown files in devdoc directories
$requirementFiles = Get-ChildItem -Path $RepoRoot -Recurse -Filter "*.md" -ErrorAction SilentlyContinue | Where-Object {
    $_.Directory.Name -eq "devdoc" -and -not (Test-IsExcluded $_.FullName $RepoRoot $excludeDirs)
}

Write-Host "Found $($requirementFiles.Count) requirement documents" -ForegroundColor White

# Build a hashtable of all SRS requirements from markdown
$srsRequirements = @{}

foreach ($mdFile in $requirementFiles) {
    $content = Get-Content -Path $mdFile.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }
    
    $tags = Get-SrsTagsFromMarkdown -Content $content -FilePath $mdFile.FullName
    
    foreach ($tag in $tags) {
        if (-not $srsRequirements.ContainsKey($tag.Tag)) {
            $srsRequirements[$tag.Tag] = $tag
            $totalRequirements++
        } else {
            # Duplicate SRS tag in markdown - use first occurrence
            Write-Host "  [WARN] Duplicate SRS tag $($tag.Tag) found in $($mdFile.FullName)" -ForegroundColor Yellow
            $duplicateTagsCount++
        }
    }
}

Write-Host "Found $totalRequirements unique SRS requirements" -ForegroundColor White
Write-Host ""

Write-Host "Phase 2: Scanning C source files..." -ForegroundColor White

# Get all C source files
$cFiles = Get-ChildItem -Path $RepoRoot -Recurse -Include "*.c" -ErrorAction SilentlyContinue | Where-Object {
    -not (Test-IsExcluded $_.FullName $RepoRoot $excludeDirs)
}

Write-Host "Found $($cFiles.Count) C source files to scan" -ForegroundColor White
Write-Host ""

$filesWithInconsistencies = @{}

foreach ($cFile in $cFiles) {
    $content = Get-Content -Path $cFile.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }
    
    $cTags = Get-SrsTagsFromCCode -Content $content -FilePath $cFile.FullName
    
    foreach ($cTag in $cTags) {
        # Check if this SRS tag exists in requirements
        if ($srsRequirements.ContainsKey($cTag.Tag)) {
            $requirement = $srsRequirements[$cTag.Tag]
            
            # Compare text (case-insensitive, whitespace-normalized)
            if ($cTag.Text -ne $requirement.CleanText) {
                $inconsistency = [PSCustomObject]@{
                    Tag = $cTag.Tag
                    Prefix = $cTag.Prefix
                    CFile = $cFile.FullName
                    MdFile = $requirement.FilePath
                    CText = $cTag.Text
                    MdText = $requirement.CleanText
                    OriginalMatch = $cTag.OriginalMatch
                    MatchIndex = $cTag.MatchIndex
                }
                
                $inconsistentRequirements += $inconsistency
                
                if (-not $filesWithInconsistencies.ContainsKey($cFile.FullName)) {
                    $filesWithInconsistencies[$cFile.FullName] = @()
                }
                $filesWithInconsistencies[$cFile.FullName] += $inconsistency
            }
        }
    }
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Validation Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total SRS requirements: $totalRequirements" -ForegroundColor White
Write-Host "C source files scanned: $($cFiles.Count)" -ForegroundColor White
Write-Host "Inconsistencies found: $($inconsistentRequirements.Count)" -ForegroundColor White
if ($duplicateTagsCount -gt 0) {
    Write-Host "Duplicate SRS tags found: $duplicateTagsCount" -ForegroundColor Yellow
}
Write-Host ""

if ($inconsistentRequirements.Count -gt 0) {
    Write-Host "Files with inconsistencies: $($filesWithInconsistencies.Count)" -ForegroundColor Yellow
    Write-Host ""
    
    if ($Fix) {
        Write-Host "Fix mode: Updating C source files..." -ForegroundColor Cyan
        Write-Host ""
        
        # Group inconsistencies by file and fix them
        foreach ($filePath in $filesWithInconsistencies.Keys) {
            $fileInconsistencies = $filesWithInconsistencies[$filePath]
            
            # Sort by match index in reverse order to avoid offset issues
            $fileInconsistencies = $fileInconsistencies | Sort-Object -Property MatchIndex -Descending
            
            try {
                $content = Get-Content -Path $filePath -Raw
                $modified = $false
                
                foreach ($inconsistency in $fileInconsistencies) {
                    # Build the correct comment by preserving the original format
                    # Use regex to replace only the text portion while keeping the comment structure
                    $oldComment = $inconsistency.OriginalMatch
                    
                    # Detect the comment type and structure
                    # Note: Make closing ] optional to handle malformed comments
                    # Capture whitespace separately to preserve exact formatting
                    if ($oldComment -match '^(/\*+)(\s*)((?:Codes|Tests)_SRS_[A-Z0-9_]+_\d{2}_\d{3}):(\s*)\[(\s*)([^\]]*?)(\s*)(\]?)(\s*\*+/)$') {
                        $commentStart = $matches[1]
                        $ws1 = $matches[2]  # whitespace between /* and SRS tag
                        $srsPrefix = $matches[3]
                        $ws2 = $matches[4]  # whitespace after colon
                        $ws3 = $matches[5]  # whitespace after opening [
                        $oldText = $matches[6]
                        $ws4 = $matches[7]  # whitespace before closing ]
                        $closingBracket = $matches[8]
                        $closingBracket = $matches[8]
                        $commentEnd = $matches[9]
                        
                        # Build the corrected comment preserving all original whitespace
                        $correctComment = "$commentStart$ws1$srsPrefix`:$ws2[$ws3$($inconsistency.MdText)$ws4]$commentEnd"
                    }
                    elseif ($oldComment -match '^(//)(\s*)((?:Codes|Tests)_SRS_[A-Z0-9_]+_\d{2}_\d{3}):(\s*)\[(\s*)([^\]\s\r\n]+(?:\s+[^\]\s\r\n]+)*)(\s*)(\]?)$') {
                        $commentStart = $matches[1]
                        $ws1 = $matches[2]  # whitespace between // and SRS tag
                        $srsPrefix = $matches[3]
                        $ws2 = $matches[4]  # whitespace after colon
                        $ws3 = $matches[5]  # whitespace after opening [
                        $oldText = $matches[6]
                        $ws4 = $matches[7]  # whitespace before closing ]
                        $closingBracket = $matches[8]
                        
                        # Build the corrected comment for line-style comments, preserving whitespace
                        $correctComment = "$commentStart$ws1$srsPrefix`:$ws2[$ws3$($inconsistency.MdText)$ws4]"
                    }
                    else {
                        Write-Host "  [ERROR] Could not parse comment format in $([System.IO.Path]::GetFileName($filePath))" -ForegroundColor Red
                        Write-Host "          Tag: $($inconsistency.Tag)" -ForegroundColor Red
                        Write-Host "          Comment: $oldComment" -ForegroundColor Red
                        continue
                    }
                    
                    if ($content.Contains($oldComment)) {
                        $content = $content.Replace($oldComment, $correctComment)
                        $modified = $true
                        $fixedRequirements += $inconsistency.Tag
                        Write-Host "  [FIXED] $($inconsistency.Tag) in $([System.IO.Path]::GetFileName($filePath))" -ForegroundColor Green
                        Write-Host "         Old: '$($inconsistency.CText)'" -ForegroundColor Gray
                        Write-Host "         New: '$($inconsistency.MdText)'" -ForegroundColor Gray
                    } else {
                        Write-Host "  [ERROR] Could not locate text to replace in $([System.IO.Path]::GetFileName($filePath))" -ForegroundColor Red
                        Write-Host "          Tag: $($inconsistency.Tag)" -ForegroundColor Red
                    }
                }
                
                if ($modified) {
                    Set-Content -Path $filePath -Value $content -NoNewline
                }
            }
            catch {
                Write-Host "  [ERROR] Failed to update $filePath : $_" -ForegroundColor Red
            }
        }
        
        Write-Host ""
        Write-Host "Fixed $($fixedRequirements.Count) inconsistencies" -ForegroundColor Green
    } else {
        Write-Host "Inconsistent SRS requirements found:" -ForegroundColor Red
        Write-Host ""
        
        # Show all inconsistencies
        foreach ($item in $inconsistentRequirements) {
            Write-Host "  [FAIL] $($item.Tag)" -ForegroundColor Red
            Write-Host "         C file: $($item.CFile)" -ForegroundColor White
            Write-Host "         MD file: $($item.MdFile)" -ForegroundColor White
            Write-Host "         C text:  '$($item.CText)'" -ForegroundColor Yellow
            Write-Host "         MD text: '$($item.MdText)'" -ForegroundColor Cyan
            Write-Host ""
        }
        
        Write-Host "To fix these inconsistencies automatically, run with -Fix parameter." -ForegroundColor Cyan
        Write-Host "This will update C code comments to match the requirement documents." -ForegroundColor Cyan
    }
}

Write-Host ""

$unfixedCount = $inconsistentRequirements.Count - $fixedRequirements.Count

if ($unfixedCount -eq 0) {
    Write-Host "[VALIDATION PASSED]" -ForegroundColor Green
    exit 0
} else {
    Write-Host "[VALIDATION FAILED]" -ForegroundColor Red
    if ($Fix) {
        Write-Host "$unfixedCount inconsistency(ies) could not be fixed automatically." -ForegroundColor Yellow
    }
    exit 1
}
