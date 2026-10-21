# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

$ErrorActionPreference = 'Stop'

$update_deps_root = Split-Path $PSScriptRoot -Parent
$entry_script = Join-Path $update_deps_root 'propagate_updates.ps1'
$pipeline_script = Join-Path $update_deps_root 'propagate_updates_pipeline.ps1'
$pipeline_helpers = Join-Path $update_deps_root 'pipeline_helper_scripts'
$failures = New-Object System.Collections.Generic.List[string]

function assert-true
{
    param(
        [bool] $Condition,
        [string] $Message
    )
    if (-not $Condition)
    {
        $failures.Add($Message)
    }
}

function parse-script
{
    param([string] $Path)
    $tokens = $null
    $parse_errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref] $tokens,
        [ref] $parse_errors)
    foreach ($parse_error in @($parse_errors))
    {
        $failures.Add("$Path parser error: $($parse_error.Message)")
    }
    return $ast
}

$scripts = @(
    Get-Item $entry_script
    Get-Item $pipeline_script
    Get-ChildItem $pipeline_helpers -Filter '*.ps1' -File
    Get-Item $PSCommandPath
)
foreach ($script in $scripts)
{
    [void](parse-script -Path $script.FullName)
}

$entry_ast = parse-script -Path $entry_script
$parameter_names = @($entry_ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
assert-true ($parameter_names -contains 'Pipeline') 'propagate_updates.ps1 must expose the -Pipeline switch.'

$entry_text = Get-Content -Path $entry_script -Raw
$dispatch_index = $entry_text.IndexOf('propagate_updates_pipeline.ps1', [System.StringComparison]::Ordinal)
$interactive_source_index = $entry_text.IndexOf('# Source helper scripts', [System.StringComparison]::Ordinal)
assert-true ($dispatch_index -ge 0) 'The interactive entry point must dispatch to propagate_updates_pipeline.ps1.'
assert-true ($dispatch_index -lt $interactive_source_index) 'Pipeline dispatch must happen before interactive helpers are sourced.'

$pipeline_text = Get-Content -Path $pipeline_script -Raw
$environment_text = Get-Content -Path (Join-Path $pipeline_helpers 'pipeline_environment.ps1') -Raw
assert-true ($environment_text.Contains('SYSTEM_ACCESSTOKEN')) 'Pipeline mode must consume SYSTEM_ACCESSTOKEN.'
assert-true ($environment_text.Contains('GIT_TERMINAL_PROMPT')) 'Pipeline mode must disable git prompts.'
assert-true ($environment_text.Contains('GIT_CONFIG_COUNT')) 'Pipeline mode must configure Azure DevOps git authentication through the environment.'
$azure_ops_text = Get-Content -Path (Join-Path $pipeline_helpers 'azure_repo_ops.ps1') -Raw
assert-true ($azure_ops_text.Contains('Authorization = "Bearer $token"')) 'Azure DevOps REST calls must use SYSTEM_ACCESSTOKEN as a bearer token.'

$pipeline_files = @((Get-Item $pipeline_script))
$pipeline_files += @(Get-ChildItem $pipeline_helpers -Filter '*.ps1' -File)
foreach ($pipeline_file in $pipeline_files)
{
    $text = Get-Content -Path $pipeline_file.FullName -Raw
    assert-true (-not [regex]::IsMatch($text, '(?im)\b(Read-Host|PromptForChoice)\b')) "$($pipeline_file.Name) contains an interactive prompt."
    assert-true (-not [regex]::IsMatch($text, '(?im)^\s*git\s+add\s+\.\s*$')) "$($pipeline_file.Name) stages the entire repository with git add ."
    assert-true (-not [regex]::IsMatch($text, '(?im)^\s*git\s+(clone|pull|push)\b')) "$($pipeline_file.Name) contains an unbounded network git operation."
    assert-true (-not [regex]::IsMatch($text, '(?im)^\s*git\s+submodule\s+update\b')) "$($pipeline_file.Name) contains an unbounded submodule update."
}

$saved_system_token = $env:SYSTEM_ACCESSTOKEN
$saved_gh_token = $env:GH_TOKEN
try
{
    $env:SYSTEM_ACCESSTOKEN = 'pipeline-system-secret-123456'
    $env:GH_TOKEN = 'ghp_abcdefghijklmnopqrstuvwxyz123456'
    . (Join-Path $pipeline_helpers 'logging.ps1')

    $redacted = Protect-Secret "system=$($env:SYSTEM_ACCESSTOKEN) github=$($env:GH_TOKEN) authorization: bearer raw-token"
    assert-true (-not $redacted.Contains($env:SYSTEM_ACCESSTOKEN)) 'Protect-Secret did not redact SYSTEM_ACCESSTOKEN.'
    assert-true (-not $redacted.Contains($env:GH_TOKEN)) 'Protect-Secret did not redact GH_TOKEN.'
    assert-true ($redacted.Contains('***REDACTED***')) 'Protect-Secret did not emit a redaction marker.'

    $powershell_exe = (Get-Process -Id $PID).Path
    $native_ok = Invoke-NativeWithTimeout -File $powershell_exe -Arguments @(
        '-NoProfile',
        '-Command',
        "[Console]::Out.Write('bounded-ok')")
    assert-true ($native_ok.ExitCode -eq 0 -and $native_ok.StdOut -eq 'bounded-ok') 'Invoke-NativeWithTimeout did not preserve native stdout.'

    $native_timeout = Invoke-NativeWithTimeout -File $powershell_exe -Arguments @(
        '-NoProfile',
        '-Command',
        'Start-Sleep -Seconds 3') -TimeoutSec 1
    assert-true ($native_timeout.TimedOut -and $native_timeout.ExitCode -eq -1) 'Invoke-NativeWithTimeout did not stop a timed-out process.'

    . (Join-Path $pipeline_helpers 'status_tracking.ps1')
    . (Join-Path $pipeline_helpers 'pipeline_environment.ps1')

    $saved_git_config_global = $env:GIT_CONFIG_GLOBAL
    initialize-pipeline-environment
    try
    {
        $ado_header = Invoke-NativeWithTimeout -File git -Arguments @(
            'config',
            '--get-urlmatch',
            'http.extraheader',
            'https://dev.azure.com/msazure/One/_git/Repo')
        assert-true ($ado_header.ExitCode -eq 0) 'Pipeline git authentication did not match dev.azure.com URLs.'
        assert-true ($ado_header.StdOut.Contains($env:SYSTEM_ACCESSTOKEN)) 'Pipeline git authentication did not use SYSTEM_ACCESSTOKEN.'

        $ado_user_header = Invoke-NativeWithTimeout -File git -Arguments @(
            'config',
            '--get-urlmatch',
            'http.extraheader',
            'https://msazure@dev.azure.com/msazure/One/_git/Repo')
        assert-true ($ado_user_header.ExitCode -eq 0) 'Pipeline git authentication did not match dev.azure.com URLs with embedded user names.'

        $visualstudio_header = Invoke-NativeWithTimeout -File git -Arguments @(
            'config',
            '--get-urlmatch',
            'http.extraheader',
            'https://msazure.visualstudio.com/One/_git/Repo')
        assert-true ($visualstudio_header.ExitCode -eq 0) 'Pipeline git authentication did not match visualstudio.com URLs.'

        $git_config_contents = Get-Content -Path $env:GIT_CONFIG_GLOBAL -Raw
        assert-true (-not $git_config_contents.Contains($env:SYSTEM_ACCESSTOKEN)) 'Pipeline git authentication wrote SYSTEM_ACCESSTOKEN to disk.'
    }
    finally
    {
        remove-pipeline-environment
    }
    assert-true ($env:GIT_CONFIG_GLOBAL -eq $saved_git_config_global) 'Pipeline environment cleanup did not restore GIT_CONFIG_GLOBAL.'

    $gate_summary = format-gate-summary -gates @(
        @{ Name = 'build'; State = 'running' },
        @{ Name = 'approval'; State = 'awaiting-action' },
        @{ Name = 'lint'; State = 'done' })
    assert-true ($gate_summary.Contains('1 running')) 'Gate summary did not report running checks.'
    assert-true ($gate_summary.Contains('approval')) 'Gate summary did not name checks awaiting action.'

    . (Join-Path $pipeline_helpers 'update_repo.ps1')
    $edges = @{
        leaf = @()
        parent = @('leaf')
    }
    $done = New-Object 'System.Collections.Generic.HashSet[string]'
    $unfinished = @(get-unfinished-dependencies -repo_name 'parent' -repo_edges $edges -done $done)
    assert-true ($unfinished.Count -eq 1 -and $unfinished[0] -eq 'leaf') 'Greedy scheduling did not block a parent with an unfinished dependency.'
    [void]$done.Add('leaf')
    $unfinished = @(get-unfinished-dependencies -repo_name 'parent' -repo_edges $edges -done $done)
    assert-true ($unfinished.Count -eq 0) 'Greedy scheduling did not release a parent after its dependency completed.'

    $temp_dir = Join-Path ([System.IO.Path]::GetTempPath()) "cbt-pipeline-mode-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $temp_dir | Out-Null
    try
    {
        $temp_entry = Join-Path $temp_dir 'propagate_updates.ps1'
        $temp_pipeline = Join-Path $temp_dir 'propagate_updates_pipeline.ps1'
        Copy-Item -Path $entry_script -Destination $temp_entry
        $stub = @'
param(
    [Int32] $azure_work_item,
    [Int32] $poll_interval,
    [switch] $NoCloseFailedPr,
    [string[]] $root_list
)
[pscustomobject]@{
    azure_work_item = $azure_work_item
    poll_interval = $poll_interval
    no_close = $NoCloseFailedPr.IsPresent
    roots = $root_list
} | ConvertTo-Json -Compress
'@
        [System.IO.File]::WriteAllText($temp_pipeline, $stub, [System.Text.UTF8Encoding]::new($false))

        $dispatch = Invoke-NativeWithTimeout -File $powershell_exe -Arguments @(
            '-NoProfile',
            '-File',
            $temp_entry,
            '-Pipeline',
            '-azure_work_item',
            '42',
            '-poll_interval',
            '7',
            '-NoCloseFailedPr',
            '-root_list',
            'repo-a') -TimeoutSec 30
        assert-true ($dispatch.ExitCode -eq 0) "Pipeline dispatch failed: $($dispatch.StdErr)"
        if ($dispatch.ExitCode -eq 0)
        {
            $forwarded = $dispatch.StdOut | ConvertFrom-Json
            assert-true ($forwarded.azure_work_item -eq 42) 'Pipeline dispatch did not forward -azure_work_item.'
            assert-true ($forwarded.poll_interval -eq 7) 'Pipeline dispatch did not forward -poll_interval.'
            assert-true ($forwarded.no_close) 'Pipeline dispatch did not forward -NoCloseFailedPr.'
            assert-true ($forwarded.roots[0] -eq 'repo-a') 'Pipeline dispatch did not forward -root_list.'
        }

        $unsupported = Invoke-NativeWithTimeout -File $powershell_exe -Arguments @(
            '-NoProfile',
            '-File',
            $temp_entry,
            '-Pipeline',
            '-Resume') -TimeoutSec 30
        $unsupported_output = "$($unsupported.StdOut)`n$($unsupported.StdErr)"
        assert-true ($unsupported.ExitCode -ne 0) 'Pipeline mode accepted the interactive-only -Resume switch.'
        assert-true ($unsupported_output.Contains('does not support')) 'Pipeline mode did not explain why -Resume was rejected.'
    }
    finally
    {
        if (Test-Path $temp_dir)
        {
            Remove-Item -Path $temp_dir -Recurse -Force
        }
    }
}
finally
{
    $env:SYSTEM_ACCESSTOKEN = $saved_system_token
    $env:GH_TOKEN = $saved_gh_token
}

if ($failures.Count -gt 0)
{
    foreach ($failure in $failures)
    {
        Write-Error $failure
    }
    exit 1
}

Write-Host 'Pipeline mode tests passed.'
