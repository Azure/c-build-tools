# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Process environment for -Pipeline runs: nothing may prompt, git authenticates to Azure DevOps with
# SYSTEM_ACCESSTOKEN, and every change is undone when the run ends.

$script:pipeline_environment_backup = @{}
$script:pipeline_git_config_path = $null

# Azure DevOps hosts that git authenticates to with SYSTEM_ACCESSTOKEN.
$script:ado_git_hosts = @('https://dev.azure.com', 'https://msazure.visualstudio.com')

# Set a process environment variable, remembering its original value for remove-pipeline-environment.
function set-pipeline-environment-variable
{
    param(
        [string] $Name,
        [string] $Value
    )
    if (-not $script:pipeline_environment_backup.ContainsKey($Name))
    {
        $existing = Get-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
        $script:pipeline_environment_backup[$Name] = if ($existing) { $existing.Value } else { $null }
    }
    else
    {
        # original value already saved
    }
    Set-Item -Path "Env:$Name" -Value $Value
}

# One git config entry in the quoted 'key=value' form of GIT_CONFIG_PARAMETERS, which every git
# version reads. An empty value is kept: 'key=' sets the empty string.
function format-git-config-parameter
{
    param(
        [string] $Key,
        [string] $Value
    )
    return "'" + ("$Key=$Value" -replace "'", "'\''") + "'"
}

function initialize-pipeline-environment
{
    # Nobody can answer a prompt in a pipeline, so git, Git Credential Manager and gh must fail
    # instead of waiting. A transfer slower than 1 byte/s for 60 seconds is treated as dead.
    set-pipeline-environment-variable -Name 'GIT_TERMINAL_PROMPT' -Value '0'
    set-pipeline-environment-variable -Name 'GCM_INTERACTIVE' -Value 'never'
    set-pipeline-environment-variable -Name 'GH_PROMPT_DISABLED' -Value '1'
    set-pipeline-environment-variable -Name 'GIT_HTTP_LOW_SPEED_LIMIT' -Value '1'
    set-pipeline-environment-variable -Name 'GIT_HTTP_LOW_SPEED_TIME' -Value '60'

    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue))
    {
        fail-with-status "git is required for dependency propagation."
    }
    else
    {
        # git available
    }

    # Keep "global" git settings (identity, gh credential helper) out of the agent's real
    # ~/.gitconfig. A caller that already isolated it keeps its own file.
    if ([string]::IsNullOrWhiteSpace($env:GIT_CONFIG_GLOBAL))
    {
        $temp_root = if ($env:AGENT_TEMPDIRECTORY) { $env:AGENT_TEMPDIRECTORY } else { [System.IO.Path]::GetTempPath() }
        $script:pipeline_git_config_path = Join-Path $temp_root "c-build-tools-propagate-$PID-$([guid]::NewGuid().ToString('N')).gitconfig"
        set-pipeline-environment-variable -Name 'GIT_CONFIG_GLOBAL' -Value $script:pipeline_git_config_path
    }
    else
    {
        # caller-provided isolated global config
    }

    # Azure DevOps git authentication goes through GIT_CONFIG_PARAMETERS (the variable 'git -c'
    # uses), appended after the caller's entries, so the bearer token is never written to disk or
    # logged. Git reads these after every config file and GIT_CONFIG_COUNT entry. For each host an
    # empty extraheader first clears one the caller already configured (the EBS pipeline does);
    # otherwise git sends two Authorization headers and the request fails. GIT_CONFIG_COUNT entries
    # cannot carry that empty value: Windows PowerShell deletes an environment variable set to ''.
    $parameters = @()
    foreach ($ado_host in $script:ado_git_hosts)
    {
        $parameters += format-git-config-parameter -Key "http.$ado_host.extraheader" -Value ''
        $parameters += format-git-config-parameter -Key "http.$ado_host.extraheader" -Value "AUTHORIZATION: bearer $($env:SYSTEM_ACCESSTOKEN)"
    }
    $parameters += format-git-config-parameter -Key 'credential.interactive' -Value 'never'
    $all_parameters = @(@($env:GIT_CONFIG_PARAMETERS) + $parameters | Where-Object { $_ })
    set-pipeline-environment-variable -Name 'GIT_CONFIG_PARAMETERS' -Value ($all_parameters -join ' ')

    # Commits need an identity; keep one the caller configured.
    $identity = @(
        @('user.name', 'c-build-tools dependency propagation'),
        @('user.email', 'c-build-tools-deps-bot@noreply.microsoft.com')
    )
    foreach ($setting in $identity)
    {
        $current = Invoke-NativeWithTimeout -File git -Arguments @('config', '--global', '--get', $setting[0])
        if ($current.ExitCode -eq 0 -and $current.StdOut.Trim())
        {
            # already configured
        }
        else
        {
            $set = Invoke-NativeWithTimeout -File git -Arguments @('config', '--global', $setting[0], $setting[1])
            if ($set.ExitCode -ne 0)
            {
                fail-with-status "Could not configure git $($setting[0]) for the pipeline: $($set.StdErr)"
            }
            else
            {
                # configured
            }
        }
    }
}

# Undo initialize-pipeline-environment: delete the temporary git config and restore every variable.
function remove-pipeline-environment
{
    if ($script:pipeline_git_config_path)
    {
        Remove-Item -Path $script:pipeline_git_config_path -Force -ErrorAction SilentlyContinue
    }
    else
    {
        # no temporary git config was created
    }
    foreach ($name in @($script:pipeline_environment_backup.Keys))
    {
        $value = $script:pipeline_environment_backup[$name]
        if ($null -eq $value)
        {
            Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
        }
        else
        {
            Set-Item -Path "Env:$name" -Value $value
        }
    }
    $script:pipeline_environment_backup = @{}
    $script:pipeline_git_config_path = $null
}
