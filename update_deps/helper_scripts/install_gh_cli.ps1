# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS

Ensures the GitHub CLI is available and authenticated.

.DESCRIPTION

ensure-gh-cli uses gh if it is already on PATH; otherwise it downloads a pinned gh release and adds it
to PATH for the current process (the build agent has no winget). It then confirms gh is authenticated,
which in the pipeline happens non-interactively via the GH_TOKEN environment variable.

.EXAMPLE

PS> . .\install_gh_cli.ps1
PS> ensure-gh-cli
#>

# Pinned gh version downloaded only when gh is not already installed.
$script:GhCliVersion = '2.62.0'

# Ensure gh is installed (download if missing) and authenticated.
# Exits on failure.
function ensure-gh-cli
{
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if ($gh)
    {
        Write-Host "GitHub CLI already installed: $($gh.Source)"
    }
    else
    {
        Write-Host "GitHub CLI not found; downloading pinned release v$script:GhCliVersion..."
        $tempBase = if ($env:AGENT_TEMPDIRECTORY) { $env:AGENT_TEMPDIRECTORY } else { $env:TEMP }
        $zip  = Join-Path $tempBase 'gh.zip'
        $dest = Join-Path $tempBase 'ghcli'
        $prevProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try
        {
            $download = @{
                Uri = "https://github.com/cli/cli/releases/download/v$script:GhCliVersion/gh_$($script:GhCliVersion)_windows_amd64.zip"
                OutFile = $zip
                TimeoutSec = 120
            }
            # PowerShell 7.4+ applies TimeoutSec only until the response starts; also bound a stalled body.
            if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('OperationTimeoutSeconds'))
            {
                $download['OperationTimeoutSeconds'] = 120
            }
            Invoke-WebRequest @download
            Expand-Archive -Path $zip -DestinationPath $dest -Force
        }
        finally
        {
            $ProgressPreference = $prevProgress
        }
        # Add to PATH for this process (the propagation runs in this same process).
        $env:PATH = "$(Join-Path $dest 'bin');$env:PATH"
        $gh = Get-Command gh -ErrorAction SilentlyContinue
        if (!$gh)
        {
            Write-Error "Failed to install GitHub CLI from the pinned release. Install it manually from https://cli.github.com/."
            exit -1
        }
        Write-Host "GitHub CLI installed: $($gh.Source)"
    }

    # gh authenticates non-interactively from the GH_TOKEN environment variable.
    $auth_status = gh auth status 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        Write-Error "GitHub CLI is not authenticated. Set GH_TOKEN to a valid GitHub token (repo write + SSO-authorized for the Azure org)."
        Write-Error ($auth_status | Out-String)
        exit -1
    }
}
