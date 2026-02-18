# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS
    Validates SRS requirement consistency and tag placement between markdown files and C code.

.DESCRIPTION
    This script performs two validations:
    
    1. **Consistency**: Checks that SRS tags have identical text content in both requirement 
       documents (*.md in devdoc/) and implementation files (*.c, *_ut.c, *_int.c).
    2. **Tag Placement**: Checks that Codes_SRS_ tags only appear in production code and 
       Tests_SRS_ tags only appear in test files.
    
    The script:
    1. Finds all SRS tags in requirement markdown files
    2. Locates corresponding SRS tags in C source files
    3. Strips markdown formatting (backticks, bold, italics) from markdown text
    4. Compares the text content for consistency
    5. Validates that Codes_SRS_ and Tests_SRS_ tags are in the correct file types
    6. Reports or fixes inconsistencies
    
    When the -Fix switch is provided, the script will update C code comments to match
    the requirement document text (after stripping markdown formatting).
    Tag placement violations cannot be auto-fixed.

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
    # Use a loop to handle multiple bold sections and nested cases
    # Match any text between ** markers, including text with spaces and special characters
    # The pattern [^*] prevents matching single asterisks (like in pointers)
    while ($Text -match '\*\*(.+?)\*\*') {
        $Text = $Text -replace '\*\*(.+?)\*\*', '$1'
    }
    
    # Remove italics markers (*word*) - only match word boundaries to avoid C pointers
    $Text = $Text -replace '\*(\w+)\*', '$1'
    
    # Remove backticks
    $Text = $Text -replace '\`([^\`]+)\`', '$1'
    
    # Unescape markdown escaped characters
    # Any backslash followed by a character should be unescaped (e.g., \< -> <, \> -> >, \\ -> \, \* -> *)
    # This handles all markdown escape sequences to match unescaped text in C code
    $Text = $Text -replace '\\(.)', '$1'

    # Normalize whitespace (multiple spaces to single space)
    $Text = $Text -replace '\s+', ' '
    
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
    # Allow optional whitespace before colon to handle cases like "SRS_TAG :" and "SRS_TAG:"
    # NOTE: The regex uses greedy .* to capture the entire comment including any garbage/duplication
    # The pattern will match from /* to the LAST ]*/ on the line, capturing any garbage in between
    # Pattern to match SRS tags in C comments: /* Codes_SRS_MODULE_ID_NUM: [ text ]*/
    # or /* Tests_SRS_MODULE_ID_NUM: [ text ]*/ (for test files)
    # Allow optional whitespace before colon to handle cases like "SRS_TAG :" and "SRS_TAG:"
    # NOTE: Use [^\r\n]* to limit matching to single line (prevents matching across multiple comments)
    # The pattern will match from /* to ]*/ on the SAME LINE ONLY
    $blockPattern = '/\*+\s*(Codes|Tests)_SRS_([A-Z0-9_]+)_(\d{2})_(\d{3})\s*:\s*\[(\s*)([^\r\n]*)(\s*)\](\s*\*+/)' 
    
    # Pattern for INCOMPLETE comments (missing closing bracket])
    # This pattern matches comments that have [ but no matching ] before the */
    # Uses [^\]\r\n]+ to ensure we don't match ] or cross line boundaries
    $incompleteBlockPattern = '/\*+\s*(Codes|Tests)_SRS_([A-Z0-9_]+)_(\d{2})_(\d{3})\s*:\s*\[(\s*)([^\]\r\n]+)(\s*\*+/)'

    # Pattern for line comments: // Codes_SRS_MODULE_ID_NUM: [ text ]
    # NOTE: Pattern captures text up to the LAST ] on the line (handles text containing ] characters)
    $linePattern = '//\s*(Codes|Tests)_SRS_([A-Z0-9_]+)_(\d{2})_(\d{3})\s*:\s*\[(\s*)(.+?)(\s*)\](\s*)$'
    
    # Match both block and line comments
    $blockMatches = [regex]::Matches($Content, $blockPattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    $incompleteMatches = [regex]::Matches($Content, $incompleteBlockPattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    $lineMatches = [regex]::Matches($Content, $linePattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    
    # Combine all matches, but exclude incomplete matches that overlap with complete matches
    $allMatches = @($blockMatches) + @($lineMatches)
    
    # Add incomplete matches only if they don't overlap with complete matches
    foreach ($incompleteMatch in $incompleteMatches) {
        $overlaps = $false
        foreach ($completeMatch in $blockMatches) {
            if ($incompleteMatch.Index -ge $completeMatch.Index -and 
                $incompleteMatch.Index -lt ($completeMatch.Index + $completeMatch.Length)) {
                $overlaps = $true
                break
            }
        }
        if (-not $overlaps) {
            $allMatches += $incompleteMatch
        }
    }
    
    foreach ($match in $allMatches) {
        $prefix = $match.Groups[1].Value  # Captures "Tests" or "Codes"
        $module = $match.Groups[2].Value
        $devId = $match.Groups[3].Value
        $reqId = $match.Groups[4].Value
        $text = $match.Groups[6].Value  # Text content (group 5 is leading whitespace)
        
        $srsTag = "SRS_${module}_${devId}_${reqId}"
        
        # Check if this is an incomplete comment (matched by incompleteBlockPattern)
        # Incomplete pattern has only 8 groups, complete pattern has 9
        $isIncomplete = $match.Groups.Count -eq 8
        
        # Check for duplication by looking at the original matched text
        # If the original match contains multiple ]*/  patterns, it's duplicated
        $hasDuplication = $false
        if ($match.Value -match '\]\*/.*?\]\*/') {
            $hasDuplication = $true
        }
        
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
            HasDuplication = $hasDuplication  # Flag to force fix even if text matches
            IsIncomplete = $isIncomplete  # Flag for missing closing bracket
        }
    }
    
    return $srsTags
}

# Function to determine if a file is a test file based on naming convention and path
function Test-IsTestFile {
    param([string]$FilePath)
    
    $fileName = [System.IO.Path]::GetFileName($FilePath)
    
    # Check file name patterns for test files
    if ($fileName -match '_ut\.c$' -or $fileName -match '_int\.c$') {
        return $true
    }
    
    return $false
}

# Initialize counters
$totalRequirements = 0
$inconsistentRequirements = @()
$fixedRequirements = @()
$duplicateTagsCount = 0
$tagPlacementViolations = @()
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
        # Check tag placement: Codes_SRS_ should not be in test files, Tests_SRS_ should not be in production files
        $isTestFile = Test-IsTestFile -FilePath $cFile.FullName
        $relativePath = $cFile.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
        
        if ($isTestFile -and $cTag.Prefix -eq "Codes") {
            $tagPlacementViolations += [PSCustomObject]@{
                FilePath = $relativePath
                Tag = "$($cTag.Prefix)_$($cTag.Tag)"
                Violation = "Codes_SRS_ tag found in test file (should use Tests_SRS_)"
            }
        }
        elseif (-not $isTestFile -and $cTag.Prefix -eq "Tests") {
            $tagPlacementViolations += [PSCustomObject]@{
                FilePath = $relativePath
                Tag = "$($cTag.Prefix)_$($cTag.Tag)"
                Violation = "Tests_SRS_ tag found in production file (should use Codes_SRS_)"
            }
        }

        # Check if this SRS tag exists in requirements
        if ($srsRequirements.ContainsKey($cTag.Tag)) {
            $requirement = $srsRequirements[$cTag.Tag]
            
            # Compare text (case-insensitive, whitespace-normalized)
            # Also treat comments with duplication or incomplete comments as inconsistent
            if ($cTag.Text -ne $requirement.CleanText -or $cTag.HasDuplication -or $cTag.IsIncomplete) {
                $inconsistency = [PSCustomObject]@{
                    Tag = $cTag.Tag
                    Prefix = $cTag.Prefix
                    CFile = $cFile.FullName
                    MdFile = $requirement.FilePath
                    CText = $cTag.Text
                    MdText = $requirement.CleanText
                    OriginalMatch = $cTag.OriginalMatch
                    MatchIndex = $cTag.MatchIndex
                    HasDuplication = $cTag.HasDuplication
                    IsIncomplete = $cTag.IsIncomplete
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
Write-Host "Tag placement violations: $($tagPlacementViolations.Count)" -ForegroundColor White
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
                    # Capture whitespace separately to preserve exact formatting
                    # Allow optional whitespace before colon to handle cases like "SRS_TAG :" and "SRS_TAG:"
                    # NOTE: The regex now uses greedy .* to capture the entire comment including any garbage/duplication
                    # This ensures we replace the ENTIRE malformed comment, not just the first part
                    if ($oldComment -match '^(/\*+)(\s*)((?:Codes|Tests)_SRS_[A-Z0-9_]+_\d{2}_\d{3})(\s*):(\s*)\[(\s*)(.*)(\s*)\](\s*\*+/)$') {
                        # Complete comment with closing bracket
                        $commentStart = $matches[1]
                        $ws1 = $matches[2]  # whitespace between /* and SRS tag
                        $srsPrefix = $matches[3]
                        $wsBeforeColon = $matches[4]  # whitespace before colon
                        $ws2 = $matches[5]  # whitespace after colon
                        $ws3 = $matches[6]  # whitespace after opening [
                        $oldText = $matches[7]  # This now includes any garbage/duplication
                        $ws4 = $matches[8]  # whitespace before closing ]
                        $commentEnd = $matches[9]
                        
                        # Build the corrected comment preserving all original whitespace
                        $correctComment = "$commentStart$ws1$srsPrefix$wsBeforeColon`:$ws2[$ws3$($inconsistency.MdText)$ws4]$commentEnd"
                    }
                    elseif ($oldComment -match '^(/\*+)(\s*)((?:Codes|Tests)_SRS_[A-Z0-9_]+_\d{2}_\d{3})(\s*):(\s*)\[(\s*)([^\]]+)(\s*\*+/)$') {
                        # Incomplete comment without closing bracket
                        $commentStart = $matches[1]
                        $ws1 = $matches[2]
                        $srsPrefix = $matches[3]
                        $wsBeforeColon = $matches[4]
                        $ws2 = $matches[5]
                        $ws3 = $matches[6]
                        $oldText = $matches[7]
                        $commentEnd = " */"  # Always add proper closing
                        
                        # Build the corrected comment with closing bracket
                        $correctComment = "$commentStart$ws1$srsPrefix$wsBeforeColon`:$ws2[$ws3$($inconsistency.MdText) ]$commentEnd"
                    }
                    elseif ($oldComment -match '^(//)(\s*)((?:Codes|Tests)_SRS_[A-Z0-9_]+_\d{2}_\d{3})(\s*):(\s*)\[(\s*)([^\]\s\r\n]+(?:\s+[^\]\s\r\n]+)*)(\s*)(\]?)$') {
                        $commentStart = $matches[1]
                        $ws1 = $matches[2]  # whitespace between // and SRS tag
                        $srsPrefix = $matches[3]
                        $wsBeforeColon = $matches[4]  # whitespace before colon
                        $ws2 = $matches[5]  # whitespace after colon
                        $ws3 = $matches[6]  # whitespace after opening [
                        $oldText = $matches[7]
                        $ws4 = $matches[8]  # whitespace before closing ]
                        $closingBracket = $matches[9]
                        
                        # Build the corrected comment for line-style comments, preserving whitespace
                        $correctComment = "$commentStart$ws1$srsPrefix$wsBeforeColon`:$ws2[$ws3$($inconsistency.MdText)$ws4]"
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

# Report tag placement violations
if ($tagPlacementViolations.Count -gt 0) {
    $codesInTests = $tagPlacementViolations | Where-Object { $_.Violation -like "Codes_SRS_*" }
    $testsInProd = $tagPlacementViolations | Where-Object { $_.Violation -like "Tests_SRS_*" }
    
    Write-Host "SRS Tag Placement Violations:" -ForegroundColor Red
    Write-Host ""
    
    if ($codesInTests.Count -gt 0) {
        Write-Host "  Codes_SRS_ tags in test files ($($codesInTests.Count) violations):" -ForegroundColor Yellow
        foreach ($v in $codesInTests) {
            Write-Host "    $($v.FilePath): $($v.Tag)" -ForegroundColor White
        }
        Write-Host ""
    }
    
    if ($testsInProd.Count -gt 0) {
        Write-Host "  Tests_SRS_ tags in production files ($($testsInProd.Count) violations):" -ForegroundColor Yellow
        foreach ($v in $testsInProd) {
            Write-Host "    $($v.FilePath): $($v.Tag)" -ForegroundColor White
        }
        Write-Host ""
    }
    
    Write-Host "  Convention: Codes_SRS_ tags belong in production code, Tests_SRS_ tags belong in test files." -ForegroundColor Cyan
    Write-Host ""
}

$unfixedCount = $inconsistentRequirements.Count - $fixedRequirements.Count
$totalFailures = $unfixedCount + $tagPlacementViolations.Count

if ($totalFailures -eq 0) {
    Write-Host "[VALIDATION PASSED]" -ForegroundColor Green
    exit 0
} else {
    Write-Host "[VALIDATION FAILED]" -ForegroundColor Red
    if ($Fix -and $unfixedCount -gt 0) {
        Write-Host "$unfixedCount inconsistency(ies) could not be fixed automatically." -ForegroundColor Yellow
    }
    if ($tagPlacementViolations.Count -gt 0) {
        Write-Host "$($tagPlacementViolations.Count) tag placement violation(s) require manual correction." -ForegroundColor Yellow
    }
    exit 1
}
