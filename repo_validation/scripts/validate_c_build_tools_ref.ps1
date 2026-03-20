# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS
    Validates that pipeline YAML files referencing c-build-tools use the correct ref.

.DESCRIPTION
    This script checks all Azure DevOps pipeline YAML files (.yml) that reference
    the c_build_tools repository resource. It validates that the ref field either:
    1. Points to refs/heads/master (acceptable transitional state)
    2. Contains a commit SHA that matches the c-build-tools git submodule

    The script finds the c-build-tools submodule by parsing .gitmodules, then
    determines its commit SHA using git. All YAML files containing a
    "repository: c_build_tools" resource block are checked.

    If no .gitmodules file exists or it does not contain a c-build-tools submodule
    entry, the script passes silently (not applicable to this repo).

    When the -Fix switch is provided, the script replaces any incorrect SHA refs
    with the correct submodule SHA. It does NOT change refs/heads/master refs
    (that migration is done separately).

.PARAMETER RepoRoot
    The root directory of the repository to validate.

.PARAMETER ExcludeFolders
    Comma-separated list of additional folders to exclude from validation.

.PARAMETER Fix
    If specified, automatically replace incorrect SHA refs with the correct submodule SHA.

.PARAMETER SubmoduleSha
    Optional override for the expected submodule SHA. Used for testing without a real
    git repository. When provided, skips the git query and uses this value instead.

.EXAMPLE
    .\validate_c_build_tools_ref.ps1 -RepoRoot "C:\repo"

    Validates all pipeline YAML files and reports any incorrect c-build-tools refs.

.EXAMPLE
    .\validate_c_build_tools_ref.ps1 -RepoRoot "C:\repo" -Fix

    Validates and automatically fixes incorrect SHA refs in pipeline YAML files.

.EXAMPLE
    .\validate_c_build_tools_ref.ps1 -RepoRoot "C:\repo" -SubmoduleSha "abc123def456"

    Validates using a specific SHA (for testing without a real git submodule).

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
    [switch]$Fix,

    [Parameter(Mandatory=$false)]
    [string]$SubmoduleSha = ""
)

$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "c-build-tools Ref Validation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Repository Root: $RepoRoot" -ForegroundColor White
Write-Host "Fix Mode: $($Fix.IsPresent)" -ForegroundColor White
Write-Host ""

# Step 1: Find the c-build-tools submodule path from .gitmodules
$gitmodulesPath = Join-Path $RepoRoot ".gitmodules"
if (-not (Test-Path $gitmodulesPath)) {
    Write-Host "No .gitmodules file found. Skipping validation (not applicable)." -ForegroundColor Yellow
    Write-Host "[VALIDATION PASSED]" -ForegroundColor Green
    exit 0
}

$gitmodulesContent = Get-Content $gitmodulesPath -Raw

# Parse .gitmodules to find c-build-tools submodule
# Look for a submodule block with url containing c-build-tools
$submodulePath = ""
$currentPath = ""
$foundCBuildTools = $false

foreach ($line in (Get-Content $gitmodulesPath)) {
    if ($line -match '^\[submodule\s+"([^"]+)"\]') {
        $currentPath = ""
        $foundCBuildTools = $false
    }
    if ($line -match '^\s*path\s*=\s*(.+)$') {
        $currentPath = $Matches[1].Trim()
    }
    if ($line -match '^\s*url\s*=\s*.*c-build-tools') {
        $foundCBuildTools = $true
    }
    if ($foundCBuildTools -and $currentPath -ne "") {
        $submodulePath = $currentPath
        break
    }
}

if ($submodulePath -eq "") {
    Write-Host "No c-build-tools submodule found in .gitmodules. Skipping validation." -ForegroundColor Yellow
    Write-Host "[VALIDATION PASSED]" -ForegroundColor Green
    exit 0
}

Write-Host "c-build-tools submodule path: $submodulePath" -ForegroundColor White

# Step 2: Determine the expected submodule SHA
$expectedSha = $SubmoduleSha
if ($expectedSha -eq "") {
    # Query git for the submodule SHA
    try {
        $lsTreeOutput = git -C $RepoRoot ls-tree HEAD $submodulePath 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to get submodule SHA via git ls-tree: $lsTreeOutput" -ForegroundColor Red
            Write-Host "[VALIDATION FAILED]" -ForegroundColor Red
            exit 1
        }
        # Output format: "160000 commit <sha>\t<path>"
        if ($lsTreeOutput -match '160000\s+commit\s+([0-9a-f]{40})') {
            $expectedSha = $Matches[1]
        } else {
            Write-Host "Could not parse submodule SHA from git ls-tree output: $lsTreeOutput" -ForegroundColor Red
            Write-Host "[VALIDATION FAILED]" -ForegroundColor Red
            exit 1
        }
    }
    catch {
        Write-Host "Error running git: $_" -ForegroundColor Red
        Write-Host "[VALIDATION FAILED]" -ForegroundColor Red
        exit 1
    }
}

Write-Host "Expected submodule SHA: $expectedSha" -ForegroundColor White
Write-Host ""

# Step 3: Parse excluded directories
$excludeDirs = $ExcludeFolders -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
Write-Host "Excluded directories: $($excludeDirs -join ', ')" -ForegroundColor White
Write-Host ""

# Step 4: Find all YAML files and check for c-build-tools refs
$allYmlFiles = Get-ChildItem -Path $RepoRoot -Recurse -Filter "*.yml" -ErrorAction SilentlyContinue

$totalFiles = 0
$checkedFiles = 0
$invalidFiles = @()
$fixedFiles = @()

foreach ($file in $allYmlFiles) {
    $relativePath = $file.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')

    # Check if file should be excluded
    $isExcluded = $false
    foreach ($excludeDir in $excludeDirs) {
        if ($relativePath -like "$excludeDir\*" -or $relativePath -like "$excludeDir/*") {
            $isExcluded = $true
            break
        }
    }
    if ($isExcluded) { continue }

    $totalFiles++

    # Read file content
    try {
        $content = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
    }
    catch {
        Write-Host "  [WARN] Cannot read file: $($file.FullName)" -ForegroundColor Yellow
        continue
    }

    # Check if this file references c_build_tools repository
    if ($content -notmatch 'repository:\s*c_build_tools') { continue }

    $checkedFiles++

    # Find the ref line within the c_build_tools repository block
    # We look for lines between "repository: c_build_tools" and the next "- repository:" or end of resources block
    $lines = Get-Content -Path $file.FullName
    $inCBuildToolsBlock = $false
    $refLineIndex = -1
    $refValue = ""

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        if ($line -match '^\s*-?\s*repository:\s*c_build_tools\s*$') {
            $inCBuildToolsBlock = $true
            continue
        }

        if ($inCBuildToolsBlock) {
            # Exit block on next repository definition or non-indented line
            if ($line -match '^\s*-\s*repository:' -or ($line -match '^\S' -and $line -notmatch '^\s*$')) {
                $inCBuildToolsBlock = $false
                continue
            }

            if ($line -match '^\s*ref:\s*(.+)$') {
                $refValue = $Matches[1].Trim()
                $refLineIndex = $i
                $inCBuildToolsBlock = $false
            }
        }
    }

    if ($refLineIndex -eq -1) {
        Write-Host "  [WARN] No ref: found for c_build_tools in $relativePath" -ForegroundColor Yellow
        continue
    }

    # Validate the ref value
    $isValid = $false
    $reason = ""

    if ($refValue -eq "refs/heads/master") {
        $isValid = $true
        Write-Host "  [OK]   $relativePath (ref: refs/heads/master)" -ForegroundColor Green
    }
    elseif ($refValue -match '^[0-9a-f]{40}$') {
        # It's a SHA - check if it matches the submodule
        if ($refValue -eq $expectedSha) {
            $isValid = $true
            Write-Host "  [OK]   $relativePath (ref: $($refValue.Substring(0, 12))... matches submodule)" -ForegroundColor Green
        } else {
            $reason = "SHA mismatch: YAML has $($refValue.Substring(0, 12))..., submodule is $($expectedSha.Substring(0, 12))..."
        }
    }
    else {
        $reason = "Unexpected ref value: $refValue (expected refs/heads/master or a 40-char commit SHA)"
    }

    if (-not $isValid) {
        Write-Host "  [FAIL] $relativePath" -ForegroundColor Red
        Write-Host "         $reason" -ForegroundColor Yellow

        $invalidFiles += [PSCustomObject]@{
            FilePath = $file.FullName
            RelativePath = $relativePath
            RefLineIndex = $refLineIndex
            CurrentRef = $refValue
            Reason = $reason
        }

        if ($Fix) {
            try {
                $lines[$refLineIndex] = $lines[$refLineIndex] -replace 'ref:\s*.+$', "ref: $expectedSha"
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllLines($file.FullName, $lines, $utf8NoBom)
                Write-Host "         [FIXED] Updated ref to $($expectedSha.Substring(0, 12))..." -ForegroundColor Green
                $fixedFiles += $file.FullName
            }
            catch {
                Write-Host "         [ERROR] Failed to fix: $_" -ForegroundColor Red
            }
        }
    }
}

# Summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Validation Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total YAML files scanned: $totalFiles" -ForegroundColor White
Write-Host "Files with c_build_tools ref: $checkedFiles" -ForegroundColor White

if ($Fix -and $fixedFiles.Count -gt 0) {
    Write-Host "Files fixed successfully: $($fixedFiles.Count)" -ForegroundColor Green
}

if ($invalidFiles.Count -gt 0 -and -not $Fix) {
    Write-Host "Files with invalid refs: $($invalidFiles.Count)" -ForegroundColor Red
    Write-Host ""
    Write-Host "The following files have incorrect c-build-tools refs:" -ForegroundColor Yellow
    foreach ($item in $invalidFiles) {
        Write-Host "  - $($item.RelativePath): $($item.Reason)" -ForegroundColor White
    }
    Write-Host ""
    Write-Host "To fix these files automatically, run with -Fix parameter." -ForegroundColor Cyan
}

$unfixedFiles = $invalidFiles.Count - $fixedFiles.Count

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
