# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS

Ensures the GitHub CLI is available and authenticated.

.DESCRIPTION

ensure-gh-cli uses gh if it is already on PATH. Otherwise interactive runs install it with winget,
and -Pipeline runs download a pinned release (build agents have no winget) and add it to PATH for
the current process. Interactive runs start 'gh auth login' when gh is not signed in; -Pipeline
runs require the GH_TOKEN environment variable instead.

.EXAMPLE

PS> . .\install_gh_cli.ps1
PS> ensure-gh-cli
#>

# Pinned gh version downloaded only when gh is not already installed on a pipeline agent.
$script:GhCliVersion = '2.62.0'

# Download the pinned gh release and add it to PATH for this process.
function install-gh-cli-release
{
    Write-Host "GitHub CLI not found; downloading pinned release v$script:GhCliVersion..."
    $temp_base = if ($env:AGENT_TEMPDIRECTORY) { $env:AGENT_TEMPDIRECTORY } else { $env:TEMP }
    $zip = Join-Path $temp_base 'gh.zip'
    $dest = Join-Path $temp_base 'ghcli'
    $prev_progress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try
    {
        for ($attempt = 1; $attempt -le 3; $attempt++)
        {
            Remove-Item -Path $zip -Force -ErrorAction SilentlyContinue
            $download = @{
                Uri = "https://github.com/cli/cli/releases/download/v$script:GhCliVersion/gh_$($script:GhCliVersion)_windows_amd64.zip"
                OutFile = $zip
                TimeoutSec = 120
                UseBasicParsing = $true
            }
            # PowerShell 7.4+ applies TimeoutSec only until the response starts; also bound a stalled body.
            if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('OperationTimeoutSeconds'))
            {
                $download['OperationTimeoutSeconds'] = 120
            }
            else
            {
                # Windows PowerShell fails a stalled body read on its own
            }
            try
            {
                Invoke-WebRequest @download
                break
            }
            catch
            {
                if ($attempt -eq 3)
                {
                    Write-Error "Failed to download the GitHub CLI: $($_.Exception.Message)"
                    exit -1
                }
                else
                {
                    Write-Log WARN "GitHub CLI download failed (attempt $attempt/3): $($_.Exception.Message)"
                    Start-Sleep -Seconds 5
                }
            }
        }
        Expand-Archive -Path $zip -DestinationPath $dest -Force
    }
    finally
    {
        $ProgressPreference = $prev_progress
    }
    $env:PATH = "$(Join-Path $dest 'bin');$env:PATH"
}

# Install gh with winget and refresh PATH for this process.
function install-gh-cli-winget
{
    ensure-winget-available
    Write-Host "GitHub CLI is not installed. Installing via winget..."
    winget install --id GitHub.cli -e --source winget
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
}

# Verify GitHub CLI is installed and authenticated.
# Exits on failure
function ensure-gh-cli
{
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if ($gh)
    {
        Write-Host "GitHub CLI already installed: $($gh.Source)"
    }
    else
    {
        if (test-pipeline-mode)
        {
            install-gh-cli-release
        }
        else
        {
            install-gh-cli-winget
        }
        $gh = Get-Command gh -ErrorAction SilentlyContinue
        if (-not $gh)
        {
            Write-Error "Failed to install GitHub CLI. Install it manually: winget install --id GitHub.cli -e --source winget"
            Write-Error "Or download from: https://cli.github.com/"
            exit -1
        }
        else
        {
            Write-Host "GitHub CLI installed: $($gh.Source)" -ForegroundColor Green
        }
    }

    $attempts = if (test-pipeline-mode) { 3 } else { 1 }
    $auth_status = Invoke-NativeWithRetry -File gh -Arguments @('auth', 'status') -MaxAttempts $attempts -TimeoutSec 120
    if ($auth_status.ExitCode -eq 0)
    {
        # already logged in
    }
    elseif (test-pipeline-mode)
    {
        # gh authenticates non-interactively from the GH_TOKEN environment variable.
        Write-Log ERROR "GitHub CLI is not authenticated. Set GH_TOKEN to a valid GitHub token (repo write + SSO-authorized for the Azure org)."
        Write-Log ERROR $auth_status.StdErr
        exit -1
    }
    else
    {
        Write-Host "Not logged in to GitHub CLI. Initiating login..."
        gh auth login
        if ($LASTEXITCODE -ne 0)
        {
            Write-Error "GitHub authentication failed. Please run 'gh auth login' manually."
            exit -1
        }
        else
        {
            Write-Host "GitHub authentication successful." -ForegroundColor Green
        }
    }
}
