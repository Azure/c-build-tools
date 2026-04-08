# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS
    Validates that SRS requirements in code comments do not contain raw backticks.

.DESCRIPTION
    This script checks all source code files (.h, .hpp, .c, .cpp, .cs) to ensure that
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
    Uses git grep for fast scanning when git is available.
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

# Parse excluded directories (default: deps, cmake)
$excludeDirs = $ExcludeFolders -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

Write-Host "Excluded directories: $($excludeDirs -join ', ')" -ForegroundColor White
Write-Host ""

# Initialize counters
$filesWithBackticks = @()
$fixedFiles = @()

# Pattern to match SRS requirements containing backticks
# The pattern checks for SRS tag followed by brackets containing backticks
$gitGrepPattern = 'SRS.*\[.*`.*\]'
$srsWithBacktickPattern = 'SRS_[A-Z_]+_\d+_\d+\s*:\s*\[[^\]]*`[^\]]*\]'

# Build git grep exclusion arguments
$gitExcludes = ($excludeDirs | ForEach-Object { ":(exclude)$_/" }) -join " "

# Check if we're in a git repository
$isGitRepo = $false
Push-Location $RepoRoot
try {
    $null = git rev-parse --git-dir 2>$null
    $isGitRepo = ($LASTEXITCODE -eq 0)
}
catch {
    $isGitRepo = $false
}

if ($isGitRepo) {
    Write-Host "Using git grep for fast scanning..." -ForegroundColor White
    
    # Use git grep for fast initial scan
    # Note: We use cmd /c to avoid PowerShell's backtick escaping issues
    $gitGrepCmd = "git grep -l -E `"$gitGrepPattern`" -- *.c *.h *.cpp *.hpp *.cs $gitExcludes 2>&1"
    $matchingFiles = @()
    
    try {
        $result = Invoke-Expression "cmd /c '$gitGrepCmd'"
        if ($LASTEXITCODE -eq 0 -and $result) {
            $matchingFiles = $result | Where-Object { $_ -ne "" }
        }
    }
    catch {
        Write-Host "  [WARN] git grep failed, falling back to file scan" -ForegroundColor Yellow
        $isGitRepo = $false
    }
    
    if ($isGitRepo -and $matchingFiles.Count -eq 0) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "Validation Summary" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "[VALIDATION PASSED]" -ForegroundColor Green
        Pop-Location
        exit 0
    }
    
    if ($isGitRepo) {
        Write-Host "Found $($matchingFiles.Count) file(s) with potential issues" -ForegroundColor White
        Write-Host ""
        
        # Process only the files that matched
        # Note: We're already in $RepoRoot after Push-Location, so relativePath is relative to current dir
        foreach ($relativePath in $matchingFiles) {
            # Resolve to absolute path from current location (which is $RepoRoot)
            $filePath = Resolve-Path -Path $relativePath -ErrorAction SilentlyContinue
            if (-not $filePath) {
                $filePath = Join-Path (Get-Location) $relativePath
            }
            
            try {
                $content = Get-Content -Path $filePath -Raw -ErrorAction Stop
            }
            catch {
                Write-Host "  [WARN] Cannot read file: $filePath" -ForegroundColor Yellow
                continue
            }
            
            if ([string]::IsNullOrEmpty($content)) {
                continue
            }
            
            # Check with precise regex
            $matches = [regex]::Matches($content, $srsWithBacktickPattern)
            
            if ($matches.Count -gt 0) {
                Write-Host "  [FAIL] $filePath" -ForegroundColor Red
                Write-Host "         Contains $($matches.Count) SRS requirement(s) with backticks" -ForegroundColor Yellow
                
                foreach ($match in $matches) {
                    $displayText = $match.Value
                    if ($displayText.Length -gt 100) {
                        $displayText = $displayText.Substring(0, 97) + "..."
                    }
                    Write-Host "         Found: $displayText" -ForegroundColor Yellow
                }
                
                $filesWithBackticks += [PSCustomObject]@{
                    FilePath = $filePath
                    MatchCount = $matches.Count
                    Matches = $matches
                }
                
                if ($Fix) {
                    try {
                        $fixedContent = $content
                        $srsPattern = '(SRS_[A-Z_]+_\d+_\d+\s*:\s*\[)([^\]]*)(\])'
                        $fixedContent = [regex]::Replace($fixedContent, $srsPattern, {
                            param($m)
                            $prefix = $m.Groups[1].Value
                            $middle = $m.Groups[2].Value -replace '`', ''
                            $suffix = $m.Groups[3].Value
                            return $prefix + $middle + $suffix
                        })
                        
                        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                        [System.IO.File]::WriteAllText($filePath, $fixedContent, $utf8NoBom)
                        
                        Write-Host "         [FIXED] Removed backticks from SRS requirements" -ForegroundColor Green
                        $fixedFiles += $filePath
                    }
                    catch {
                        Write-Host "         [ERROR] Failed to fix: $_" -ForegroundColor Red
                    }
                }
            }
        }
    }
}

Pop-Location

# Fallback to file system scan if not a git repo
if (-not $isGitRepo) {
    Write-Host "Scanning file system..." -ForegroundColor White
    
    $extensions = @("*.h", "*.hpp", "*.c", "*.cpp", "*.cs")
    $allFiles = @()
    foreach ($ext in $extensions) {
        $allFiles += Get-ChildItem -Path $RepoRoot -Recurse -Filter $ext -ErrorAction SilentlyContinue
    }
    
    $totalFiles = 0
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
        
        if ($isExcluded) {
            continue
        }
        
        $totalFiles++
        
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
        
        $matches = [regex]::Matches($content, $srsWithBacktickPattern)
        
        if ($matches.Count -gt 0) {
            Write-Host "  [FAIL] $($file.FullName)" -ForegroundColor Red
            Write-Host "         Contains $($matches.Count) SRS requirement(s) with backticks" -ForegroundColor Yellow
            
            foreach ($match in $matches) {
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
                    $fixedContent = $content
                    $srsPattern = '(SRS_[A-Z_]+_\d+_\d+\s*:\s*\[)([^\]]*)(\])'
                    $fixedContent = [regex]::Replace($fixedContent, $srsPattern, {
                        param($m)
                        $prefix = $m.Groups[1].Value
                        $middle = $m.Groups[2].Value -replace '`', ''
                        $suffix = $m.Groups[3].Value
                        return $prefix + $middle + $suffix
                    })
                    
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
    Write-Host "Total source files checked: $totalFiles" -ForegroundColor White
    Write-Host "Files skipped (excluded directories): $skippedFiles" -ForegroundColor White
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Validation Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

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
