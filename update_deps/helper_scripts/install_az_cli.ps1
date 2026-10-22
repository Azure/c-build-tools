# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS

Prepares Azure DevOps authentication for interactive runs.

.DESCRIPTION

Azure DevOps operations use the REST API. With a Personal Access Token (-azure_token, or the
AZURE_DEVOPS_EXT_PAT environment variable) no Azure CLI is needed. Otherwise the Azure CLI is
installed via winget if missing and signed in with WAM (Web Account Manager); REST access tokens
are then obtained with 'az account get-access-token'.

.PARAMETER pat_token

(Optional) Personal Access Token for Azure DevOps authentication. PAT must have Code (Read & Write)
and Work Items (Read & Write) permissions.

.EXAMPLE

PS> . .\install_az_cli.ps1
PS> initialize-interactive-azure-auth

.EXAMPLE

PS> . .\install_az_cli.ps1
PS> initialize-interactive-azure-auth -pat_token "your-pat-token"
#>

# Helper function to ensure winget is available (also used by install_gh_cli.ps1)
# Exits on failure
function ensure-winget-available
{
    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if (!$wingetCmd)
    {
        Write-Error "winget is required but not available. Please ensure Windows Package Manager is installed."
        Write-Error "Download from: https://aka.ms/getwinget"
        exit -1
    }
    else
    {
        # winget available
    }
}

# Choose the Azure DevOps credential for an interactive run: a PAT if one is given, otherwise a
# WAM sign-in through the Azure CLI (installed if missing).
# Exits on failure
function initialize-interactive-azure-auth
{
    param(
        [string] $pat_token
    )

    if ($pat_token)
    {
        $script:ado_pat = $pat_token
    }
    elseif ($env:AZURE_DEVOPS_EXT_PAT)
    {
        $script:ado_pat = $env:AZURE_DEVOPS_EXT_PAT
    }
    else
    {
        $script:ado_pat = $null
    }

    if ($script:ado_pat)
    {
        add-redaction-value $script:ado_pat
        Write-Host "Using a Personal Access Token for Azure DevOps" -ForegroundColor Green
        return
    }
    else
    {
        # no PAT; sign in with WAM through the Azure CLI
    }

    $az = Get-Command az -ErrorAction SilentlyContinue
    if (!$az)
    {
        ensure-winget-available
        Write-Host "Azure CLI is not installed. Installing via winget..."
        winget install --exact --id Microsoft.AzureCLI

        # Refresh PATH to pick up newly installed az
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        $az = Get-Command az -ErrorAction SilentlyContinue

        if (!$az)
        {
            Write-Error "Failed to install Azure CLI. Please install manually: winget install --exact --id Microsoft.AzureCLI"
            Write-Error "Or download from: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
            exit -1
        }
        else
        {
            Write-Host "Azure CLI installed successfully." -ForegroundColor Green
        }
    }
    else
    {
        # az already available
    }

    Write-Host "Attempting WAM (Web Account Manager) authentication..."

    # Enable WAM broker on Windows
    az config set core.enable_broker_on_windows=true 2>$null

    # Check if already logged in via WAM
    $account = az account show -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or !$account)
    {
        Write-Host "Not logged in. Initiating WAM login..."
        az login
        if ($LASTEXITCODE -ne 0)
        {
            Write-Error "WAM login failed. Please provide a PAT token using -azure_token parameter."
            exit -1
        }
        else
        {
            Write-Host "WAM login successful" -ForegroundColor Green
        }
    }
    else
    {
        $accountInfo = $account | ConvertFrom-Json
        Write-Host "Authenticated via WAM as: $($accountInfo.user.name)" -ForegroundColor Green
    }
}
