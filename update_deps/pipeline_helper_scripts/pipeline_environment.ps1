# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

$script:pipeline_environment_backup = @{}
$script:pipeline_git_config_path = $null

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
    Set-Item -Path "Env:$Name" -Value $Value
}

function initialize-pipeline-environment
{
    set-pipeline-environment-variable -Name 'GIT_TERMINAL_PROMPT' -Value '0'
    set-pipeline-environment-variable -Name 'GCM_INTERACTIVE' -Value 'never'
    set-pipeline-environment-variable -Name 'GH_PROMPT_DISABLED' -Value '1'
    set-pipeline-environment-variable -Name 'GIT_HTTP_LOW_SPEED_LIMIT' -Value '1'
    set-pipeline-environment-variable -Name 'GIT_HTTP_LOW_SPEED_TIME' -Value '60'

    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue))
    {
        fail-with-status "git is required for dependency propagation."
    }

    $temp_root = if ($env:AGENT_TEMPDIRECTORY) { $env:AGENT_TEMPDIRECTORY } else { [System.IO.Path]::GetTempPath() }
    $script:pipeline_git_config_path = Join-Path $temp_root "c-build-tools-propagate-$PID-$([guid]::NewGuid().ToString('N')).gitconfig"
    set-pipeline-environment-variable -Name 'GIT_CONFIG_GLOBAL' -Value $script:pipeline_git_config_path

    # Supply Azure DevOps git authentication through inherited environment config so the bearer
    # token is never written to disk or placed in a logged command line.
    $ado_hosts = @(
        'http.https://dev.azure.com.extraheader',
        'http.https://msazure@dev.azure.com.extraheader',
        'http.https://msazure.visualstudio.com.extraheader'
    )
    set-pipeline-environment-variable -Name 'GIT_CONFIG_COUNT' -Value ([string]($ado_hosts.Count + 1))
    for ($index = 0; $index -lt $ado_hosts.Count; $index++)
    {
        set-pipeline-environment-variable -Name "GIT_CONFIG_KEY_$index" -Value $ado_hosts[$index]
        set-pipeline-environment-variable -Name "GIT_CONFIG_VALUE_$index" -Value "AUTHORIZATION: bearer $($env:SYSTEM_ACCESSTOKEN)"
    }
    set-pipeline-environment-variable -Name "GIT_CONFIG_KEY_$($ado_hosts.Count)" -Value 'credential.interactive'
    set-pipeline-environment-variable -Name "GIT_CONFIG_VALUE_$($ado_hosts.Count)" -Value 'never'

    $name_result = Invoke-NativeWithTimeout -File git -Arguments @('config', '--global', 'user.name', 'c-build-tools dependency propagation')
    $email_result = Invoke-NativeWithTimeout -File git -Arguments @('config', '--global', 'user.email', 'c-build-tools-deps-bot@noreply.microsoft.com')
    if ($name_result.ExitCode -ne 0 -or $email_result.ExitCode -ne 0)
    {
        fail-with-status "Could not configure the pipeline git identity."
    }
}

function remove-pipeline-environment
{
    if ($script:pipeline_git_config_path)
    {
        Remove-Item -Path $script:pipeline_git_config_path -Force -ErrorAction SilentlyContinue
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
