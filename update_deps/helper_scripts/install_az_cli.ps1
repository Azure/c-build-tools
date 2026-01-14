# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS

Installs and configures Azure CLI with the Azure DevOps extension.

.DESCRIPTION

This script ensures Azure CLI is installed and properly configured for Azure DevOps access.
It handles installation via winget, extension setup, and authentication via WAM or PAT token.

.PARAMETER pat_token

(Optional) Personal Access Token for Azure DevOps authentication. If not provided, WAM
authentication will be used. PAT must have Code (Read & Write) and Work Items (Read) permissions.

.EXAMPLE

PS> . .\install_az_cli.ps1
PS> check-az-cli-exists

.EXAMPLE

PS> . .\install_az_cli.ps1
PS> check-az-cli-exists -pat_token "your-pat-token"
#>

# Helper function to ensure winget is available
# Exits on failure
function ensure-winget-available {
    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if (!$wingetCmd) {
        Write-Error "winget is required but not available. Please ensure Windows Package Manager is installed."
        Write-Error "Download from: https://aka.ms/getwinget"
        exit -1
    }
    else {
        # winget available
    }
}

# verify Azure CLI is installed and authenticate (WAM or PAT)
# Exits on failure
function check-az-cli-exists {
    param(
        [string] $pat_token
    )

    $az = Get-Command az -ErrorAction SilentlyContinue
    if (!$az) {
        ensure-winget-available
        Write-Host "Azure CLI is not installed. Installing via winget..."
        winget install --exact --id Microsoft.AzureCLI

        # Refresh PATH to pick up newly installed az
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        $az = Get-Command az -ErrorAction SilentlyContinue

        if (!$az) {
            Write-Error "Failed to install Azure CLI. Please install manually: winget install --exact --id Microsoft.AzureCLI"
            Write-Error "Or download from: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
            exit -1
        }
        else {
            Write-Host "Azure CLI installed successfully." -ForegroundColor Green
        }
    }
    else {
        # az already available
    }

    # Check if azure-devops extension is installed
    $extensions = az extension list --query "[?name=='azure-devops'].name" -o tsv 2>&1
    $azExitCode = $LASTEXITCODE

    if (!$extensions -or $azExitCode -ne 0) {
        Write-Host "Installing azure-devops extension..."
        $installOutput = az extension add --name azure-devops 2>&1
        if ($LASTEXITCODE -ne 0) {
            $installError = $installOutput | Out-String
            Write-Error "Failed to install azure-devops extension: $installError"
            Write-Error "See: https://learn.microsoft.com/en-us/azure/devops/cli/"
            exit -1
        }
        else {
            # extension installed successfully
        }
    }
    else {
        # extension already installed
    }

    # Test if extension is working properly
    $extensionTest = az devops -h 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Azure DevOps extension appears corrupted. Please reinstall manually:"
        Write-Error "  az extension remove --name azure-devops"
        Write-Error "  az extension add --name azure-devops"
        exit -1
    }
    else {
        # extension working
    }

    # If PAT token provided, use it
    if ($pat_token) {
        Write-Host "Logging in to Azure DevOps using PAT token..."
        $pat_token | az devops login
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to login to Azure DevOps. Check your PAT token."
            exit -1
        }
        else {
            # PAT login successful
        }
    }
    else {
        # Try WAM authentication (Windows only)
        Write-Host "Attempting WAM (Web Account Manager) authentication..."

        # Enable WAM broker on Windows
        az config set core.enable_broker_on_windows=true 2>$null

        # Check if already logged in via WAM
        $account = az account show -o json 2>$null
        if ($LASTEXITCODE -ne 0 -or !$account) {
            Write-Host "Not logged in. Initiating WAM login..."
            az login
            if ($LASTEXITCODE -ne 0) {
                Write-Error "WAM login failed. Please provide a PAT token using -azure_token parameter."
                exit -1
            }
            else {
                # WAM login successful
            }
        }
        else {
            $accountInfo = $account | ConvertFrom-Json
            Write-Host "Authenticated via WAM as: $($accountInfo.user.name)" -ForegroundColor Green
        }
    }
}
