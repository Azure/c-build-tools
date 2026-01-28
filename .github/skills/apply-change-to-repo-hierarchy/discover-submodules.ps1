<#
.SYNOPSIS
    Discovers all git submodules in a repository hierarchy recursively.

.DESCRIPTION
    This script traverses a git repository and discovers all submodules,
    returning their names, paths, URLs, and current commit SHAs.

.PARAMETER RepoPath
    The path to the starting repository.

.PARAMETER IncludeRoot
    If specified, includes the root repository in the output.

.OUTPUTS
    Array of objects with Name, Path, Url, and Commit properties.

.EXAMPLE
    $repos = ./discover-submodules.ps1 -RepoPath "D:\w\store4"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$RepoPath,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeRoot
)

$ErrorActionPreference = "Stop"

function Get-SubmodulesRecursive {
    param(
        [string]$Path,
        [string]$RelativePath = ""
    )

    $results = @()

    Push-Location $Path
    try {
        # Check if this is a git repository (skip silently if not initialized)
        if (-not (Test-Path ".git")) {
            return $results
        }

        # Get submodule information
        $gitmodulesPath = Join-Path $Path ".gitmodules"
        if (Test-Path $gitmodulesPath) {
            # Parse .gitmodules file
            $submoduleInfo = git config --file .gitmodules --get-regexp "submodule\..*\.(path|url)" 2>$null

            if ($submoduleInfo) {
                $submodules = @{}

                foreach ($line in $submoduleInfo) {
                    if ($line -match "submodule\.(.+)\.(path|url)\s+(.+)") {
                        $name = $Matches[1]
                        $property = $Matches[2]
                        $value = $Matches[3]

                        if (-not $submodules.ContainsKey($name)) {
                            $submodules[$name] = @{}
                        }
                        $submodules[$name][$property] = $value
                    }
                }

                foreach ($name in $submodules.Keys) {
                    $submodule = $submodules[$name]
                    $submodulePath = $submodule["path"]
                    $submoduleUrl = $submodule["url"]

                    if ($submodulePath) {
                        $fullPath = Join-Path $Path $submodulePath
                        $fullRelativePath = if ($RelativePath) { "$RelativePath/$submodulePath" } else { $submodulePath }

                        # Get current commit SHA for the submodule
                        $commit = ""
                        if (Test-Path $fullPath) {
                            Push-Location $fullPath
                            try {
                                $commit = git rev-parse HEAD 2>$null
                            }
                            finally {
                                Pop-Location
                            }
                        }

                        $results += [PSCustomObject]@{
                            Name         = $name
                            Path         = $fullRelativePath
                            Url          = $submoduleUrl
                            Commit       = $commit
                            AbsolutePath = $fullPath
                        }

                        # Recurse into submodule
                        if (Test-Path $fullPath) {
                            $nestedResults = Get-SubmodulesRecursive -Path $fullPath -RelativePath $fullRelativePath
                            $results += $nestedResults
                        }
                    }
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

if ($IncludeRoot) {
    Push-Location $resolvedPath
    try {
        $rootUrl = git config --get remote.origin.url 2>$null
        $rootCommit = git rev-parse HEAD 2>$null
        $rootName = Split-Path $resolvedPath -Leaf

        $allRepos += [PSCustomObject]@{
            Name         = $rootName
            Path         = "."
            Url          = $rootUrl
            Commit       = $rootCommit
            AbsolutePath = $resolvedPath.Path
        }
    }
    finally {
        Pop-Location
    }
}

# Discover all submodules recursively
$submodules = Get-SubmodulesRecursive -Path $resolvedPath

$allRepos += $submodules

# Output the results
Write-Host "Discovered $($allRepos.Count) repositories:" -ForegroundColor Cyan
foreach ($repo in $allRepos) {
    Write-Host "  - $($repo.Name) [$($repo.Path)]" -ForegroundColor Gray
}

return $allRepos
