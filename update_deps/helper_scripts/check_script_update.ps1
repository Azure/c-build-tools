# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Check if there's a newer version of the update_deps folder in origin/master

function check-for-script-updates
{
    param(
        [string]$script_root
    )

    Write-Host "Checking for script updates..." -ForegroundColor Cyan

    try
    {
        # Find the git repo root (script_root is update_deps, go up one level)
        $repo_root = Split-Path $script_root -Parent

        if (-not (Test-Path (Join-Path $repo_root ".git")))
        {
            Write-Host "Not running from a git repository, skipping update check." -ForegroundColor Yellow
            return
        }

        Push-Location $repo_root

        # Fetch latest from origin (quiet)
        git fetch origin master --quiet 2>$null
        if ($LASTEXITCODE -ne 0)
        {
            Write-Host "Could not fetch from origin (this is not an error, continuing...)" -ForegroundColor Yellow
            Pop-Location
            return
        }

        # Get tree hash of update_deps folder for local HEAD and origin/master
        $local_tree = git rev-parse HEAD:update_deps 2>$null
        $remote_tree = git rev-parse origin/master:update_deps 2>$null

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($local_tree) -or [string]::IsNullOrEmpty($remote_tree))
        {
            Write-Host "Could not compare versions (this is not an error, continuing...)" -ForegroundColor Yellow
            Pop-Location
            return
        }

        if ($local_tree -ne $remote_tree)
        {
            Write-Host ""
            Write-Host "==========================================" -ForegroundColor Yellow
            Write-Host " A newer version of these scripts exists!" -ForegroundColor Yellow
            Write-Host "==========================================" -ForegroundColor Yellow
            Write-Host "Your local update_deps folder differs from origin/master." -ForegroundColor Yellow
            Write-Host "Consider updating: git pull origin master" -ForegroundColor Cyan
            Write-Host ""
        }
        else
        {
            Write-Host "Scripts are up to date." -ForegroundColor Green
        }

        Pop-Location
    }
    catch
    {
        Write-Host "Could not check for updates: $_" -ForegroundColor Yellow
        Write-Host "Continuing anyway..." -ForegroundColor Yellow
    }
}
