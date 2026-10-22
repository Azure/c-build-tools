# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Tests for update_deps/propagate_updates.ps1 and its helpers, in both interactive and -Pipeline
# mode. Nothing here creates branches or pull requests: remote services are mocked, and git runs
# against local repositories in a temporary directory.

$ErrorActionPreference = 'Continue'

$update_deps_root = Split-Path $PSScriptRoot -Parent
$entry_script = Join-Path $update_deps_root 'propagate_updates.ps1'
$helper_root = Join-Path $update_deps_root 'helper_scripts'
$powershell_exe = (Get-Process -Id $PID).Path
$failures = New-Object System.Collections.Generic.List[string]
$script:current_test = ''

function assert-true
{
    param(
        [bool] $Condition,
        [string] $Message
    )
    if (-not $Condition)
    {
        $failures.Add("[$script:current_test] $Message")
    }
    else
    {
        # passed
    }
}

function run-test
{
    param(
        [string] $Name,
        [scriptblock] $Body
    )
    $script:current_test = $Name
    Write-Host "--- $Name"
    Push-Location
    try
    {
        & $Body
    }
    catch
    {
        $failures.Add("[$Name] threw: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)")
    }
    finally
    {
        Pop-Location
    }
}

function get-script-ast
{
    param([string] $path)
    $tokens = $null
    $errors = $null
    return [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
}

# Run git, failing the test on error. Returns the command output.
function invoke-git
{
    param([string[]] $git_args)
    $output = & git @git_args 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "git $($git_args -join ' ') failed: $($output | Out-String)"
    }
    else
    {
        return $output
    }
}

# Commit with a message read from a file, so quotes survive Windows PowerShell argument passing.
function commit-with-message
{
    param(
        [string] $repo,
        [string] $message
    )
    $file = Join-Path $test_root ([guid]::NewGuid().ToString('N') + '.msg')
    [System.IO.File]::WriteAllText($file, $message, (New-Object System.Text.UTF8Encoding $false))
    invoke-git @('-C', $repo, 'commit', '-q', '--allow-empty', '-F', $file) | Out-Null
    Remove-Item -Path $file
}

# An error record shaped like a failed Invoke-RestMethod call.
function new-http-error
{
    param(
        [int] $status,
        [string] $message = 'simulated failure',
        [string] $retry_after = $null
    )
    $exception = New-Object System.Exception "Response status code does not indicate success: $status"
    $headers = @{}
    if ($retry_after) { $headers['Retry-After'] = $retry_after }
    $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $status; Headers = $headers })
    $record = New-Object System.Management.Automation.ErrorRecord ($exception, 'SimulatedHttpError', 'NotSpecified', $null)
    $record.ErrorDetails = New-Object System.Management.Automation.ErrorDetails ('{"message":"' + $message + '"}')
    return $record
}

# Run propagate_updates.ps1 in a child process from an empty directory.
function invoke-entry-script
{
    param(
        [string[]] $arguments = @(),
        [string] $command = $null
    )
    $work = Join-Path $test_root ("entry" + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $work | Out-Null
    Push-Location $work
    try
    {
        if ($command)
        {
            $run = Invoke-NativeWithTimeout -File $powershell_exe -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $command) -TimeoutSec 180
        }
        else
        {
            $run = Invoke-NativeWithTimeout -File $powershell_exe -Arguments (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $entry_script) + $arguments) -TimeoutSec 180
        }
    }
    finally
    {
        Pop-Location
    }
    return [pscustomobject]@{
        ExitCode = $run.ExitCode
        Output = "$($run.StdOut)`n$($run.StdErr)"
        WorkDirs = @(Get-ChildItem -Path $work -Directory -Filter 'new_deps_*')
    }
}

# Run 'git ls-remote' against a local TCP listener and return the raw HTTP request git sent. The
# listener answers 404, so git stops after this one request.
function get-git-http-request
{
    param(
        [System.Net.Sockets.TcpListener] $listener,
        [string] $url
    )
    $accept = $listener.AcceptTcpClientAsync()
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Command -Name git -CommandType Application | Select-Object -First 1).Path
    $info.Arguments = "ls-remote $url"
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    # A machine proxy must not intercept the loopback request.
    $info.EnvironmentVariables['NO_PROXY'] = '*'
    $git = [System.Diagnostics.Process]::Start($info)
    [void]$git.StandardOutput.ReadToEndAsync()
    [void]$git.StandardError.ReadToEndAsync()
    $request = ''
    try
    {
        if ($accept.Wait(30000))
        {
            $client = $accept.Result
            try
            {
                $stream = $client.GetStream()
                $stream.ReadTimeout = 10000
                $buffer = New-Object byte[] 8192
                $text = New-Object System.Text.StringBuilder
                while ($text.ToString() -notmatch "`r`n`r`n")
                {
                    $read = $stream.Read($buffer, 0, $buffer.Length)
                    if ($read -le 0) { break }
                    [void]$text.Append([System.Text.Encoding]::ASCII.GetString($buffer, 0, $read))
                }
                $request = $text.ToString()
                $reply = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                $stream.Write($reply, 0, $reply.Length)
            }
            finally
            {
                $client.Close()
            }
        }
        else
        {
            # git never connected; the caller's assertions report the empty request
        }
    }
    finally
    {
        if (-not $git.WaitForExit(30000)) { $git.Kill() }
        $git.Dispose()
    }
    return $request
}

# Isolate the environment: no real credentials, and git sees only a test configuration.
$saved_location = Get-Location
$saved_env = @{}
foreach ($variable in @(Get-ChildItem Env: | Where-Object { $_.Name -match '^(GIT_|GH_|GCM_|SYSTEM_ACCESSTOKEN$|AZURE_DEVOPS_EXT_PAT$|ghToken$)' }))
{
    $saved_env[$variable.Name] = $variable.Value
    Remove-Item -Path "Env:$($variable.Name)"
}
$test_root = Join-Path ([System.IO.Path]::GetTempPath()) ("cbtud" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $test_root | Out-Null
$test_git_config = Join-Path $test_root 'test.gitconfig'
$env:GIT_CONFIG_NOSYSTEM = '1'
$env:GIT_CONFIG_GLOBAL = $test_git_config
& git config --global user.name 'propagation test'
& git config --global user.email 'propagation-test@example.com'
& git config --global protocol.file.allow always
& git config --global init.defaultBranch master
& git config --global core.autocrlf false

. (Join-Path $helper_root 'load_helpers.ps1')

# fail-with-status ends the process; tests need it to throw instead.
function fail-with-status
{
    param([string] $message)
    throw "fail-with-status: $message"
}

# update_deps.ps1 is an unrelated standalone script; static checks cover only the propagation scripts.
$production_files = @(@(Get-Item -Path $entry_script) + @(Get-ChildItem -Path $helper_root -File -Filter *.ps1))

# Build the dependency graph that get-repo-update-order takes, from an ordered map of each repo to the repos it depends on.
function new-repo-edges
{
    param([System.Collections.Specialized.OrderedDictionary] $dependencies)
    $edges = New-Object 'System.Collections.Generic.Dictionary[string, System.Collections.ArrayList]'
    foreach ($repo in $dependencies.Keys)
    {
        $edges[$repo] = [System.Collections.ArrayList]@($dependencies[$repo])
    }
    return ,$edges
}

# Mocks shared by several tests. Dot-source one in a test, so that the functions it defines replace the real commands for
# that test only.

# Replaces az: each call is recorded in $script:az_calls and issues a new access token, wam-token-<call number>.
$mock_az_tokens = {
    $script:az_calls = @()
    $script:ado_token_cache = @{}
    function az
    {
        $script:az_calls += ,@($args)
        $global:LASTEXITCODE = 0
        return ('{{"accessToken":"wam-token-{0}","expires_on":{1}}}' -f $script:az_calls.Count, [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds())
    }
}

# Replaces Invoke-RestMethod: each request is recorded in $script:rest_calls and answered with the next response queued by
# set-responses. A queued error record is thrown.
$mock_rest_responses = {
    $script:rest_calls = New-Object System.Collections.ArrayList
    $script:rest_responses = New-Object System.Collections.Queue
    function Invoke-RestMethod
    {
        [CmdletBinding()]
        param($Method, $Uri, $Headers, $TimeoutSec, $UseBasicParsing, $ContentType, $Body, $OperationTimeoutSeconds)
        [void]$script:rest_calls.Add(@{ Method = $Method; Uri = $Uri; Headers = $Headers; ContentType = $ContentType; Body = $Body })
        $next = $script:rest_responses.Dequeue()
        if ($next -is [System.Management.Automation.ErrorRecord]) { throw $next }
        return $next
    }
    function set-responses
    {
        param([object[]] $responses)
        foreach ($response in $responses) { $script:rest_responses.Enqueue($response) }
    }
}

# Replaces Invoke-NativeWithTimeout for gh: 'gh pr view' reports a PR in $script:gh_state (initially OPEN) that awaits
# review and has auto-merge enabled, and 'gh pr checks' reports $script:gh_checks. Each call is recorded in $script:gh_calls.
$mock_gh_pr = {
    $script:gh_state = 'OPEN'
    $script:gh_checks = '[]'
    $script:gh_calls = New-Object System.Collections.ArrayList
    function Invoke-NativeWithTimeout
    {
        param([string] $File, [string[]] $Arguments = @(), [int] $TimeoutSec = 120)
        [void]$script:gh_calls.Add(($Arguments -join ' '))
        $stdout = ''
        if ($Arguments[0] -eq 'pr' -and $Arguments[1] -eq 'view')
        {
            $stdout = '{"state":"' + $script:gh_state + '","reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"BLOCKED","isDraft":false,"autoMergeRequest":{"enabledAt":"x"}}'
        }
        elseif ($Arguments[0] -eq 'pr' -and $Arguments[1] -eq 'checks')
        {
            $stdout = $script:gh_checks
        }
        else
        {
            # other gh commands succeed silently
        }
        return [pscustomobject]@{ ExitCode = 0; StdOut = $stdout; StdErr = ''; TimedOut = $false }
    }
}

# Replaces invoke-ado-rest for Azure DevOps PR 7 and work item 4242: the work item links the PR while $script:linked is set
# (initially), updates succeed, and creating a PR fails because PR 7 is already active. Each call is recorded in
# $script:ado_calls.
$mock_ado_work_items = {
    $script:ado_calls = New-Object System.Collections.ArrayList
    $script:linked = $true
    function invoke-ado-rest
    {
        param([string] $Method, [string] $Url, $Body = $null, [string] $BodyJson = $null, [string] $ContentType = '', [string] $Accept = $null, [int] $TimeoutSec = 0, [int] $MaxAttempts = 3, [switch] $AllowText)
        [void]$script:ado_calls.Add("$Method $Url")
        if ($Url -like '*/_apis/git/pullrequests/*')
        {
            return [pscustomobject]@{ pullRequestId = 7; status = 'active'; repository = [pscustomobject]@{ id = 'repo-id'; project = [pscustomobject]@{ id = 'project-id' } } }
        }
        elseif ($Method -eq 'GET' -and $Url -like '*/_apis/wit/workitems/4242*')
        {
            $relations = @()
            if ($script:linked) { $relations += [pscustomobject]@{ rel = 'ArtifactLink'; url = 'vstfs:///Git/PullRequestId/project-id%2Frepo-id%2F7' } }
            return [pscustomobject]@{ relations = $relations }
        }
        elseif ($Method -eq 'PATCH')
        {
            return [pscustomobject]@{ id = 4242 }
        }
        elseif ($Method -eq 'POST')
        {
            throw (new-http-error 409 'TF401179: An active pull request for the source and target branch already exists.')
        }
        else
        {
            throw "unexpected call $Method $Url"
        }
    }
}

try
{
    # Tests that every PowerShell script under update_deps parses.
    # Steps:
    # 1. Parse each .ps1 file under update_deps, and collect the parse errors.
    # 2. Verify that there are no parse errors.
    run-test 'scripts parse' {
        # Act
        # 1. Parse each .ps1 file under update_deps, and collect the parse errors.
        $parse_errors = @()
        foreach ($file in Get-ChildItem -Path $update_deps_root -Recurse -File -Filter *.ps1)
        {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            foreach ($parse_error in $errors)
            {
                $parse_errors += "$($file.Name):$($parse_error.Extent.StartLineNumber) $($parse_error.Message)"
            }
        }

        # Assert
        # 2. Verify that there are no parse errors.
        assert-true ($parse_errors.Count -eq 0) ($parse_errors -join "`n    ")
    }

    # Tests that both modes run the same entry script with the same helpers.
    # Steps:
    # 1. Look for a separate pipeline entry script or helper folder.
    # 2. Verify that neither exists.
    run-test 'both modes share one entry script and helper set' {
        # Act
        # 1. Look for a separate pipeline entry script or helper folder.
        $pipeline_copies = @(@('propagate_updates_pipeline.ps1', 'pipeline_helper_scripts') | Where-Object { Test-Path (Join-Path $update_deps_root $_) })

        # Assert
        # 2. Verify that neither exists.
        assert-true ($pipeline_copies.Count -eq 0) "both modes must use propagate_updates.ps1 and helper_scripts; found $($pipeline_copies -join ', ')."
    }

    # Tests that the entry script can dot-source every helper: no helper declares script parameters, which would overwrite
    # the entry script's parameters, and no function is defined twice.
    # Steps:
    # 1. Find the helpers that declare script parameters.
    # 2. Find the functions that more than one production script defines.
    # 3. Verify that there are none of either.
    run-test 'helpers are safe to dot-source together' {
        # Act
        # 1. Find the helpers that declare script parameters.
        $parameterized = @(Get-ChildItem -Path $helper_root -Filter *.ps1 | Where-Object { (get-script-ast $_.FullName).ParamBlock } | ForEach-Object { $_.Name })

        # 2. Find the functions that more than one production script defines.
        $definitions = @{}
        $duplicates = @()
        foreach ($file in $production_files)
        {
            foreach ($function_ast in (get-script-ast $file.FullName).FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
            {
                $name = ($function_ast.Name -replace '^(global|script):', '').ToLowerInvariant()
                if ($definitions.ContainsKey($name))
                {
                    $duplicates += "$name is defined in both $($definitions[$name]) and $($file.Name)."
                }
                else
                {
                    $definitions[$name] = $file.Name
                }
            }
        }

        # Assert
        # 3. Verify that there are none of either.
        assert-true ($parameterized.Count -eq 0) "dot-sourcing these helpers would overwrite the entry script's parameters: $($parameterized -join ', ')."
        assert-true ($duplicates.Count -eq 0) ($duplicates -join "`n    ")
    }

    # Tests that every command the production scripts call exists, and that each call to a production function passes only
    # parameters that the function declares.
    # Steps:
    # 1. Collect each production function's parameters, and every command call.
    # 2. Find the calls to unknown commands, and the calls that pass an undeclared parameter.
    # 3. Verify that there are none.
    run-test 'command references resolve' {
        # Arrange
        # 1. Collect each production function's parameters, and every command call.
        $functions = @{}
        $calls = @()
        foreach ($file in $production_files)
        {
            $ast = get-script-ast $file.FullName
            foreach ($function_ast in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
            {
                $parameters = @()
                if ($function_ast.Body.ParamBlock) { $parameters += @($function_ast.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
                if ($function_ast.Parameters) { $parameters += @($function_ast.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
                $functions[($function_ast.Name -replace '^(global|script):', '').ToLowerInvariant()] = $parameters
            }
            foreach ($command_ast in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
            {
                $calls += [pscustomobject]@{ Ast = $command_ast; File = $file.Name }
            }
        }
        $external = @('git', 'gh', 'az', 'winget', 'copilot', 'cmake', 'taskkill.exe')
        $common = @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable')

        # Act
        # 2. Find the calls to unknown commands, and the calls that pass an undeclared parameter.
        $problems = @()
        foreach ($call in $calls)
        {
            $name = $call.Ast.GetCommandName()
            if (-not $name) { continue }
            $location = "$($call.File):$($call.Ast.Extent.StartLineNumber)"
            $key = $name.ToLowerInvariant()
            if ($functions.ContainsKey($key))
            {
                foreach ($element in @($call.Ast.CommandElements | Select-Object -Skip 1 | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] }))
                {
                    $parameter = $element.ParameterName
                    $known = ($common -contains $parameter) -or (@($functions[$key] | Where-Object { $_ -like "$parameter*" }).Count -gt 0)
                    if (-not $known) { $problems += "$location calls $name with unknown parameter -$parameter." }
                }
            }
            else
            {
                $resolved = ($external -contains $name) -or [bool](Get-Command -Name $name -CommandType Cmdlet, Alias, Function -ErrorAction SilentlyContinue)
                if (-not $resolved) { $problems += "$location calls unknown command $name." }
            }
        }

        # Assert
        # 3. Verify that there are none.
        assert-true ($problems.Count -eq 0) ($problems -join "`n    ")
    }

    # Tests that the production scripts reach Azure DevOps and git remotes only through the shared primitives, which bound
    # and retry network calls, and that they never stage the whole repository.
    # Steps:
    # 1. List the line patterns that bypass the shared primitives or stage the whole repository.
    # 2. Find the production lines, outside comments, that match a pattern.
    # 3. Verify that there are none.
    run-test 'network commands go through the shared primitives' {
        # Arrange
        # 1. List the line patterns that bypass the shared primitives or stage the whole repository.
        $bypasses = @(
            @{ Pattern = '\baz\s+(repos|devops|pipelines)\b'; Problem = 'calls the Azure DevOps CLI; use invoke-ado-rest.' },
            @{ Pattern = '^\s*(\$\w+\s*=\s*)?\(?git\s+(clone|fetch|pull|push|submodule\s+update)\b'; Problem = 'runs a network git command directly; use invoke-git-command.' },
            @{ Pattern = '^\s*git\s+add\s+\.\s*$'; Problem = 'stages the whole repository.' }
        )

        # Act
        # 2. Find the production lines, outside comments, that match a pattern.
        $problems = @()
        foreach ($file in $production_files)
        {
            $lines = @(Get-Content -Path $file.FullName)
            for ($i = 0; $i -lt $lines.Count; $i++)
            {
                if ($lines[$i] -match '^\s*#') { continue }
                foreach ($bypass in $bypasses)
                {
                    if ($lines[$i] -match $bypass.Pattern) { $problems += "$($file.Name):$($i + 1) $($bypass.Problem)" }
                }
            }
        }

        # Assert
        # 3. Verify that there are none.
        assert-true ($problems.Count -eq 0) ($problems -join "`n    ")
    }

    # Tests that -Pipeline rejects a parameter that only interactive mode supports.
    # Steps:
    # 1. Run propagate_updates.ps1 -Pipeline -Resume.
    # 2. Verify that the run fails and names -Resume as unsupported.
    run-test 'pipeline mode rejects interactive-only parameters' {
        # Act
        # 1. Run propagate_updates.ps1 -Pipeline -Resume.
        $result = invoke-entry-script -arguments @('-Pipeline', '-Resume')

        # Assert
        # 2. Verify that the run fails and names -Resume as unsupported.
        assert-true ($result.ExitCode -ne 0) '-Pipeline -Resume must fail.'
        assert-true ($result.Output -match 'does not support: -Resume') "unexpected output: $($result.Output)"
    }

    # Tests that, in each mode, a run without -azure_work_item fails before it sets up any tool or creates a work directory.
    # Steps:
    # 1. Build the mode's arguments, without -azure_work_item.
    # 2. Run propagate_updates.ps1.
    # 3. Verify that the run failed for the missing -azure_work_item, before tool setup and without a work directory.
    foreach ($mode in @('interactive', 'pipeline'))
    {
        run-test "missing arguments fail before any setup ($mode)" {
            # Arrange
            # 1. Build the mode's arguments, without -azure_work_item.
            $arguments = @('-root_list', 'https://dev.azure.com/org/project/_git/repo')
            if ($mode -eq 'pipeline') { $arguments = @('-Pipeline') + $arguments }

            # Act
            # 2. Run propagate_updates.ps1.
            $result = invoke-entry-script -arguments $arguments

            # Assert
            # 3. Verify that the run failed for the missing -azure_work_item, before tool setup and without a work directory.
            assert-true ($result.ExitCode -ne 0) 'a run without -azure_work_item must fail.'
            assert-true ($result.Output -match 'azure_work_item is required') "output: $($result.Output)"
            assert-true ($result.Output -notmatch 'Checking PowerShell environment') 'tool setup started before the arguments were validated.'
            assert-true ($result.WorkDirs.Count -eq 0) 'a work directory was created.'
        }
    }

    # Tests that -Pipeline checks its credentials before any other work, and keeps the parameters it was given.
    # Steps:
    # 1. Run propagate_updates.ps1 -Pipeline with -poll_interval 7 and -NoCloseFailedPr, without SYSTEM_ACCESSTOKEN or GH_TOKEN.
    # 2. Verify that the run kept -poll_interval and -NoCloseFailedPr.
    # 3. Verify that the preflight failed with exit code 1, reported both missing tokens, and created no work directory.
    run-test 'pipeline mode checks credentials first and keeps its parameters' {
        # Act
        # 1. Run propagate_updates.ps1 -Pipeline with -poll_interval 7 and -NoCloseFailedPr, without SYSTEM_ACCESSTOKEN or GH_TOKEN.
        $command = "`$ErrorActionPreference = 'Stop'; & '$entry_script' -Pipeline -azure_work_item 42 -poll_interval 7 -NoCloseFailedPr -root_list 'https://dev.azure.com/org/project/_git/repo'; exit `$LASTEXITCODE"
        $result = invoke-entry-script -command $command

        # Assert
        # 2. Verify that the run kept -poll_interval and -NoCloseFailedPr.
        assert-true ($result.Output -match 'poll interval: 7s') '-poll_interval was not preserved after loading the helpers.'
        assert-true ($result.Output -match 'close failed PR: False') '-NoCloseFailedPr was not honored.'

        # 3. Verify that the preflight failed with exit code 1, reported both missing tokens, and created no work directory.
        assert-true ($result.ExitCode -eq 1) "expected the preflight exit code 1, got $($result.ExitCode): $($result.Output)"
        assert-true ($result.Output -match 'SYSTEM_ACCESSTOKEN is not set') 'a missing SYSTEM_ACCESSTOKEN was not reported.'
        assert-true ($result.Output -match 'GH_TOKEN is not set') 'a missing GH_TOKEN was not reported.'
        assert-true ($result.WorkDirs.Count -eq 0) 'a work directory was created before the preflight passed.'
    }

    # Tests that pipeline mode logs timestamped Azure Pipelines log commands, and interactive mode logs plain messages.
    # Steps:
    # 1. Log a warning in pipeline mode, then in interactive mode.
    # 2. Verify that pipeline mode logged a timestamped warning command, and interactive mode logged only the message.
    run-test 'log format follows the mode' {
        # Act
        # 1. Log a warning in pipeline mode, then in interactive mode.
        $script:propagation_mode = 'pipeline'
        $pipeline_output = (& { Write-Log WARN 'pipeline message' } 6>&1 | Out-String).Trim()
        $script:propagation_mode = 'interactive'
        $interactive_output = (& { Write-Log WARN 'interactive message' } 6>&1 | Out-String).Trim()

        # Assert
        # 2. Verify that pipeline mode logged a timestamped warning command, and interactive mode logged only the message.
        assert-true ($pipeline_output -match '^##\[warning\]\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] \[WARN\] pipeline message$') "pipeline log line: $pipeline_output"
        assert-true ($interactive_output -eq 'interactive message') "interactive log line: $interactive_output"
    }

    # Tests that Protect-Secret removes registered secrets, GitHub tokens, and authorization headers from text.
    # Steps:
    # 1. Register a secret.
    # 2. Redact text that contains the secret, a GitHub token, and bearer and basic authorization headers.
    # 3. Verify that none of them remains.
    run-test 'secrets are redacted' {
        # Arrange
        # 1. Register a secret.
        add-redaction-value 'pat-secret-value-123'

        # Act
        # 2. Redact text that contains the secret, a GitHub token, and bearer and basic authorization headers.
        $text = Protect-Secret 'pat=pat-secret-value-123 token=ghp_abcdefghijklmnopqrstuvwxyz123456 Authorization: Bearer abc.def Authorization: Basic Zm9vOmJhcg=='

        # Assert
        # 3. Verify that none of them remains.
        assert-true ($text -notmatch 'pat-secret-value-123') "a registered secret leaked: $text"
        assert-true ($text -notmatch 'ghp_abcdefghijklmnopqrstuvwxyz') "a GitHub token leaked: $text"
        assert-true ($text -notmatch 'abc\.def' -and $text -notmatch 'Zm9vOmJhcg') "an authorization header leaked: $text"
    }

    # Tests that Invoke-NativeWithTimeout returns the exit code and output of a command that finishes.
    # Steps:
    # 1. Run a command that writes text.
    # 2. Verify that the command succeeded and its text was returned.
    run-test 'native commands return their output' {
        # Act
        # 1. Run a command that writes text.
        $result = Invoke-NativeWithTimeout -File $powershell_exe -Arguments @('-NoProfile', '-Command', "[Console]::Out.Write('bounded-ok')")

        # Assert
        # 2. Verify that the command succeeded and its text was returned.
        assert-true ($result.ExitCode -eq 0 -and $result.StdOut -eq 'bounded-ok') "stdout was not preserved: $($result.StdOut) $($result.StdErr)"
    }

    # Tests that Invoke-NativeWithTimeout stops a command that runs past its time limit.
    # Steps:
    # 1. Run a command that sleeps for 30 seconds, with a 2-second limit.
    # 2. Verify that the command was stopped and reported as timed out.
    run-test 'native commands that hang are stopped' {
        # Act
        # 1. Run a command that sleeps for 30 seconds, with a 2-second limit.
        $result = Invoke-NativeWithTimeout -File $powershell_exe -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -TimeoutSec 2

        # Assert
        # 2. Verify that the command was stopped and reported as timed out.
        assert-true ($result.TimedOut -and $result.ExitCode -eq -1) 'a hung command was not stopped.'
    }

    # Tests that Invoke-NativeWithRetry returns the exit code of its last attempt.
    # Steps:
    # 1. Run a command that always exits with 3, allowing two attempts.
    # 2. Verify that exit code 3 was returned.
    run-test 'native retries return the last exit code' {
        # Act
        # 1. Run a command that always exits with 3, allowing two attempts.
        $result = Invoke-NativeWithRetry -File $powershell_exe -Arguments @('-NoProfile', '-Command', 'exit 3') -MaxAttempts 2 -RetryDelaySec 0

        # Assert
        # 2. Verify that exit code 3 was returned.
        assert-true ($result.ExitCode -eq 3) "the last attempt's exit code was not returned: $($result.ExitCode)"
    }

    # Tests that, in each mode, invoke-git-command returns only the git exit code, so that callers can compare it to 0.
    # Steps:
    # 1. Select the mode.
    # 2. Run a git command that succeeds, and one that fails.
    # 3. Verify that each call returned only its integer exit code.
    foreach ($mode in @('pipeline', 'interactive'))
    {
        run-test "git commands return only their exit code ($mode)" {
            # Arrange
            # 1. Select the mode.
            $script:propagation_mode = $mode

            # Act
            # 2. Run a git command that succeeds, and one that fails.
            $ok = invoke-git-command -git_args @('--version')
            $bad = invoke-git-command -git_args @('no-such-command')

            # Assert
            # 3. Verify that each call returned only its integer exit code.
            assert-true ($ok -is [int] -and $ok -eq 0) "git --version returned '$ok'."
            assert-true ($bad -is [int] -and $bad -ne 0) "the failing git command returned '$bad'."
        }
    }

    # Tests that pipeline mode authenticates to Azure DevOps with SYSTEM_ACCESSTOKEN.
    # Steps:
    # 1. Select pipeline mode, and set SYSTEM_ACCESSTOKEN.
    # 2. Get the Azure DevOps authorization header.
    # 3. Verify that the header carries SYSTEM_ACCESSTOKEN as a bearer token.
    run-test 'pipeline mode authenticates Azure DevOps with SYSTEM_ACCESSTOKEN' {
        # Arrange
        # 1. Select pipeline mode, and set SYSTEM_ACCESSTOKEN.
        $script:propagation_mode = 'pipeline'
        $env:SYSTEM_ACCESSTOKEN = 'system-token-value'

        # Act
        # 2. Get the Azure DevOps authorization header.
        $header = get-ado-authorization-header -org_url 'https://dev.azure.com/org'

        # Assert
        # 3. Verify that the header carries SYSTEM_ACCESSTOKEN as a bearer token.
        assert-true ($header -eq 'Bearer system-token-value') 'pipeline mode must use SYSTEM_ACCESSTOKEN.'

        # Cleanup
        Remove-Item -Path Env:SYSTEM_ACCESSTOKEN
    }

    # Tests that interactive mode sends a PAT with Basic authentication, and that a PAT cannot be refreshed.
    # Steps:
    # 1. Select interactive mode with a PAT.
    # 2. Get the Azure DevOps authorization header, then try to refresh the token.
    # 3. Verify that the header is Basic authentication with the PAT, and that the refresh was refused.
    run-test 'interactive mode authenticates Azure DevOps with a PAT' {
        # Arrange
        # 1. Select interactive mode with a PAT.
        $script:propagation_mode = 'interactive'
        $script:ado_pat = 'personal-access-token'
        $expected = 'Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(':personal-access-token'))

        # Act
        # 2. Get the Azure DevOps authorization header, then try to refresh the token.
        $header = get-ado-authorization-header -org_url 'https://dev.azure.com/org'
        $refreshed = reset-ado-access-token -org_url 'https://dev.azure.com/org'

        # Assert
        # 3. Verify that the header is Basic authentication with the PAT, and that the refresh was refused.
        assert-true ($header -eq $expected) 'a PAT must use Basic authentication.'
        assert-true (-not $refreshed) 'a PAT cannot be refreshed.'

        # Cleanup
        $script:ado_pat = $null
    }

    # Tests that, without a PAT, interactive mode gets an Azure DevOps token from the Azure CLI for the organization's
    # tenant, caches it, and replaces it when asked to refresh it.
    # Steps:
    # 1. Select interactive mode without a PAT, and mock az and the organization's tenant.
    # 2. Get the authorization header twice.
    # 3. Refresh the token, and get the header again.
    # 4. Verify that az was called once, for the organization's tenant, and that both headers carry its token.
    # 5. Verify that the refresh succeeded, and that the header then carried a new token.
    run-test 'interactive mode caches and refreshes the Azure CLI token' {
        # Arrange
        # 1. Select interactive mode without a PAT, and mock az and the organization's tenant.
        $script:propagation_mode = 'interactive'
        $script:ado_pat = $null
        . $mock_az_tokens
        function get-ado-tenant-id { param([string] $org_url) return '72f988bf-86f1-41af-91ab-2d7cd011db47' }

        # Act
        # 2. Get the authorization header twice.
        $first = get-ado-authorization-header -org_url 'https://dev.azure.com/org'
        $second = get-ado-authorization-header -org_url 'https://dev.azure.com/org'
        $az_calls_before_refresh = $script:az_calls.Count

        # 3. Refresh the token, and get the header again.
        $refreshed = reset-ado-access-token -org_url 'https://dev.azure.com/org'
        $third = get-ado-authorization-header -org_url 'https://dev.azure.com/org'

        # Assert
        # 4. Verify that az was called once, for the organization's tenant, and that both headers carry its token.
        assert-true ($az_calls_before_refresh -eq 1) "az was called $az_calls_before_refresh times before the refresh."
        assert-true (($script:az_calls[0] -join ' ') -match '--tenant 72f988bf-86f1-41af-91ab-2d7cd011db47') 'the organization tenant was not requested.'
        assert-true ($first -eq 'Bearer wam-token-1' -and $second -eq $first) "the WAM token was not cached: $first / $second"

        # 5. Verify that the refresh succeeded, and that the header then carried a new token.
        assert-true $refreshed 'a WAM token must be refreshable.'
        assert-true ($third -eq 'Bearer wam-token-2') "the token was not refreshed: $third"

        # Cleanup
        $script:ado_token_cache = @{}
    }

    # Tests that a failing Azure CLI sign-in is retried, then thrown for the caller to handle; it never ends the run.
    # Steps:
    # 1. Select interactive mode without a PAT, and mock an az that always fails.
    # 2. Get the Azure DevOps authorization header.
    # 3. Verify that az was tried three times, and that the failure was thrown as an error the caller can catch.
    run-test 'Azure CLI sign-in failures are retried and then thrown' {
        # Arrange
        # 1. Select interactive mode without a PAT, and mock an az that always fails.
        $script:propagation_mode = 'interactive'
        $script:ado_pat = $null
        $script:ado_token_cache = @{}
        $script:az_calls = @()
        function get-ado-tenant-id { param([string] $org_url) return '72f988bf-86f1-41af-91ab-2d7cd011db47' }
        function az
        {
            $script:az_calls += ,@($args)
            $global:LASTEXITCODE = 1
        }
        function Start-Sleep { param([int] $Seconds) }

        # Act
        # 2. Get the Azure DevOps authorization header.
        $caught = $null
        try { [void](get-ado-authorization-header -org_url 'https://dev.azure.com/org') } catch { $caught = $_.Exception.Message }

        # Assert
        # 3. Verify that az was tried three times, and that the failure was thrown as an error the caller can catch.
        assert-true ($script:az_calls.Count -eq 3) "a failing az was tried $($script:az_calls.Count) times."
        assert-true ($caught -match 'az login' -and $caught -notmatch '^fail-with-status') "a token failure must throw an error the caller can handle: $caught"

        # Cleanup
        $script:ado_token_cache = @{}
    }

    # Tests that Azure DevOps REST requests send the authorization header, and ask the service not to redirect to a
    # sign-in page.
    # Steps:
    # 1. Select pipeline mode with SYSTEM_ACCESSTOKEN, and queue a successful response.
    # 2. Send a GET request.
    # 3. Verify that the request carried the pipeline token and suppressed sign-in redirects.
    run-test 'Azure DevOps REST requests authenticate without sign-in redirects' {
        # Arrange
        # 1. Select pipeline mode with SYSTEM_ACCESSTOKEN, and queue a successful response.
        $script:propagation_mode = 'pipeline'
        $env:SYSTEM_ACCESSTOKEN = 'system-token-value'
        . $mock_rest_responses
        set-responses @([pscustomobject]@{ value = 'ok' })

        # Act
        # 2. Send a GET request.
        [void](invoke-ado-rest -Method GET -Url 'https://dev.azure.com/org/_apis/test')

        # Assert
        # 3. Verify that the request carried the pipeline token and suppressed sign-in redirects.
        assert-true ($script:rest_calls[0].Headers['Authorization'] -eq 'Bearer system-token-value') 'the Authorization header was not sent.'
        assert-true ($script:rest_calls[0].Headers['X-TFS-FedAuthRedirect'] -eq 'Suppress') 'X-TFS-FedAuthRedirect was not sent.'

        # Cleanup
        Remove-Item -Path Env:SYSTEM_ACCESSTOKEN
    }

    # Tests that a read that failed with a server error is retried.
    # Steps:
    # 1. Select pipeline mode with SYSTEM_ACCESSTOKEN, and queue a 503 response with Retry-After, then a success.
    # 2. Send a GET request.
    # 3. Verify that the request was sent twice, and returned the success.
    run-test 'Azure DevOps REST retries a read after a server error' {
        # Arrange
        # 1. Select pipeline mode with SYSTEM_ACCESSTOKEN, and queue a 503 response with Retry-After, then a success.
        $script:propagation_mode = 'pipeline'
        $env:SYSTEM_ACCESSTOKEN = 'system-token-value'
        . $mock_rest_responses
        set-responses @((new-http-error 503 -retry_after '1'), [pscustomobject]@{ value = 'ok' })

        # Act
        # 2. Send a GET request.
        $result = invoke-ado-rest -Method GET -Url 'https://dev.azure.com/org/_apis/test'

        # Assert
        # 3. Verify that the request was sent twice, and returned the success.
        assert-true ($result.value -eq 'ok' -and $script:rest_calls.Count -eq 2) "a 503 GET was not retried ($($script:rest_calls.Count) calls)."

        # Cleanup
        Remove-Item -Path Env:SYSTEM_ACCESSTOKEN
    }

    # Tests that a read that the service reports as not found fails at once, with the service's error message.
    # Steps:
    # 1. Select pipeline mode with SYSTEM_ACCESSTOKEN, and queue a 404 response with an error message.
    # 2. Send a GET request.
    # 3. Verify that the request was sent once, and failed with status 404 and the service's message.
    run-test 'Azure DevOps REST does not retry a read that was not found' {
        # Arrange
        # 1. Select pipeline mode with SYSTEM_ACCESSTOKEN, and queue a 404 response with an error message.
        $script:propagation_mode = 'pipeline'
        $env:SYSTEM_ACCESSTOKEN = 'system-token-value'
        . $mock_rest_responses
        set-responses @((new-http-error 404 'TF401019: not found'))

        # Act
        # 2. Send a GET request.
        $caught = $null
        try { invoke-ado-rest -Method GET -Url 'https://dev.azure.com/org/_apis/test' } catch { $caught = $_ }

        # Assert
        # 3. Verify that the request was sent once, and failed with status 404 and the service's message.
        assert-true ($caught -and (get-http-status-code $caught) -eq 404 -and $script:rest_calls.Count -eq 1) 'a 404 GET must fail without retrying.'
        assert-true ((get-ado-error-message $caught) -eq 'TF401019: not found') "the service error message was lost: $(get-ado-error-message $caught)"

        # Cleanup
        Remove-Item -Path Env:SYSTEM_ACCESSTOKEN
    }

    # Tests that a write that failed with a server error is not retried, since the service may have applied it.
    # Steps:
    # 1. Select pipeline mode with SYSTEM_ACCESSTOKEN, and queue a 500 response.
    # 2. Send a POST request.
    # 3. Verify that the request was sent once, and failed.
    run-test 'Azure DevOps REST does not retry a write after a server error' {
        # Arrange
        # 1. Select pipeline mode with SYSTEM_ACCESSTOKEN, and queue a 500 response.
        $script:propagation_mode = 'pipeline'
        $env:SYSTEM_ACCESSTOKEN = 'system-token-value'
        . $mock_rest_responses
        set-responses @((new-http-error 500))

        # Act
        # 2. Send a POST request.
        $caught = $null
        try { invoke-ado-rest -Method POST -Url 'https://dev.azure.com/org/_apis/test' -Body @{ a = 1 } } catch { $caught = $_ }

        # Assert
        # 3. Verify that the request was sent once, and failed.
        assert-true ($caught -and $script:rest_calls.Count -eq 1) 'a write that failed with a server error must not be retried.'

        # Cleanup
        Remove-Item -Path Env:SYSTEM_ACCESSTOKEN
    }

    # Tests that a throttled write is retried, since the service did not apply it.
    # Steps:
    # 1. Select pipeline mode with SYSTEM_ACCESSTOKEN, and queue a 429 response with Retry-After, then a success.
    # 2. Send a PATCH request.
    # 3. Verify that the request was sent twice, and returned the success.
    run-test 'Azure DevOps REST retries a throttled write' {
        # Arrange
        # 1. Select pipeline mode with SYSTEM_ACCESSTOKEN, and queue a 429 response with Retry-After, then a success.
        $script:propagation_mode = 'pipeline'
        $env:SYSTEM_ACCESSTOKEN = 'system-token-value'
        . $mock_rest_responses
        set-responses @((new-http-error 429 -retry_after '1'), [pscustomobject]@{ id = 7 })

        # Act
        # 2. Send a PATCH request.
        $result = invoke-ado-rest -Method PATCH -Url 'https://dev.azure.com/org/_apis/test' -Body @{ status = 'active' }

        # Assert
        # 3. Verify that the request was sent twice, and returned the success.
        assert-true ($result.id -eq 7 -and $script:rest_calls.Count -eq 2) 'a throttled write was not retried.'

        # Cleanup
        Remove-Item -Path Env:SYSTEM_ACCESSTOKEN
    }

    # Tests that an HTML page, such as a sign-in page, is not accepted as a REST result.
    # Steps:
    # 1. Select pipeline mode with SYSTEM_ACCESSTOKEN, and queue an HTML sign-in page as the response.
    # 2. Send a GET request.
    # 3. Verify that the request failed as a non-JSON response.
    run-test 'Azure DevOps REST rejects a sign-in page' {
        # Arrange
        # 1. Select pipeline mode with SYSTEM_ACCESSTOKEN, and queue an HTML sign-in page as the response.
        $script:propagation_mode = 'pipeline'
        $env:SYSTEM_ACCESSTOKEN = 'system-token-value'
        . $mock_rest_responses
        set-responses @('<html>sign in</html>')

        # Act
        # 2. Send a GET request.
        $caught = $null
        try { invoke-ado-rest -Method GET -Url 'https://dev.azure.com/org/_apis/test' } catch { $caught = $_ }

        # Assert
        # 3. Verify that the request failed as a non-JSON response.
        assert-true ($caught -and $caught.Exception.Message -match 'non-JSON') 'an HTML sign-in page was accepted as a result.'

        # Cleanup
        Remove-Item -Path Env:SYSTEM_ACCESSTOKEN
    }

    # Tests that request bodies are sent as UTF-8 JSON, so that non-ASCII text survives.
    # Steps:
    # 1. Select pipeline mode with SYSTEM_ACCESSTOKEN, and queue a successful response.
    # 2. Send a POST request whose body has non-ASCII text.
    # 3. Verify that the request declared UTF-8 JSON, and that its body decodes from UTF-8 to the same text.
    run-test 'Azure DevOps REST sends UTF-8 JSON' {
        # Arrange
        # 1. Select pipeline mode with SYSTEM_ACCESSTOKEN, and queue a successful response.
        $script:propagation_mode = 'pipeline'
        $env:SYSTEM_ACCESSTOKEN = 'system-token-value'
        . $mock_rest_responses
        set-responses @([pscustomobject]@{ id = 1 })

        # Act
        # 2. Send a POST request whose body has non-ASCII text.
        $title = 'caf' + [char]0x00E9 + ' ' + [char]0x2014 + ' ok'
        [void](invoke-ado-rest -Method POST -Url 'https://dev.azure.com/org/_apis/test' -Body @{ title = $title })

        # Assert
        # 3. Verify that the request declared UTF-8 JSON, and that its body decodes from UTF-8 to the same text.
        $call = $script:rest_calls[0]
        assert-true ($call.ContentType -eq 'application/json; charset=utf-8') "unexpected content type: $($call.ContentType)"
        assert-true ((([System.Text.Encoding]::UTF8.GetString($call.Body)) | ConvertFrom-Json).title -eq $title) 'the request body was not UTF-8.'

        # Cleanup
        Remove-Item -Path Env:SYSTEM_ACCESSTOKEN
    }

    # Tests that interactive mode refreshes a token that Azure DevOps rejected, and retries the request once with the new
    # token.
    # Steps:
    # 1. Select interactive mode without a PAT, mock az, and queue a 401 response, then a success.
    # 2. Send a POST request.
    # 3. Verify that a new token was requested, and that the request was retried once with it.
    run-test 'Azure DevOps REST refreshes a rejected interactive token once' {
        # Arrange
        # 1. Select interactive mode without a PAT, mock az, and queue a 401 response, then a success.
        $script:propagation_mode = 'interactive'
        $script:ado_pat = $null
        . $mock_az_tokens
        function get-ado-tenant-id { param([string] $org_url) return $null }
        . $mock_rest_responses
        set-responses @((new-http-error 401), [pscustomobject]@{ ok = $true })

        # Act
        # 2. Send a POST request.
        $result = invoke-ado-rest -Method POST -Url 'https://dev.azure.com/org/_apis/test' -Body @{ a = 1 }

        # Assert
        # 3. Verify that a new token was requested, and that the request was retried once with it.
        assert-true ($result.ok -and $script:rest_calls.Count -eq 2 -and $script:az_calls.Count -eq 2) 'a rejected WAM token was not refreshed once.'
        assert-true ($script:rest_calls[1].Headers['Authorization'] -eq 'Bearer wam-token-2') 'the retry did not use the new token.'

        # Cleanup
        $script:ado_token_cache = @{}
    }

    # Tests that the pipeline git environment authenticates every Azure DevOps URL form without writing the token to disk,
    # keeps the caller's git settings, never prompts, and restores the caller's environment when it is removed.
    # Steps:
    # 1. Select pipeline mode with SYSTEM_ACCESSTOKEN, and give the caller git config entries and git -c parameters in the
    #    environment, but no global git config.
    # 2. Initialize the pipeline environment, and record the git configuration and prompt settings that it provides.
    # 3. Remove the pipeline environment.
    # 4. Verify that git was configured to send the token to each Azure DevOps URL form, kept the caller's settings,
    #    never prompted, and had a commit identity, and that the token was not written to the isolated global git config.
    # 5. Verify that the caller's environment was restored, and that the isolated global git config was deleted.
    run-test 'pipeline environment authenticates git without writing the token' {
        # Arrange
        # 1. Select pipeline mode with SYSTEM_ACCESSTOKEN, and give the caller git config entries and git -c parameters in the
        #    environment, but no global git config.
        $script:propagation_mode = 'pipeline'
        $env:SYSTEM_ACCESSTOKEN = 'pipeline-system-secret-123456'
        $saved_global = $env:GIT_CONFIG_GLOBAL
        Remove-Item -Path Env:GIT_CONFIG_GLOBAL
        $env:GIT_CONFIG_COUNT = '1'
        $env:GIT_CONFIG_KEY_0 = 'core.autocrlf'
        $env:GIT_CONFIG_VALUE_0 = 'input'
        $env:GIT_CONFIG_PARAMETERS = "'core.filemode=false'"
        $ado_urls = @('https://dev.azure.com/msazure/One/_git/Repo', 'https://msazure@dev.azure.com/msazure/One/_git/Repo', 'https://msazure.visualstudio.com/One/_git/Repo')

        # Act
        # 2. Initialize the pipeline environment, and record the git configuration and prompt settings that it provides.
        $headers = @{}
        initialize-pipeline-environment
        try
        {
            $temp_config = $env:GIT_CONFIG_GLOBAL
            $temp_config_created = $temp_config -and (Test-Path $temp_config)
            foreach ($url in $ado_urls)
            {
                $headers[$url] = (Invoke-NativeWithTimeout -File git -Arguments @('config', '--get-urlmatch', 'http.extraheader', $url)).StdOut.Trim()
            }
            $autocrlf = & git config --get core.autocrlf
            $filemode = & git config --get core.filemode
            $credential_interactive = & git config --get credential.interactive
            $user_name = & git config --global --get user.name
            $config_text = Get-Content -Raw -Path $temp_config
            $prompts_disabled = $env:GIT_TERMINAL_PROMPT -eq '0' -and $env:GCM_INTERACTIVE -eq 'never' -and $env:GH_PROMPT_DISABLED -eq '1'
        }
        finally
        {
            # 3. Remove the pipeline environment.
            remove-pipeline-environment
        }

        # Assert
        # 4. Verify that git was configured to send the token to each Azure DevOps URL form, kept the caller's settings,
        #    never prompted, and had a commit identity, and that the token was not written to the isolated global git config.
        assert-true $temp_config_created 'an isolated global git config was not created.'
        foreach ($url in $ado_urls)
        {
            assert-true ($headers[$url] -eq "AUTHORIZATION: bearer $($env:SYSTEM_ACCESSTOKEN)") "no Azure DevOps credential for $url."
        }
        assert-true ($autocrlf -eq 'input') 'git config entries from the caller environment were dropped.'
        assert-true ($filemode -eq 'false') "the caller's git -c parameters were dropped."
        assert-true ($credential_interactive -eq 'never') 'git credential prompts were not disabled.'
        assert-true ($user_name -eq 'c-build-tools dependency propagation') 'the commit identity was not configured.'
        assert-true ($config_text -notmatch [regex]::Escape($env:SYSTEM_ACCESSTOKEN)) 'the token was written to disk.'
        assert-true $prompts_disabled 'prompts were not disabled.'

        # 5. Verify that the caller's environment was restored, and that the isolated global git config was deleted.
        assert-true ($env:GIT_CONFIG_COUNT -eq '1' -and $env:GIT_CONFIG_KEY_0 -eq 'core.autocrlf' -and -not (Test-Path Env:GIT_CONFIG_KEY_1)) 'environment git config was not restored.'
        assert-true ($env:GIT_CONFIG_PARAMETERS -eq "'core.filemode=false'") 'git -c parameters were not restored.'
        assert-true (-not (Test-Path Env:GIT_CONFIG_GLOBAL) -and -not (Test-Path $temp_config)) 'the isolated git config was not removed.'
        assert-true (-not (Test-Path Env:GIT_TERMINAL_PROMPT)) 'prompt settings were not restored.'

        # Cleanup
        Remove-Item -Path Env:GIT_CONFIG_COUNT, Env:GIT_CONFIG_KEY_0, Env:GIT_CONFIG_VALUE_0, Env:GIT_CONFIG_PARAMETERS, Env:SYSTEM_ACCESSTOKEN
        $env:GIT_CONFIG_GLOBAL = $saved_global
    }

    # Tests that the pipeline git environment uses the caller's global git config, when there is one, and leaves it in place.
    # Steps:
    # 1. Select pipeline mode with SYSTEM_ACCESSTOKEN, and point GIT_CONFIG_GLOBAL at a caller config with a commit identity.
    # 2. Initialize the pipeline environment, record the global git config and identity that it uses, and remove it.
    # 3. Verify that the caller's global git config and identity were used, and that the config still exists.
    run-test 'pipeline environment keeps the caller global git config' {
        # Arrange
        # 1. Select pipeline mode with SYSTEM_ACCESSTOKEN, and point GIT_CONFIG_GLOBAL at a caller config with a commit identity.
        $script:propagation_mode = 'pipeline'
        $env:SYSTEM_ACCESSTOKEN = 'pipeline-system-secret-123456'
        $saved_global = $env:GIT_CONFIG_GLOBAL
        $caller_config = Join-Path $test_root 'caller.gitconfig'
        & git config --file $caller_config user.name 'caller identity'
        $env:GIT_CONFIG_GLOBAL = $caller_config

        # Act
        # 2. Initialize the pipeline environment, record the global git config and identity that it uses, and remove it.
        initialize-pipeline-environment
        try
        {
            $global_config = $env:GIT_CONFIG_GLOBAL
            $user_name = & git config --global --get user.name
        }
        finally
        {
            remove-pipeline-environment
        }

        # Assert
        # 3. Verify that the caller's global git config and identity were used, and that the config still exists.
        assert-true ($global_config -eq $caller_config) "the caller's global git config was replaced."
        assert-true ($user_name -eq 'caller identity') "the caller's identity was overwritten."
        assert-true (Test-Path $caller_config) "the caller's global git config was deleted."

        # Cleanup
        Remove-Item -Path Env:SYSTEM_ACCESSTOKEN
        $env:GIT_CONFIG_GLOBAL = $saved_global
    }

    # Tests that, when the caller's global git config already has a credential for an Azure DevOps host, pipeline git sends
    # that host a single Authorization header, with the pipeline token.
    # Steps:
    # 1. Start a local HTTP listener, and give the caller's global git config an extra header for it, like the EBS pipeline.
    # 2. Select pipeline mode with SYSTEM_ACCESSTOKEN, and treat the listener as an Azure DevOps host.
    # 3. Initialize the pipeline environment, and capture the request that git sends to the listener.
    # 4. Verify that the request has one Authorization header, with the pipeline token.
    run-test 'pipeline git sends one Azure DevOps credential when the caller configured one too' {
        # Arrange
        # 1. Start a local HTTP listener, and give the caller's global git config an extra header for it, like the EBS pipeline.
        $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $server = "http://127.0.0.1:$($listener.LocalEndpoint.Port)"
        $caller_config = Join-Path $test_root 'caller-credential.gitconfig'
        & git config --file $caller_config "http.$server.extraheader" 'AUTHORIZATION: bearer caller-token'
        $saved_global = $env:GIT_CONFIG_GLOBAL
        $env:GIT_CONFIG_GLOBAL = $caller_config

        # 2. Select pipeline mode with SYSTEM_ACCESSTOKEN, and treat the listener as an Azure DevOps host.
        $script:propagation_mode = 'pipeline'
        $env:SYSTEM_ACCESSTOKEN = 'pipeline-system-secret-123456'
        $saved_hosts = $script:ado_git_hosts
        $script:ado_git_hosts = @($server)

        # Act
        # 3. Initialize the pipeline environment, and capture the request that git sends to the listener.
        $request = ''
        try
        {
            initialize-pipeline-environment
            $request = get-git-http-request -listener $listener -url "$server/repo.git"
        }
        finally
        {
            remove-pipeline-environment
            $listener.Stop()
            $script:ado_git_hosts = $saved_hosts
            $env:GIT_CONFIG_GLOBAL = $saved_global
            Remove-Item -Path Env:SYSTEM_ACCESSTOKEN
        }

        # Assert
        # 4. Verify that the request has one Authorization header, with the pipeline token.
        $headers = @($request -split "`r`n" | Where-Object { $_ -match '^authorization:' })
        assert-true ($headers.Count -eq 1) "git sent $($headers.Count) Authorization headers: $($headers -join ' | ')"
        assert-true (($headers -join ' ') -match 'pipeline-system-secret-123456') "git did not send the pipeline token: $($headers -join ' | ')"
    }

    # Tests that each repo is updated after the repos it depends on.
    # Steps:
    # 1. Build a graph: root depends on left and right, right also depends on middle, and left, right, and middle depend
    #    on leaf.
    # 2. Get the update order.
    # 3. Verify that the order is leaf, middle, left, right, root.
    run-test 'update order puts dependencies first' {
        # Arrange
        # 1. Build a graph: root depends on left and right, right also depends on middle, and left, right, and middle depend
        #    on leaf.
        $edges = new-repo-edges ([ordered]@{ root = @('left', 'right'); left = @('leaf'); right = @('leaf', 'middle'); middle = @('leaf'); leaf = @() })

        # Act
        # 2. Get the update order.
        $order = get-repo-update-order -root_list @('https://example.com/org/root') -repo_edges $edges

        # Assert
        # 3. Verify that the order is leaf, middle, left, right, root.
        assert-true (($order -join ',') -eq 'leaf,middle,left,right,root') "unexpected order: $($order -join ',')"
    }

    # Tests that a dependency cycle is rejected.
    # Steps:
    # 1. Build a graph in which a and b depend on each other.
    # 2. Get the update order.
    # 3. Verify that the cycle was reported.
    run-test 'update order rejects dependency cycles' {
        # Arrange
        # 1. Build a graph in which a and b depend on each other.
        $edges = new-repo-edges ([ordered]@{ a = @('b'); b = @('a') })

        # Act
        # 2. Get the update order.
        $caught = $null
        try { [void](get-repo-update-order -root_list @('https://example.com/org/a') -repo_edges $edges) } catch { $caught = $_.Exception.Message }

        # Assert
        # 3. Verify that the cycle was reported.
        assert-true ($caught -match 'Dependency cycle') "a dependency cycle was not rejected: $caught"
    }

    # Tests that a repo waits until the repos it depends on are done.
    # Steps:
    # 1. Build a graph in which middle depends on leaf, and no repo is done.
    # 2. Get middle's unfinished dependencies, mark leaf done, and get them again.
    # 3. Verify that middle waited for leaf only until leaf was done.
    run-test 'a repo waits for its unfinished dependencies' {
        # Arrange
        # 1. Build a graph in which middle depends on leaf, and no repo is done.
        $edges = new-repo-edges ([ordered]@{ middle = @('leaf'); leaf = @() })
        $done = New-Object 'System.Collections.Generic.HashSet[string]'

        # Act
        # 2. Get middle's unfinished dependencies, mark leaf done, and get them again.
        $before = @(get-unfinished-dependencies -repo_name 'middle' -repo_edges $edges -done $done)
        [void]$done.Add('leaf')
        $after = @(get-unfinished-dependencies -repo_name 'middle' -repo_edges $edges -done $done)

        # Assert
        # 3. Verify that middle waited for leaf only until leaf was done.
        assert-true (($before -join ',') -eq 'leaf') "a repo must wait for its dependencies: $($before -join ',')"
        assert-true ($after.Count -eq 0) "a repo must start once its dependencies are done: $($after -join ',')"
    }

    # Tests that repository names, Azure DevOps organizations and projects, and PR ids are parsed from each URL form.
    # Steps:
    # 1. Parse each supported URL form.
    # 2. Verify each parsed value.
    run-test 'repository URLs are parsed consistently' {
        # Act
        # 1. Parse each supported URL form.
        $github_name = get-name-from-url 'https://github.com/Azure/c-build-tools.git'
        $ado_name = get-name-from-url 'https://msazure.visualstudio.com/One/_git/Azure-MessagingStore'
        $local_name = get-name-from-url 'C:\repos\child.git'
        $dev_azure = get-azure-org-project-from-url 'https://msazure@dev.azure.com/msazure/One/_git/zrpc'
        $visualstudio = get-azure-org-project-from-url 'https://msazure.visualstudio.com/DefaultCollection/One/_git/zrpc'
        $github = get-azure-org-project-from-url 'https://github.com/Azure/c-pal'
        $org_url = get-ado-org-base-url 'https://dev.azure.com/msazure/One/_apis/git'
        $pr_id = get-azure-pr-id-from-url 'https://dev.azure.com/msazure/One/_git/zrpc/pullrequest/123'

        # Assert
        # 2. Verify each parsed value.
        assert-true ($github_name -eq 'c-build-tools') 'GitHub URL'
        assert-true ($ado_name -eq 'Azure-MessagingStore') 'Azure DevOps URL'
        assert-true ($local_name -eq 'child') 'local path'
        assert-true ($dev_azure.Organization -eq 'https://dev.azure.com/msazure' -and $dev_azure.Project -eq 'One') 'dev.azure.com URL'
        assert-true ($visualstudio.Organization -eq 'https://dev.azure.com/msazure' -and $visualstudio.Project -eq 'One') 'visualstudio.com URL'
        assert-true ($null -eq $github) 'a GitHub URL is not an Azure DevOps repo'
        assert-true ($org_url -eq 'https://dev.azure.com/msazure') 'organization URL'
        assert-true ($pr_id -eq 123) 'PR id'
    }

    # Tests that, in each mode, the final status reports success only when every repo was updated or skipped.
    # Steps:
    # 1. Select the mode, and track repo a as updated and repo b as in progress.
    # 2. Show the final status, mark b skipped, and show the final status again.
    # 3. Verify that only the second status reported success.
    foreach ($mode in @('pipeline', 'interactive'))
    {
        run-test "status table reports success only when every repo finished ($mode)" {
            # Arrange
            # 1. Select the mode, and track repo a as updated and repo b as in progress.
            $script:propagation_mode = $mode
            initialize-repo-status -repos @('a', 'b')
            set-repo-status -repo_name 'a' -status $script:STATUS_UPDATED
            set-repo-status -repo_name 'b' -status $script:STATUS_IN_PROGRESS
            set-repo-details -repo_name 'b' -details 'waiting on reviewers'

            # Act
            # 2. Show the final status, mark b skipped, and show the final status again.
            $unfinished = show-propagation-status -Final 6>$null
            set-repo-status -repo_name 'b' -status $script:STATUS_SKIPPED
            $finished = show-propagation-status -Final 6>$null

            # Assert
            # 3. Verify that only the second status reported success.
            assert-true (-not $unfinished) 'success was reported while a repo was in progress.'
            assert-true ([bool]$finished) 'success was not reported once every repo was updated or skipped.'
        }
    }

    # Tests that pipeline logs show ASCII status symbols, and the interactive status shows a check mark.
    # Steps:
    # 1. Get the symbol for an updated repo in pipeline mode, then in interactive mode.
    # 2. Verify that pipeline mode used '+' and interactive mode used a check mark.
    run-test 'status symbols follow the mode' {
        # Act
        # 1. Get the symbol for an updated repo in pipeline mode, then in interactive mode.
        $script:propagation_mode = 'pipeline'
        $pipeline_symbol = (get-repo-status-display -status 'updated').Symbol
        $script:propagation_mode = 'interactive'
        $interactive_symbol = (get-repo-status-display -status 'updated').Symbol

        # Assert
        # 2. Verify that pipeline mode used '+' and interactive mode used a check mark.
        assert-true ($pipeline_symbol -eq '+') 'pipeline logs use ASCII status symbols.'
        assert-true ($interactive_symbol -eq [char]0x2713) 'interactive status uses a check mark.'
    }

    # Tests that the gate summary counts the running gates and names the gates awaiting action.
    # Steps:
    # 1. Summarize a running gate, a gate awaiting action, and a done gate.
    # 2. Verify that the summary counts one running gate and names the gate awaiting action.
    run-test 'gate summary counts running gates and names the gates awaiting action' {
        # Act
        # 1. Summarize a running gate, a gate awaiting action, and a done gate.
        $summary = format-gate-summary -gates @(@{ Name = 'build'; State = 'running' }, @{ Name = 'approval'; State = 'awaiting-action' }, @{ Name = 'lint'; State = 'done' })

        # Assert
        # 2. Verify that the summary counts one running gate and names the gate awaiting action.
        assert-true ($summary -match '1 running' -and $summary -match 'awaiting action \[approval\]') "gate summary: $summary"
    }

    # Tests that pipeline PR titles carry the [no begging] tag, and interactive PR titles do not.
    # Steps:
    # 1. Describe one c-pal change.
    # 2. Build the PR description in pipeline mode, then in interactive mode.
    # 3. Verify each mode's PR title.
    run-test 'PR titles follow the mode' {
        # Arrange
        # 1. Describe one c-pal change.
        initialize-repo-status -repos @('c-pal')
        $changes = @(@{ Repo = 'c-pal'; SHA = 'abc1234'; Subject = 'Fix the thing' })

        # Act
        # 2. Build the PR description in pipeline mode, then in interactive mode.
        $script:propagation_mode = 'pipeline'
        $pipeline_description = build-propagation-description $changes
        $script:propagation_mode = 'interactive'
        $interactive_description = build-propagation-description $changes

        # Assert
        # 3. Verify each mode's PR title.
        assert-true ($pipeline_description.PrTitle -eq '[no begging] [autogenerated] update deps: c-pal') "pipeline title: $($pipeline_description.PrTitle)"
        assert-true ($interactive_description.PrTitle -eq '[autogenerated] update deps: c-pal') "interactive title: $($interactive_description.PrTitle)"
    }

    # Tests that a PR body keeps the detail of each commit when it fits the Azure DevOps limit.
    # Steps:
    # 1. Build the PR description for one c-pal change.
    # 2. Select the PR body for the Azure DevOps limit.
    # 3. Verify that the body lists the commit.
    run-test 'PR body keeps detail when it fits' {
        # Arrange
        # 1. Build the PR description for one c-pal change.
        $script:propagation_mode = 'interactive'
        initialize-repo-status -repos @('c-pal')
        $description = build-propagation-description @(@{ Repo = 'c-pal'; SHA = 'abc1234'; Subject = 'Fix the thing' })

        # Act
        # 2. Select the PR body for the Azure DevOps limit.
        $body = select-pr-body -description $description -max_length 3999

        # Assert
        # 3. Verify that the body lists the commit.
        assert-true ($body -match 'abc1234') 'the detailed body was not used.'
    }

    # Tests that a PR body falls back to the summary when the detail is too long, and is truncated when even the summary
    # is too long.
    # Steps:
    # 1. Build the PR description for 200 changes, whose detail is longer than the Azure DevOps limit.
    # 2. Select the PR body for the Azure DevOps limit, and for a 50-character limit.
    # 3. Verify that the summary was used for the Azure DevOps limit, and that the body was truncated to 50 characters.
    run-test 'PR body falls back to the summary, then truncates, when the detail is too long' {
        # Arrange
        # 1. Build the PR description for 200 changes, whose detail is longer than the Azure DevOps limit.
        $script:propagation_mode = 'interactive'
        initialize-repo-status -repos @('c-pal')
        $many = @(1..200 | ForEach-Object { @{ Repo = "repo$($_ % 3)"; SHA = ('{0:x7}' -f $_); Subject = ('subject ' * 5) + $_ } })
        $description = build-propagation-description $many
        if ($description.PrBody.Length -le 3999) { throw 'the test needs a detailed body over the limit.' }

        # Act
        # 2. Select the PR body for the Azure DevOps limit, and for a 50-character limit.
        $body = select-pr-body -description $description -max_length 3999
        $truncated = select-pr-body -description $description -max_length 50

        # Assert
        # 3. Verify that the summary was used for the Azure DevOps limit, and that the body was truncated to 50 characters.
        assert-true ($body -eq $description.PrSummaryBody) 'the summary body was not used when the detailed body is too long.'
        assert-true ($truncated.Length -le 50 -and $truncated.EndsWith('... (truncated)')) "truncation exceeded the limit: $($truncated.Length)"
    }

    # Tests that a GitHub PR with a running check stays pending, and that its status details count the running check.
    # Steps:
    # 1. Mock gh to report an open PR with one running check.
    # 2. Poll the PR.
    # 3. Verify that the PR is pending, and that its details report one running check.
    run-test 'GitHub PR with a running check stays pending' {
        # Arrange
        # 1. Mock gh to report an open PR with one running check.
        $script:propagation_mode = 'pipeline'
        initialize-repo-status -repos @('c-pal')
        $pr = @{ Repo = 'c-pal'; Type = 'github'; PrUrl = 'https://github.com/Azure/c-pal/pull/1' }
        . $mock_gh_pr
        $script:gh_checks = '[{"name":"Gate","state":"IN_PROGRESS","bucket":"pending"}]'

        # Act
        # 2. Poll the PR.
        $state = poll-github-pr-state $pr

        # Assert
        # 3. Verify that the PR is pending, and that its details report one running check.
        assert-true ($state -eq 'pending') 'a running check must keep the PR pending.'
        assert-true ($global:repo_status['c-pal'].Details -match '1 running') "details: $($global:repo_status['c-pal'].Details)"
    }

    # Tests that a GitHub PR with a failed check fails, even when its other checks passed.
    # Steps:
    # 1. Mock gh to report an open PR with a failed check and a passed check.
    # 2. Poll the PR.
    # 3. Verify that the PR failed.
    run-test 'GitHub PR with a failed check fails' {
        # Arrange
        # 1. Mock gh to report an open PR with a failed check and a passed check.
        $script:propagation_mode = 'pipeline'
        initialize-repo-status -repos @('c-pal')
        $pr = @{ Repo = 'c-pal'; Type = 'github'; PrUrl = 'https://github.com/Azure/c-pal/pull/1' }
        . $mock_gh_pr
        $script:gh_checks = '[{"name":"Gate","state":"FAILURE","bucket":"fail"},{"name":"license/cla","state":"SUCCESS","bucket":"pass"}]'

        # Act
        # 2. Poll the PR.
        $state = poll-github-pr-state $pr

        # Assert
        # 3. Verify that the PR failed.
        assert-true ($state -eq 'failed') 'a failed check must fail the PR.'
    }

    # Tests that an open GitHub PR whose checks all passed stays pending, and is asked to merge in case auto-merge did not
    # engage.
    # Steps:
    # 1. Mock gh to report an open PR whose only check passed.
    # 2. Poll the PR.
    # 3. Verify that the PR is pending, and that one merge was requested.
    run-test 'GitHub PR whose checks passed is nudged to merge' {
        # Arrange
        # 1. Mock gh to report an open PR whose only check passed.
        $script:propagation_mode = 'pipeline'
        initialize-repo-status -repos @('c-pal')
        $pr = @{ Repo = 'c-pal'; Type = 'github'; PrUrl = 'https://github.com/Azure/c-pal/pull/1' }
        . $mock_gh_pr
        $script:gh_checks = '[{"name":"Gate","state":"SUCCESS","bucket":"pass"}]'

        # Act
        # 2. Poll the PR.
        $state = poll-github-pr-state $pr

        # Assert
        # 3. Verify that the PR is pending, and that one merge was requested.
        assert-true ($state -eq 'pending') 'an unmerged PR stays pending.'
        assert-true (@($script:gh_calls | Where-Object { $_ -like 'pr merge*' }).Count -eq 1) 'a PR whose checks passed was not nudged to merge.'
    }

    # Tests that a merged GitHub PR is detected.
    # Steps:
    # 1. Mock gh to report a merged PR whose only check passed.
    # 2. Poll the PR.
    # 3. Verify that the PR is merged.
    run-test 'merged GitHub PR is detected' {
        # Arrange
        # 1. Mock gh to report a merged PR whose only check passed.
        $script:propagation_mode = 'pipeline'
        initialize-repo-status -repos @('c-pal')
        $pr = @{ Repo = 'c-pal'; Type = 'github'; PrUrl = 'https://github.com/Azure/c-pal/pull/1' }
        . $mock_gh_pr
        $script:gh_state = 'MERGED'
        $script:gh_checks = '[{"name":"Gate","state":"SUCCESS","bucket":"pass"}]'

        # Act
        # 2. Poll the PR.
        $state = poll-github-pr-state $pr

        # Assert
        # 3. Verify that the PR is merged.
        assert-true ($state -eq 'merged') 'a merged PR was not detected.'
    }

    # Tests that linking the work item to a PR that it already links does not add the link again.
    # Steps:
    # 1. Mock Azure DevOps with work item 4242 linked to PR 7.
    # 2. Link work item 4242 to PR 7.
    # 3. Verify that the work item was not updated.
    run-test 'an existing work item link is not added again' {
        # Arrange
        # 1. Mock Azure DevOps with work item 4242 linked to PR 7.
        $azure_work_item = 4242
        . $mock_ado_work_items

        # Act
        # 2. Link work item 4242 to PR 7.
        link-work-item-to-pr-azure 7 'https://dev.azure.com/org' 6>$null

        # Assert
        # 3. Verify that the work item was not updated.
        assert-true (@($script:ado_calls | Where-Object { $_ -like 'PATCH*' }).Count -eq 0) 'an existing work item link was added again.'
    }

    # Tests that linking the work item to a PR that it does not link yet adds the link.
    # Steps:
    # 1. Mock Azure DevOps with work item 4242 not linked to PR 7.
    # 2. Link work item 4242 to PR 7.
    # 3. Verify that the work item was updated once.
    run-test 'a missing work item link is added' {
        # Arrange
        # 1. Mock Azure DevOps with work item 4242 not linked to PR 7.
        $azure_work_item = 4242
        . $mock_ado_work_items
        $script:linked = $false

        # Act
        # 2. Link work item 4242 to PR 7.
        link-work-item-to-pr-azure 7 'https://dev.azure.com/org' 6>$null

        # Assert
        # 3. Verify that the work item was updated once.
        assert-true (@($script:ado_calls | Where-Object { $_ -like 'PATCH*/_apis/wit/workitems/4242*' }).Count -eq 1) 'a missing work item link was not added.'
    }

    # Tests that, when creating a PR fails because an active PR already exists for the branch, the active PR is used.
    # Steps:
    # 1. Mock Azure DevOps so that creating the PR fails, because PR 7 is already active for the branch.
    # 2. Create the PR.
    # 3. Verify that PR 7 was returned.
    run-test 'PR creation reuses the active PR when one already exists' {
        # Arrange
        # 1. Mock Azure DevOps so that creating the PR fails, because PR 7 is already active for the branch.
        . $mock_ado_work_items
        function get-azure-org-project { param([string] $repo_name) return @{ Organization = 'https://dev.azure.com/org'; Project = 'proj' } }
        function find-active-azure-pr { param([string] $repo_name, [string] $branch_name) return 'https://dev.azure.com/org/proj/_git/repo/pullrequest/7' }

        # Act
        # 2. Create the PR.
        $created = create-pr-azure 'repo' 'new_deps_1' (build-propagation-description @()) 6>$null

        # Assert
        # 3. Verify that PR 7 was returned.
        assert-true ($created.pullRequestId -eq 7) 'the active PR was not reused after the create call failed.'
    }

    # Tests that the Azure PR watcher reads policy evaluations through REST: it links the PR, reports a rejected build as a
    # failed check, and names and classifies each policy.
    # Steps:
    # 1. Mock PR 5 with a rejected blocking build policy and an approved reviewer policy.
    # 2. Read the PR's policy display data, and evaluate whether its checks are complete.
    # 3. Name and classify each policy.
    # 4. Verify the PR link and the checks, and that the checks completed with the build failed.
    # 5. Verify that the build policy is named after its build and failed, and that the reviewer policy is done.
    run-test 'Azure policy watcher reads REST evaluations' {
        # Arrange
        # 1. Mock PR 5 with a rejected blocking build policy and an approved reviewer policy.
        $script:evaluations = @(
            [pscustomobject]@{ status = 'rejected'; context = [pscustomobject]@{ buildId = 99 }; configuration = [pscustomobject]@{ isBlocking = $true; type = [pscustomobject]@{ id = '0609b952-1397-4640-95ec-e00a01b2c241'; displayName = 'Build' }; settings = [pscustomobject]@{ displayName = 'PR-Gate' } } },
            [pscustomobject]@{ status = 'approved'; context = $null; configuration = [pscustomobject]@{ isBlocking = $true; type = [pscustomobject]@{ id = 'fa4e907d-c16b-4a4c-9dfa-4906e5d171dd'; displayName = 'Minimum number of reviewers' }; settings = [pscustomobject]@{} } }
        )
        function get-ado-pull-request { param([string] $org_url, [int] $pr_id) return [pscustomobject]@{ pullRequestId = $pr_id; repository = [pscustomobject]@{ name = 'zrpc'; project = [pscustomobject]@{ id = 'project-id'; name = 'One' } } } }
        function get-azure-pr-policy-evaluations { param([string] $org, [object] $pr) return $script:evaluations }

        # Act
        # 2. Read the PR's policy display data, and evaluate whether its checks are complete.
        $data = get-policy-display-data -pr_id 5 -org 'https://dev.azure.com/msazure'
        $completion = Test-ChecksComplete -checks $data.Checks

        # 3. Name and classify each policy.
        $build_name = get-azure-policy-name $script:evaluations[0]
        $build_state = get-azure-policy-gate-state $script:evaluations[0]
        $reviewer_state = get-azure-policy-gate-state $script:evaluations[1]

        # Assert
        # 4. Verify the PR link and the checks, and that the checks completed with the build failed.
        assert-true ($data.PrUrl -eq 'https://dev.azure.com/msazure/One/_git/zrpc/pullrequest/5') "PR URL: $($data.PrUrl)"
        assert-true (@($data.Checks).Count -eq 2) "checks: $(@($data.Checks).Count)"
        assert-true ($completion.Complete -and -not $completion.Success -and $completion.Message -eq 'Failed: Build') "completion: $($completion.Message)"

        # 5. Verify that the build policy is named after its build and failed, and that the reviewer policy is done.
        assert-true ($build_name -eq 'PR-Gate') 'pipeline gate names use the build name.'
        assert-true ($build_state -eq 'failed') 'a rejected build is a failed gate.'
        assert-true ($reviewer_state -eq 'done') 'an approved policy is a done gate.'
    }

    # Tests that, when closing the failed PR fails too, the run still fails once with the original failure, instead of
    # closing the PR again in a loop.
    # Steps:
    # 1. Write a pipeline-mode script that fails, and whose failed PR fails to close.
    # 2. Run the script.
    # 3. Verify that the run failed, closed the PR once, and reported the original failure.
    run-test 'a failure while reporting a failure does not recurse' {
        # Arrange
        # 1. Write a pipeline-mode script that fails, and whose failed PR fails to close.
        $child_script = Join-Path $test_root 'nested_failure.ps1'
        Set-Content -Path $child_script -Encoding ascii -Value @(
            "`$ErrorActionPreference = 'Continue'",
            ". '$(Join-Path $helper_root 'load_helpers.ps1')'",
            "`$script:propagation_mode = 'pipeline'",
            "initialize-repo-status -repos @('repo')",
            "`$global:current_repo = 'repo'",
            "`$global:repo_status['repo'].PrUrl = 'https://dev.azure.com/org/project/_git/repo/pullrequest/1'",
            "`$global:close_failed_pr = `$true",
            "`$global:work_dir = (Get-Location).Path",
            "`$global:original_dir = (Get-Location).Path",
            "function get-repo-type { param([string] `$repo_name) return 'azure' }",
            "function close-pr-azure { param([string] `$pr_url, [string] `$repo_name) Write-Host 'closing the failed PR'; fail-with-status 'nested failure' }",
            "fail-with-status 'outer failure'"
        )

        # Act
        # 2. Run the script.
        $result = invoke-entry-script -command "& '$child_script'; exit `$LASTEXITCODE"

        # Assert
        # 3. Verify that the run failed, closed the PR once, and reported the original failure.
        $closes = [regex]::Matches($result.Output, 'closing the failed PR').Count
        assert-true ($result.ExitCode -ne 0) 'fail-with-status must end the run with a failure.'
        assert-true ($closes -eq 1) "the failed PR was closed $closes times: $($result.Output)"
        assert-true ($result.Output -match 'outer failure') "the original failure was not reported: $($result.Output)"
    }

    # Tests that, when the user cancels watching an Azure PR, the cancellation is recorded and the PR is not watched again.
    # Steps:
    # 1. Mock an active PR whose policy watch fails, and have the user cancel the wait that follows.
    # 2. Wait for the PR to complete.
    # 3. Verify that the cancellation was recorded, and that the PR was watched once.
    run-test 'cancelling an Azure PR watch stops watching' {
        # Arrange
        # 1. Mock an active PR whose policy watch fails, and have the user cancel the wait that follows.
        $script:watch_calls = 0
        function watch-azure-pr-policies
        {
            $script:watch_calls++
            if ($script:watch_calls -gt 1) { throw 'the PR was watched again after the user cancelled.' }
            return $false
        }
        function get-pr-status-with-retry { param([int] $pr_id, [string] $org) return [pscustomobject]@{ status = 'active' } }
        function wait-or-cancel { param([int] $seconds) return $true }
        $global:propagation_cancelled = $false

        # Act
        # 2. Wait for the PR to complete.
        try
        {
            wait-until-complete-azure -pr_id 5 -org 'https://dev.azure.com/org' -repo_name 'repo' -pr_url 'https://dev.azure.com/org/project/_git/repo/pullrequest/5'
            $cancelled = $global:propagation_cancelled
        }
        finally
        {
            $global:propagation_cancelled = $false
        }

        # Assert
        # 3. Verify that the cancellation was recorded, and that the PR was watched once.
        assert-true $cancelled 'the cancellation was not recorded.'
        assert-true ($script:watch_calls -eq 1) "the PR was watched $($script:watch_calls) times."
    }

    # Tests that the entry script never pipes propagate-updates. Piping the run (e.g. to Out-Host) would redirect native
    # stdout, so 'gh auth login' could not prompt.
    # Steps:
    # 1. Find the calls to propagate-updates in propagate_updates.ps1.
    # 2. Verify that there is a call, and that no call is piped.
    run-test 'interactive sign-in keeps the console' {
        # Act
        # 1. Find the calls to propagate-updates in propagate_updates.ps1.
        $ast = get-script-ast $entry_script
        $calls = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'propagate-updates' }, $true))

        # Assert
        # 2. Verify that there is a call, and that no call is piped.
        $piped_lines = @($calls | Where-Object { $_.Parent.PipelineElements.Count -ne 1 } | ForEach-Object { $_.Extent.StartLineNumber })
        assert-true ($calls.Count -gt 0) 'propagate_updates.ps1 does not call propagate-updates.'
        assert-true ($piped_lines.Count -eq 0) "propagate-updates is piped at line $($piped_lines -join ', ')."
    }

    # Tests that, in each mode, update-local-repo moves the submodule to the propagated commit, and commits and pushes only
    # that change, with a message that keeps the commit subject and a PR description for the mode.
    # Steps:
    # 1. Select the mode and its PR title prefix.
    # 2. Create a child repository, and a parent repository that has it as the deps/child submodule.
    # 3. Add a child commit whose subject has quotes.
    # 4. Record that the child was updated in PR 1, to that commit.
    # 5. Clone the parent into the work directory, and add an unrelated file to the clone.
    # 6. Update the parent.
    # 7. Verify that the update returned only its result, and pushed a commit that moves only deps/child to the child commit
    #    and keeps the quoted subject.
    # 8. Verify that the child was fetched through the mirror cache, and that the PR description has the mode's title and
    #    links the child PR.
    foreach ($mode in @('pipeline', 'interactive'))
    {
        run-test "update-local-repo commits only submodule changes ($mode)" {
            # Arrange
            # 1. Select the mode and its PR title prefix.
            $script:propagation_mode = $mode
            $expected_prefix = if ($mode -eq 'pipeline') { '[no begging] [autogenerated]' } else { '[autogenerated]' }

            # 2. Create a child repository, and a parent repository that has it as the deps/child submodule.
            $root = Join-Path $test_root "r-$mode"
            New-Item -ItemType Directory -Path $root | Out-Null
            $child_src = Join-Path $root 'child_src'
            $child_bare = Join-Path $root 'child.git'
            $parent_src = Join-Path $root 'parent_src'
            $parent_bare = Join-Path $root 'parent.git'
            invoke-git @('init', '-q', $child_src) | Out-Null
            commit-with-message $child_src 'child initial'
            invoke-git @('clone', '-q', '--bare', $child_src, $child_bare) | Out-Null
            invoke-git @('init', '-q', $parent_src) | Out-Null
            invoke-git @('-C', $parent_src, 'submodule', 'add', '-q', $child_bare, 'deps/child') | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $parent_src 'build') | Out-Null
            Set-Content -Path (Join-Path $parent_src 'build\pipeline.yml') -Value 'steps: []'
            invoke-git @('-C', $parent_src, 'add', '-A') | Out-Null
            commit-with-message $parent_src 'parent initial'
            invoke-git @('clone', '-q', '--bare', $parent_src, $parent_bare) | Out-Null

            # 3. Add a child commit whose subject has quotes.
            commit-with-message $child_src 'Revert "Fix the thing" (#12)'
            $child_head = "$(invoke-git @('-C', $child_src, 'rev-parse', 'HEAD'))".Trim()
            invoke-git @('-C', $child_src, 'push', '-q', $child_bare, 'master') | Out-Null

            # 4. Record that the child was updated in PR 1, to that commit.
            $work = Join-Path $root 'work'
            New-Item -ItemType Directory -Path $work | Out-Null
            Set-Location $work
            $global:work_dir = $work
            $global:git_mirror_index = @{}
            $global:fixed_commits = @{ child = $child_head }
            $global:repo_change_descriptions = @{}
            initialize-repo-status -repos @('child', 'parent')
            set-repo-status -repo_name 'child' -status $script:STATUS_UPDATED -pr_url 'https://example.com/child/pull/1'

            # 5. Clone the parent into the work directory, and add an unrelated file to the clone.
            clone-repo-with-retry -repo_url $parent_bare -target_dir 'parent'
            Set-Content -Path (Join-Path $work 'parent\stray.txt') -Value 'not part of the update'

            # Act
            # 6. Update the parent.
            $result = update-local-repo 'parent' 'new_deps_test'

            # Assert
            # 7. Verify that the update returned only its result, and pushed a commit that moves only deps/child to the child commit
            #    and keeps the quoted subject.
            assert-true ($result -is [hashtable]) "update-local-repo returned extra output: $(@($result).Count) objects."
            assert-true ($result.HasChanges) 'the update did not report its commit.'
            $tree = "$(invoke-git @('--git-dir', $parent_bare, 'ls-tree', 'new_deps_test', 'deps/child'))"
            assert-true ($tree -match $child_head) "the push did not move deps/child to the child commit: $tree"
            $message = (invoke-git @('--git-dir', $parent_bare, 'log', '-1', '--format=%B', 'new_deps_test')) -join "`n"
            assert-true ($message.Contains('Revert "Fix the thing"')) "the commit message lost the quoted subject: $message"
            $files = @(invoke-git @('--git-dir', $parent_bare, 'show', '--name-only', '--format=', 'new_deps_test') | Where-Object { $_ })
            assert-true (($files -join ',') -eq 'deps/child') "the commit contains unexpected files: $($files -join ',')"

            # 8. Verify that the child was fetched through the mirror cache, and that the PR description has the mode's title and
            #    links the child PR.
            assert-true (Test-Path (Join-Path $work '_gitmirrors\child.git')) 'the update did not use the mirror cache.'
            assert-true ($result.Description.PrTitle.StartsWith($expected_prefix)) "PR title: $($result.Description.PrTitle)"
            assert-true ($result.Description.PrBody -match 'https://example.com/child/pull/1') 'the PR body lacks the related PR link.'
        }
    }
}
finally
{
    Set-Location $saved_location
    foreach ($variable in @(Get-ChildItem Env: | Where-Object { $_.Name -match '^(GIT_|GH_|GCM_|SYSTEM_ACCESSTOKEN$|AZURE_DEVOPS_EXT_PAT$|ghToken$)' }))
    {
        Remove-Item -Path "Env:$($variable.Name)"
    }
    foreach ($name in $saved_env.Keys)
    {
        Set-Item -Path "Env:$name" -Value $saved_env[$name]
    }
    Remove-Item -Path $test_root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0)
{
    foreach ($failure in $failures)
    {
        Write-Host "FAILED: $failure" -ForegroundColor Red
    }
    exit 1
}
else
{
    Write-Host 'All propagate_updates tests passed.' -ForegroundColor Green
    exit 0
}
