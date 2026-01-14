# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS

Installs and configures GitHub CLI.

.DESCRIPTION

This script ensures GitHub CLI is installed and the user is authenticated.
It handles installation via winget and initiates the login flow if needed.

.EXAMPLE

PS> . .\install_gh_cli.ps1
PS> check-gh-cli-exists
#>

# Helper function to ensure winget is available
function ensure-winget-available {
    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if(!$wingetCmd) {
        Write-Error "winget is required but not available. Please ensure Windows Package Manager is installed."
        Write-Error "Download from: https://aka.ms/getwinget"
        exit -1
    }
}

# verify GitHub CLI is installed and authenticated
function check-gh-cli-exists {
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if(!$gh) {
        ensure-winget-available
        Write-Host "GitHub CLI is not installed. Installing via winget..."
        winget install --id GitHub.cli -e --source winget

        # Refresh PATH to pick up newly installed gh
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        $gh = Get-Command gh -ErrorAction SilentlyContinue

        if(!$gh) {
            Write-Error "Failed to install GitHub CLI. Please install manually: winget install --id GitHub.cli -e --source winget"
            Write-Error "Or download from: https://cli.github.com/"
            exit -1
        }
        Write-Host "GitHub CLI installed successfully." -ForegroundColor Green
    }

    # Check if user is logged in to GitHub
    $auth_status = gh auth status 2>&1
    if($LASTEXITCODE -ne 0) {
        Write-Host "Not logged in to GitHub CLI. Initiating login..."
        gh auth login
        if($LASTEXITCODE -ne 0) {
            Write-Error "GitHub authentication failed. Please run 'gh auth login' manually."
            exit -1
        }
        Write-Host "GitHub authentication successful." -ForegroundColor Green
    }
}
