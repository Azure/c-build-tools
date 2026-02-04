# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS
    Clones a list of repositories to a temporary work area.

.DESCRIPTION
    This script clones repositories discovered by discover-submodules.ps1
    to a temporary work area, maintaining the original hierarchy structure.

.PARAMETER Repos
    Array of repository objects from discover-submodules.ps1.

.PARAMETER WorkArea
    The path to the temporary work area.

.PARAMETER Branch
    Optional branch name to create in all repos for the changes.

.OUTPUTS
    Array of objects with repository paths in the work area.

.EXAMPLE
    $repos = ./discover-submodules.ps1 -RepoPath "D:\w\store4" -IncludeRoot
    ./clone-repos.ps1 -Repos $repos -WorkArea "C:\temp\workarea"
#>

param(
    [Parameter(Mandatory = $true)]
    [object[]]$Repos,

    [Parameter(Mandatory = $true)]
    [string]$WorkArea,

    [Parameter(Mandatory = $false)]
    [string]$Branch
)

$ErrorActionPreference = "Stop"

# Create work area if it doesn't exist
if (-not (Test-Path $WorkArea)) {
    New-Item -ItemType Directory -Path $WorkArea -Force | Out-Null
}

$clonedRepos = @()

Write-Host "Cloning $($Repos.Count) repositories to $WorkArea" -ForegroundColor Cyan

foreach ($repo in $Repos) {
    $targetPath = Join-Path $WorkArea $repo.Name

    Write-Host "Cloning $($repo.Name)..." -ForegroundColor Yellow

    # Create parent directory if needed (shouldn't be needed with flat structure)
    $parentDir = Split-Path $targetPath -Parent
    if ($parentDir -and -not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    # Clone the repository
    if ($repo.Url) {
        # Clone from remote URL
        git clone $repo.Url $targetPath 2>&1 | Write-Host
    }
    elseif ($repo.AbsolutePath -and (Test-Path $repo.AbsolutePath)) {
        # Clone from local path
        git clone $repo.AbsolutePath $targetPath 2>&1 | Write-Host
    }
    else {
        Write-Warning "Cannot clone $($repo.Name): No URL or local path available"
        continue
    }

    # Create branch if specified
    if ($Branch -and (Test-Path $targetPath)) {
        Push-Location $targetPath
        try {
            git checkout -b $Branch 2>&1 | Write-Host
            Write-Host "  Created branch: $Branch" -ForegroundColor Green
        }
        finally {
            Pop-Location
        }
    }

    $clonedRepos += [PSCustomObject]@{
        Name         = $repo.Name
        WorkAreaPath = $targetPath
        OriginalUrl  = $repo.Url
    }

    Write-Host "  Cloned to: $targetPath" -ForegroundColor Green
}

Write-Host ""
Write-Host "Successfully cloned $($clonedRepos.Count) repositories" -ForegroundColor Cyan
Write-Host "Work area: $WorkArea" -ForegroundColor Cyan

return $clonedRepos
