# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS
    Discovers all git submodules in a repository hierarchy recursively.

.DESCRIPTION
    This script traverses a git repository and discovers all submodules,
    returning their names, paths, and URLs in dependency order (deepest first).
    
    It uses git submodule commands (not .gitmodules parsing) and calls
    build_graph.ps1 for proper dependency ordering. Results are deduplicated
    so each unique repository appears only once.

.PARAMETER RepoPath
    The path to the starting repository. Defaults to current directory.

.PARAMETER IncludeRoot
    Whether to include the root repository in the output. Defaults to $true.

.PARAMETER ExcludeRepos
    Array of repository names to exclude from discovery. These are typically
    third-party repositories that should not be modified.
    Default: libuv, mimalloc, jemalloc, vcpkg

.OUTPUTS
    Array of objects with Name, Url, and AbsolutePath properties, ordered
    from deepest dependencies first (leaf repos) to root.

.EXAMPLE
    $repos = ./discover-submodules.ps1 -RepoPath "D:\w\store4"

.EXAMPLE
    $repos = ./discover-submodules.ps1 -IncludeRoot $false -ExcludeRepos @("libuv", "vcpkg", "custom-lib")
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$RepoPath = ".",

    [Parameter(Mandatory = $false)]
    [bool]$IncludeRoot = $true,

    [Parameter(Mandatory = $false)]
    [string[]]$ExcludeRepos = @("libuv", "mimalloc", "jemalloc", "vcpkg")
)

$ErrorActionPreference = "Stop"

# Track discovered repos to avoid duplicates (keyed by repo name)
$discoveredRepos = @{}

function Get-RepoNameFromUrl {
    param([string]$Url)
    
    if (-not $Url) { return $null }
    
    # Extract repo name from URL (handles both .git suffix and no suffix)
    $parts = $Url.TrimEnd('/').Split('/')
    $lastPart = $parts[-1]
    if ($lastPart.EndsWith(".git")) {
        return $lastPart.Substring(0, $lastPart.Length - 4)
    }
    return $lastPart
}

function Get-SubmodulesRecursive {
    param(
        [string]$Path
    )

    $results = @()

    Push-Location $Path
    try {
        # Check if this is a git repository
        if (-not (Test-Path ".git")) {
            return $results
        }

        # Use git submodule to get submodule info (not .gitmodules parsing)
        # Format: <sha> <path> (<describe>)
        $submoduleStatus = git submodule status --recursive 2>$null
        
        if (-not $submoduleStatus) {
            # No submodules or not initialized - try git submodule foreach
            $submoduleOutput = git submodule foreach --quiet 'echo "$name|$sm_path|$(git config --get remote.origin.url)"' 2>$null
            
            if ($submoduleOutput) {
                foreach ($line in $submoduleOutput) {
                    if ($line -match "^([^|]+)\|([^|]+)\|(.+)$") {
                        $name = $Matches[1]
                        $smPath = $Matches[2]
                        $url = $Matches[3]
                        
                        # Skip excluded repos
                        if ($name -in $ExcludeRepos) {
                            Write-Host "  Skipping excluded repo: $name" -ForegroundColor DarkGray
                            continue
                        }
                        
                        # Skip if already discovered (deduplication)
                        if ($discoveredRepos.ContainsKey($name)) {
                            continue
                        }
                        
                        $fullPath = Join-Path $Path $smPath
                        
                        $repoObj = [PSCustomObject]@{
                            Name         = $name
                            Url          = $url
                            AbsolutePath = (Resolve-Path $fullPath -ErrorAction SilentlyContinue)?.Path ?? $fullPath
                        }
                        
                        $discoveredRepos[$name] = $repoObj
                        $results += $repoObj
                        
                        # Recurse into submodule
                        if (Test-Path $fullPath) {
                            $nestedResults = Get-SubmodulesRecursive -Path $fullPath
                            $results += $nestedResults
                        }
                    }
                }
            }
        }
        else {
            # Parse git submodule status output and get URLs
            foreach ($line in $submoduleStatus) {
                # Format: " <sha> <path> (<describe>)" or "-<sha> <path>" (not initialized)
                if ($line -match "^\s*[-+]?([0-9a-f]+)\s+(\S+)") {
                    $smPath = $Matches[2]
                    $fullPath = Join-Path $Path $smPath
                    $name = Split-Path $smPath -Leaf
                    
                    # Skip excluded repos
                    if ($name -in $ExcludeRepos) {
                        Write-Host "  Skipping excluded repo: $name" -ForegroundColor DarkGray
                        continue
                    }
                    
                    # Skip if already discovered (deduplication)
                    if ($discoveredRepos.ContainsKey($name)) {
                        continue
                    }
                    
                    # Get URL from submodule config
                    $url = git config --get "submodule.$smPath.url" 2>$null
                    if (-not $url) {
                        $url = git config -f .gitmodules --get "submodule.$smPath.url" 2>$null
                    }
                    
                    $repoObj = [PSCustomObject]@{
                        Name         = $name
                        Url          = $url
                        AbsolutePath = (Resolve-Path $fullPath -ErrorAction SilentlyContinue)?.Path ?? $fullPath
                    }
                    
                    $discoveredRepos[$name] = $repoObj
                    $results += $repoObj
                }
            }
        }
    }
    finally {
        Pop-Location
    }

    return $results
}

# Resolve the repository path
$resolvedPath = Resolve-Path $RepoPath -ErrorAction Stop

# Get root repository info if requested
$allRepos = @()
$rootName = Split-Path $resolvedPath -Leaf

if ($IncludeRoot) {
    Push-Location $resolvedPath
    try {
        $rootUrl = git config --get remote.origin.url 2>$null

        $rootRepo = [PSCustomObject]@{
            Name         = $rootName
            Url          = $rootUrl
            AbsolutePath = $resolvedPath.Path
        }
        
        $discoveredRepos[$rootName] = $rootRepo
    }
    finally {
        Pop-Location
    }
}

# Discover all submodules recursively
Write-Host "Discovering submodules in $resolvedPath..." -ForegroundColor Cyan
$submodules = Get-SubmodulesRecursive -Path $resolvedPath

# Use build_graph.ps1 to compute dependency order (deepest first)
# build_graph.ps1 is located in update_deps folder relative to this script's location in c-build-tools
$buildGraphScript = Join-Path $PSScriptRoot "..\..\..\update_deps\build_graph.ps1"

# Check if we can find build_graph.ps1
if (-not (Test-Path $buildGraphScript)) {
    # Try to find it via the repo's c-build-tools dependency
    $cbuildToolsPath = Join-Path $resolvedPath "deps\c-build-tools\update_deps\build_graph.ps1"
    if (Test-Path $cbuildToolsPath) {
        $buildGraphScript = $cbuildToolsPath
    }
}

$sortedRepos = @()

if ((Test-Path $buildGraphScript) -and ($discoveredRepos.Count -gt 0)) {
    Write-Host "Using build_graph.ps1 for dependency ordering..." -ForegroundColor Cyan
    
    # Get root repo URL for build_graph
    $rootUrl = $discoveredRepos.Values | Where-Object { $_.Name -eq $rootName } | Select-Object -First 1 -ExpandProperty Url
    
    if ($rootUrl) {
        # Create temp directory for build_graph output
        $tempDir = Join-Path $env:TEMP "discover-submodules-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        
        try {
            Push-Location $tempDir
            try {
                # Call build_graph.ps1 with the root URL
                & $buildGraphScript -root_list @($rootUrl) 2>&1 | Out-Null
                
                # Read the order from order.json
                $orderFile = Join-Path $tempDir "order.json"
                if (Test-Path $orderFile) {
                    $repoOrder = Get-Content $orderFile | ConvertFrom-Json
                    
                    # Map the ordered names back to our repo objects
                    foreach ($repoName in $repoOrder) {
                        if ($discoveredRepos.ContainsKey($repoName) -and ($repoName -notin $ExcludeRepos)) {
                            $sortedRepos += $discoveredRepos[$repoName]
                        }
                    }
                    
                    # Add any repos that weren't in the order (shouldn't happen, but safety)
                    foreach ($repo in $discoveredRepos.Values) {
                        if ($repo.Name -notin $sortedRepos.Name) {
                            $sortedRepos += $repo
                        }
                    }
                }
            }
            finally {
                Pop-Location
            }
        }
        finally {
            # Cleanup temp directory
            Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
        }
    }
}

# Fallback: if build_graph didn't work, use simple level-based ordering
if ($sortedRepos.Count -eq 0) {
    Write-Host "Using fallback level-based ordering..." -ForegroundColor Yellow
    
    # Build a simple level-based ordering: repos that are dependencies of others come first
    $repoLevels = @{}
    foreach ($repo in $discoveredRepos.Values) {
        $repoLevels[$repo.Name] = 0
    }

    # Compute levels by checking which repos contain which as submodules
    foreach ($repo in $discoveredRepos.Values) {
        if ($repo.AbsolutePath -and (Test-Path $repo.AbsolutePath)) {
            Push-Location $repo.AbsolutePath
            try {
                $submoduleNames = git submodule foreach --quiet 'echo $name' 2>$null
                if ($submoduleNames) {
                    foreach ($subName in $submoduleNames) {
                        $subName = $subName.Trim()
                        if ($repoLevels.ContainsKey($subName)) {
                            # Submodule should have higher level (processed first)
                            $currentLevel = $repoLevels[$subName]
                            $parentLevel = $repoLevels[$repo.Name]
                            if ($currentLevel -le $parentLevel) {
                                $repoLevels[$subName] = $parentLevel + 1
                            }
                        }
                    }
                }
            }
            finally {
                Pop-Location
            }
        }
    }

    # Sort repos by level descending (deepest dependencies first)
    $sortedRepos = $discoveredRepos.Values | Sort-Object { $repoLevels[$_.Name] } -Descending
}

# Output the results
Write-Host ""
Write-Host "Discovered $($sortedRepos.Count) repositories (deepest dependencies first):" -ForegroundColor Cyan
$index = 1
foreach ($repo in $sortedRepos) {
    Write-Host "  $index. $($repo.Name)" -ForegroundColor Gray
    $index++
}

return @($sortedRepos)
