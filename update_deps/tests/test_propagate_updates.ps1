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

try
{
    run-test 'scripts parse' {
        foreach ($file in Get-ChildItem -Path $update_deps_root -Recurse -File -Filter *.ps1)
        {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            foreach ($parse_error in @($errors))
            {
                assert-true $false "$($file.Name):$($parse_error.Extent.StartLineNumber) $($parse_error.Message)"
            }
        }
    }

    run-test 'both modes share one helper set' {
        assert-true (-not (Test-Path (Join-Path $update_deps_root 'pipeline_helper_scripts'))) 'pipeline_helper_scripts must not exist; both modes share helper_scripts.'
        assert-true (-not (Test-Path (Join-Path $update_deps_root 'propagate_updates_pipeline.ps1'))) 'propagate_updates.ps1 must be the only entry point.'

        foreach ($file in Get-ChildItem -Path $helper_root -Filter *.ps1)
        {
            assert-true (-not (get-script-ast $file.FullName).ParamBlock) "$($file.Name) declares script parameters; dot-sourcing it would overwrite the entry script's parameters."
        }

        $definitions = @{}
        foreach ($file in $production_files)
        {
            foreach ($function_ast in (get-script-ast $file.FullName).FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
            {
                $name = ($function_ast.Name -replace '^(global|script):', '').ToLowerInvariant()
                if ($definitions.ContainsKey($name))
                {
                    assert-true $false "$name is defined in both $($definitions[$name]) and $($file.Name)."
                }
                else
                {
                    $definitions[$name] = $file.Name
                }
            }
        }
    }

    run-test 'command references resolve' {
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
        foreach ($call in $calls)
        {
            $name = $call.Ast.GetCommandName()
            if (-not $name) { continue }
            $location = "$($call.File):$($call.Ast.Extent.StartLineNumber)"
            $key = $name.ToLowerInvariant()
            if ($functions.ContainsKey($key))
            {
                foreach ($element in @($call.Ast.CommandElements | Select-Object -Skip 1))
                {
                    if ($element -is [System.Management.Automation.Language.CommandParameterAst])
                    {
                        $parameter = $element.ParameterName
                        $known = ($common -contains $parameter) -or (@($functions[$key] | Where-Object { $_ -like "$parameter*" }).Count -gt 0)
                        assert-true $known "$location calls $name with unknown parameter -$parameter."
                    }
                    else
                    {
                        # positional argument
                    }
                }
            }
            else
            {
                $resolved = ($external -contains $name) -or [bool](Get-Command -Name $name -CommandType Cmdlet, Alias, Function -ErrorAction SilentlyContinue)
                assert-true $resolved "$location calls unknown command $name."
            }
        }
    }

    run-test 'network commands go through the shared primitives' {
        foreach ($file in $production_files)
        {
            $lines = @(Get-Content -Path $file.FullName)
            for ($i = 0; $i -lt $lines.Count; $i++)
            {
                $line = $lines[$i]
                if ($line -match '^\s*#') { continue }
                $location = "$($file.Name):$($i + 1)"
                assert-true ($line -notmatch '\baz\s+(repos|devops|pipelines)\b') "$location calls the Azure DevOps CLI; use invoke-ado-rest."
                assert-true ($line -notmatch '^\s*(\$\w+\s*=\s*)?\(?git\s+(clone|fetch|pull|push|submodule\s+update)\b') "$location runs a network git command directly; use invoke-git-command."
                assert-true ($line -notmatch '^\s*git\s+add\s+\.\s*$') "$location stages the whole repository."
            }
        }
    }

    run-test 'pipeline mode rejects interactive-only parameters' {
        $result = invoke-entry-script -arguments @('-Pipeline', '-Resume')
        assert-true ($result.ExitCode -ne 0) '-Pipeline -Resume must fail.'
        assert-true ($result.Output -match 'does not support: -Resume') "unexpected output: $($result.Output)"
    }

    run-test 'missing arguments fail before any setup' {
        foreach ($mode in @('interactive', 'pipeline'))
        {
            $arguments = @('-root_list', 'https://dev.azure.com/org/project/_git/repo')
            if ($mode -eq 'pipeline') { $arguments = @('-Pipeline') + $arguments }
            $result = invoke-entry-script -arguments $arguments
            assert-true ($result.ExitCode -ne 0) "$mode run without -azure_work_item must fail."
            assert-true ($result.Output -match 'azure_work_item is required') "$mode output: $($result.Output)"
            assert-true ($result.Output -notmatch 'Checking PowerShell environment') "$mode run started tool setup before validating its arguments."
            assert-true ($result.WorkDirs.Count -eq 0) "$mode run created a work directory."
        }
    }

    run-test 'pipeline mode checks credentials first and keeps its parameters' {
        $command = "`$ErrorActionPreference = 'Stop'; & '$entry_script' -Pipeline -azure_work_item 42 -poll_interval 7 -NoCloseFailedPr -root_list 'https://dev.azure.com/org/project/_git/repo'; exit `$LASTEXITCODE"
        $result = invoke-entry-script -command $command
        assert-true ($result.ExitCode -eq 1) "expected the preflight exit code 1, got $($result.ExitCode): $($result.Output)"
        assert-true ($result.Output -match 'poll interval: 7s') '-poll_interval was not preserved after loading the helpers.'
        assert-true ($result.Output -match 'close failed PR: False') '-NoCloseFailedPr was not honored.'
        assert-true ($result.Output -match 'SYSTEM_ACCESSTOKEN is not set') 'a missing SYSTEM_ACCESSTOKEN was not reported.'
        assert-true ($result.Output -match 'GH_TOKEN is not set') 'a missing GH_TOKEN was not reported.'
        assert-true ($result.WorkDirs.Count -eq 0) 'a work directory was created before the preflight passed.'
    }

    run-test 'log format follows the mode' {
        $script:propagation_mode = 'pipeline'
        $pipeline_output = (& { Write-Log WARN 'pipeline message' } 6>&1 | Out-String).Trim()
        $script:propagation_mode = 'interactive'
        $interactive_output = (& { Write-Log WARN 'interactive message' } 6>&1 | Out-String).Trim()
        assert-true ($pipeline_output -match '^##\[warning\]\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] \[WARN\] pipeline message$') "pipeline log line: $pipeline_output"
        assert-true ($interactive_output -eq 'interactive message') "interactive log line: $interactive_output"
    }

    run-test 'secrets are redacted' {
        add-redaction-value 'pat-secret-value-123'
        $text = Protect-Secret 'pat=pat-secret-value-123 token=ghp_abcdefghijklmnopqrstuvwxyz123456 Authorization: Bearer abc.def Authorization: Basic Zm9vOmJhcg=='
        assert-true ($text -notmatch 'pat-secret-value-123') "a registered secret leaked: $text"
        assert-true ($text -notmatch 'ghp_abcdefghijklmnopqrstuvwxyz') "a GitHub token leaked: $text"
        assert-true ($text -notmatch 'abc\.def' -and $text -notmatch 'Zm9vOmJhcg') "an authorization header leaked: $text"
    }

    run-test 'native commands are time-bounded' {
        $ok = Invoke-NativeWithTimeout -File $powershell_exe -Arguments @('-NoProfile', '-Command', "[Console]::Out.Write('bounded-ok')")
        assert-true ($ok.ExitCode -eq 0 -and $ok.StdOut -eq 'bounded-ok') "stdout was not preserved: $($ok.StdOut) $($ok.StdErr)"
        $slow = Invoke-NativeWithTimeout -File $powershell_exe -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -TimeoutSec 2
        assert-true ($slow.TimedOut -and $slow.ExitCode -eq -1) 'a hung command was not stopped.'
        $retry = Invoke-NativeWithRetry -File $powershell_exe -Arguments @('-NoProfile', '-Command', 'exit 3') -MaxAttempts 2 -RetryDelaySec 0
        assert-true ($retry.ExitCode -eq 3) "the last attempt's exit code was not returned: $($retry.ExitCode)"
    }

    run-test 'git commands return only their exit code' {
        foreach ($mode in @('pipeline', 'interactive'))
        {
            $script:propagation_mode = $mode
            $ok = invoke-git-command -git_args @('--version')
            $bad = invoke-git-command -git_args @('no-such-command')
            assert-true ($ok -is [int] -and $ok -eq 0) "$mode git --version returned '$ok'."
            assert-true ($bad -is [int] -and $bad -ne 0) "$mode failing git command returned '$bad'."
        }
    }

    run-test 'Azure DevOps credentials follow the mode' {
        $env:SYSTEM_ACCESSTOKEN = 'system-token-value'
        $script:propagation_mode = 'pipeline'
        assert-true ((get-ado-authorization-header -org_url 'https://dev.azure.com/org') -eq 'Bearer system-token-value') 'pipeline mode must use SYSTEM_ACCESSTOKEN.'
        Remove-Item -Path Env:SYSTEM_ACCESSTOKEN

        $script:propagation_mode = 'interactive'
        $script:ado_pat = 'personal-access-token'
        $expected = 'Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(':personal-access-token'))
        assert-true ((get-ado-authorization-header -org_url 'https://dev.azure.com/org') -eq $expected) 'a PAT must use Basic authentication.'
        assert-true (-not (reset-ado-access-token -org_url 'https://dev.azure.com/org')) 'a PAT cannot be refreshed.'
        $script:ado_pat = $null

        $script:az_calls = @()
        $script:ado_token_cache = @{}
        function get-ado-tenant-id { param([string] $org_url) return '72f988bf-86f1-41af-91ab-2d7cd011db47' }
        function az
        {
            $script:az_calls += ,@($args)
            $global:LASTEXITCODE = 0
            return ('{{"accessToken":"wam-token-{0}","expires_on":{1}}}' -f $script:az_calls.Count, [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds())
        }
        $first = get-ado-authorization-header -org_url 'https://dev.azure.com/org'
        $second = get-ado-authorization-header -org_url 'https://dev.azure.com/org'
        assert-true ($first -eq 'Bearer wam-token-1' -and $second -eq $first) "the WAM token was not cached: $first / $second"
        assert-true ($script:az_calls.Count -eq 1) "az was called $($script:az_calls.Count) times."
        assert-true (($script:az_calls[0] -join ' ') -match '--tenant 72f988bf-86f1-41af-91ab-2d7cd011db47') 'the organization tenant was not requested.'
        assert-true (reset-ado-access-token -org_url 'https://dev.azure.com/org') 'a WAM token must be refreshable.'
        $third = get-ado-authorization-header -org_url 'https://dev.azure.com/org'
        assert-true ($third -eq 'Bearer wam-token-2') "the token was not refreshed: $third"
        $script:ado_token_cache = @{}

        # A sign-in failure is retried, then thrown for the caller to handle; it never ends the run.
        $script:az_calls = @()
        function az
        {
            $script:az_calls += ,@($args)
            $global:LASTEXITCODE = 1
        }
        function Start-Sleep { param([int] $Seconds) }
        $caught = $null
        try { [void](get-ado-authorization-header -org_url 'https://dev.azure.com/org') } catch { $caught = $_.Exception.Message }
        assert-true ($script:az_calls.Count -eq 3) "a failing az was tried $($script:az_calls.Count) times."
        assert-true ($caught -match 'az login' -and $caught -notmatch '^fail-with-status') "a token failure must throw an error the caller can handle: $caught"
        $script:ado_token_cache = @{}
    }

    run-test 'Azure DevOps REST retries only safe failures' {
        $env:SYSTEM_ACCESSTOKEN = 'system-token-value'
        $script:propagation_mode = 'pipeline'
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
            $script:rest_calls.Clear()
            $script:rest_responses.Clear()
            foreach ($response in $responses) { $script:rest_responses.Enqueue($response) }
        }
        $url = 'https://dev.azure.com/org/_apis/test'

        set-responses @((new-http-error 503 -retry_after '1'), [pscustomobject]@{ value = 'ok' })
        $result = invoke-ado-rest -Method GET -Url $url
        assert-true ($result.value -eq 'ok' -and $script:rest_calls.Count -eq 2) "a 503 GET was not retried ($($script:rest_calls.Count) calls)."
        assert-true ($script:rest_calls[0].Headers['X-TFS-FedAuthRedirect'] -eq 'Suppress') 'X-TFS-FedAuthRedirect was not sent.'
        assert-true ($script:rest_calls[0].Headers['Authorization'] -eq 'Bearer system-token-value') 'the Authorization header was not sent.'

        set-responses @((new-http-error 404 'TF401019: not found'))
        $caught = $null
        try { invoke-ado-rest -Method GET -Url $url } catch { $caught = $_ }
        assert-true ($caught -and (get-http-status-code $caught) -eq 404 -and $script:rest_calls.Count -eq 1) 'a 404 GET must fail without retrying.'
        assert-true ((get-ado-error-message $caught) -eq 'TF401019: not found') "the service error message was lost: $(get-ado-error-message $caught)"

        set-responses @((new-http-error 500))
        $caught = $null
        try { invoke-ado-rest -Method POST -Url $url -Body @{ a = 1 } } catch { $caught = $_ }
        assert-true ($caught -and $script:rest_calls.Count -eq 1) 'a write that failed with a server error must not be retried.'

        set-responses @((new-http-error 429 -retry_after '1'), [pscustomobject]@{ id = 7 })
        $result = invoke-ado-rest -Method PATCH -Url $url -Body @{ status = 'active' }
        assert-true ($result.id -eq 7 -and $script:rest_calls.Count -eq 2) 'a throttled write was not retried.'

        set-responses @('<html>sign in</html>')
        $caught = $null
        try { invoke-ado-rest -Method GET -Url $url } catch { $caught = $_ }
        assert-true ($caught -and $caught.Exception.Message -match 'non-JSON') 'an HTML sign-in page was accepted as a result.'

        $title = 'caf' + [char]0x00E9 + ' ' + [char]0x2014 + ' ok'
        set-responses @([pscustomobject]@{ id = 1 })
        [void](invoke-ado-rest -Method POST -Url $url -Body @{ title = $title })
        $call = $script:rest_calls[0]
        assert-true ($call.ContentType -eq 'application/json; charset=utf-8') "unexpected content type: $($call.ContentType)"
        assert-true ((([System.Text.Encoding]::UTF8.GetString($call.Body)) | ConvertFrom-Json).title -eq $title) 'the request body was not UTF-8.'

        Remove-Item -Path Env:SYSTEM_ACCESSTOKEN
        $script:propagation_mode = 'interactive'
        $script:ado_pat = $null
        $script:ado_token_cache = @{}
        $script:az_calls = @()
        function get-ado-tenant-id { param([string] $org_url) return $null }
        function az
        {
            $script:az_calls += ,@($args)
            $global:LASTEXITCODE = 0
            return ('{{"accessToken":"wam-token-{0}","expires_on":{1}}}' -f $script:az_calls.Count, [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds())
        }
        set-responses @((new-http-error 401), [pscustomobject]@{ ok = $true })
        $result = invoke-ado-rest -Method POST -Url $url -Body @{ a = 1 }
        assert-true ($result.ok -and $script:rest_calls.Count -eq 2 -and $script:az_calls.Count -eq 2) 'a rejected WAM token was not refreshed once.'
        assert-true ($script:rest_calls[1].Headers['Authorization'] -eq 'Bearer wam-token-2') 'the retry did not use the new token.'
        $script:ado_token_cache = @{}
    }

    run-test 'pipeline environment authenticates git without writing the token' {
        $env:SYSTEM_ACCESSTOKEN = 'pipeline-system-secret-123456'
        $script:propagation_mode = 'pipeline'
        $saved_global = $env:GIT_CONFIG_GLOBAL
        Remove-Item -Path Env:GIT_CONFIG_GLOBAL
        $env:GIT_CONFIG_COUNT = '1'
        $env:GIT_CONFIG_KEY_0 = 'core.autocrlf'
        $env:GIT_CONFIG_VALUE_0 = 'input'
        $env:GIT_CONFIG_PARAMETERS = "'core.filemode=false'"
        $temp_config = $null
        initialize-pipeline-environment
        try
        {
            $temp_config = $env:GIT_CONFIG_GLOBAL
            assert-true ($temp_config -and (Test-Path $temp_config)) 'an isolated global git config was not created.'
            foreach ($url in @('https://dev.azure.com/msazure/One/_git/Repo', 'https://msazure@dev.azure.com/msazure/One/_git/Repo', 'https://msazure.visualstudio.com/One/_git/Repo'))
            {
                $header = Invoke-NativeWithTimeout -File git -Arguments @('config', '--get-urlmatch', 'http.extraheader', $url)
                assert-true ($header.StdOut.Trim() -eq "AUTHORIZATION: bearer $($env:SYSTEM_ACCESSTOKEN)") "no Azure DevOps credential for $url."
            }
            assert-true ((& git config --get core.autocrlf) -eq 'input') 'git config entries from the caller environment were dropped.'
            assert-true ((& git config --get core.filemode) -eq 'false') "the caller's git -c parameters were dropped."
            assert-true ((& git config --get credential.interactive) -eq 'never') 'git credential prompts were not disabled.'
            assert-true ((& git config --global --get user.name) -eq 'c-build-tools dependency propagation') 'the commit identity was not configured.'
            assert-true ((Get-Content -Raw -Path $temp_config) -notmatch [regex]::Escape($env:SYSTEM_ACCESSTOKEN)) 'the token was written to disk.'
            assert-true ($env:GIT_TERMINAL_PROMPT -eq '0' -and $env:GCM_INTERACTIVE -eq 'never' -and $env:GH_PROMPT_DISABLED -eq '1') 'prompts were not disabled.'
        }
        finally
        {
            remove-pipeline-environment
        }
        assert-true ($env:GIT_CONFIG_COUNT -eq '1' -and $env:GIT_CONFIG_KEY_0 -eq 'core.autocrlf' -and -not (Test-Path Env:GIT_CONFIG_KEY_1)) 'environment git config was not restored.'
        assert-true ($env:GIT_CONFIG_PARAMETERS -eq "'core.filemode=false'") 'git -c parameters were not restored.'
        assert-true (-not (Test-Path Env:GIT_CONFIG_GLOBAL) -and -not (Test-Path $temp_config)) 'the isolated git config was not removed.'
        assert-true (-not (Test-Path Env:GIT_TERMINAL_PROMPT)) 'prompt settings were not restored.'

        $caller_config = Join-Path $test_root 'caller.gitconfig'
        & git config --file $caller_config user.name 'caller identity'
        $env:GIT_CONFIG_GLOBAL = $caller_config
        initialize-pipeline-environment
        try
        {
            assert-true ($env:GIT_CONFIG_GLOBAL -eq $caller_config) "the caller's global git config was replaced."
            assert-true ((& git config --global --get user.name) -eq 'caller identity') "the caller's identity was overwritten."
        }
        finally
        {
            remove-pipeline-environment
        }
        assert-true (Test-Path $caller_config) "the caller's global git config was deleted."

        Remove-Item -Path Env:GIT_CONFIG_COUNT, Env:GIT_CONFIG_KEY_0, Env:GIT_CONFIG_VALUE_0, Env:GIT_CONFIG_PARAMETERS, Env:SYSTEM_ACCESSTOKEN
        $env:GIT_CONFIG_GLOBAL = $saved_global
    }

    run-test 'pipeline git sends one Azure DevOps credential when the caller configured one too' {
        $env:SYSTEM_ACCESSTOKEN = 'pipeline-system-secret-123456'
        $script:propagation_mode = 'pipeline'
        $saved_global = $env:GIT_CONFIG_GLOBAL
        $saved_hosts = $script:ado_git_hosts
        $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $server = "http://127.0.0.1:$($listener.LocalEndpoint.Port)"
        # Like the EBS pipeline, the caller already put a credential for the host in its global config.
        $caller_config = Join-Path $test_root 'caller-credential.gitconfig'
        & git config --file $caller_config "http.$server.extraheader" 'AUTHORIZATION: bearer caller-token'
        $env:GIT_CONFIG_GLOBAL = $caller_config
        $script:ado_git_hosts = @($server)
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
        $headers = @($request -split "`r`n" | Where-Object { $_ -match '^authorization:' })
        assert-true ($headers.Count -eq 1) "git sent $($headers.Count) Authorization headers: $($headers -join ' | ')"
        assert-true (($headers -join ' ') -match 'pipeline-system-secret-123456') "git did not send the pipeline token: $($headers -join ' | ')"
    }

    run-test 'update order follows dependencies and rejects cycles' {
        $edges = New-Object 'System.Collections.Generic.Dictionary[string, System.Collections.ArrayList]'
        $edges['root'] = [System.Collections.ArrayList]@('left', 'right')
        $edges['left'] = [System.Collections.ArrayList]@('leaf')
        $edges['right'] = [System.Collections.ArrayList]@('leaf', 'middle')
        $edges['middle'] = [System.Collections.ArrayList]@('leaf')
        $edges['leaf'] = New-Object System.Collections.ArrayList
        $order = get-repo-update-order -root_list @('https://example.com/org/root') -repo_edges $edges
        assert-true (($order -join ',') -eq 'leaf,middle,left,right,root') "unexpected order: $($order -join ',')"

        $cycle = New-Object 'System.Collections.Generic.Dictionary[string, System.Collections.ArrayList]'
        $cycle['a'] = [System.Collections.ArrayList]@('b')
        $cycle['b'] = [System.Collections.ArrayList]@('a')
        $caught = $null
        try { [void](get-repo-update-order -root_list @('https://example.com/org/a') -repo_edges $cycle) } catch { $caught = $_.Exception.Message }
        assert-true ($caught -match 'Dependency cycle') "a dependency cycle was not rejected: $caught"

        $done = New-Object 'System.Collections.Generic.HashSet[string]'
        assert-true ((@(get-unfinished-dependencies -repo_name 'middle' -repo_edges $edges -done $done) -join ',') -eq 'leaf') 'a repo must wait for its dependencies.'
        [void]$done.Add('leaf')
        assert-true (@(get-unfinished-dependencies -repo_name 'middle' -repo_edges $edges -done $done).Count -eq 0) 'a repo must start once its dependencies are done.'
    }

    run-test 'repository URLs are parsed consistently' {
        assert-true ((get-name-from-url 'https://github.com/Azure/c-build-tools.git') -eq 'c-build-tools') 'GitHub URL'
        assert-true ((get-name-from-url 'https://msazure.visualstudio.com/One/_git/Azure-MessagingStore') -eq 'Azure-MessagingStore') 'Azure DevOps URL'
        assert-true ((get-name-from-url 'C:\repos\child.git') -eq 'child') 'local path'
        $info = get-azure-org-project-from-url 'https://msazure@dev.azure.com/msazure/One/_git/zrpc'
        assert-true ($info.Organization -eq 'https://dev.azure.com/msazure' -and $info.Project -eq 'One') 'dev.azure.com URL'
        $info = get-azure-org-project-from-url 'https://msazure.visualstudio.com/DefaultCollection/One/_git/zrpc'
        assert-true ($info.Organization -eq 'https://dev.azure.com/msazure' -and $info.Project -eq 'One') 'visualstudio.com URL'
        assert-true ($null -eq (get-azure-org-project-from-url 'https://github.com/Azure/c-pal')) 'a GitHub URL is not an Azure DevOps repo'
        assert-true ((get-ado-org-base-url 'https://dev.azure.com/msazure/One/_apis/git') -eq 'https://dev.azure.com/msazure') 'organization URL'
        assert-true ((get-azure-pr-id-from-url 'https://dev.azure.com/msazure/One/_git/zrpc/pullrequest/123') -eq 123) 'PR id'
    }

    run-test 'status table reports success only when every repo finished' {
        foreach ($mode in @('pipeline', 'interactive'))
        {
            $script:propagation_mode = $mode
            initialize-repo-status -repos @('a', 'b')
            set-repo-status -repo_name 'a' -status $script:STATUS_UPDATED
            set-repo-status -repo_name 'b' -status $script:STATUS_IN_PROGRESS
            set-repo-details -repo_name 'b' -details 'waiting on reviewers'
            $unfinished = show-propagation-status -Final 6>$null
            set-repo-status -repo_name 'b' -status $script:STATUS_SKIPPED
            $finished = show-propagation-status -Final 6>$null
            assert-true (-not $unfinished -and $finished) "$mode success must require every repo to be updated or skipped."
        }
        $script:propagation_mode = 'pipeline'
        assert-true ((get-repo-status-display -status 'updated').Symbol -eq '+') 'pipeline logs use ASCII status symbols.'
        $script:propagation_mode = 'interactive'
        assert-true ((get-repo-status-display -status 'updated').Symbol -eq [char]0x2713) 'interactive status uses a check mark.'
        $summary = format-gate-summary -gates @(@{ Name = 'build'; State = 'running' }, @{ Name = 'approval'; State = 'awaiting-action' }, @{ Name = 'lint'; State = 'done' })
        assert-true ($summary -match '1 running' -and $summary -match 'awaiting action \[approval\]') "gate summary: $summary"
    }

    run-test 'PR descriptions keep detail when it fits' {
        initialize-repo-status -repos @('c-pal')
        $changes = @(@{ Repo = 'c-pal'; SHA = 'abc1234'; Subject = 'Fix the thing' })
        $script:propagation_mode = 'pipeline'
        $pipeline_description = build-propagation-description $changes
        $script:propagation_mode = 'interactive'
        $interactive_description = build-propagation-description $changes
        assert-true ($pipeline_description.PrTitle -eq '[no begging] [autogenerated] update deps: c-pal') "pipeline title: $($pipeline_description.PrTitle)"
        assert-true ($interactive_description.PrTitle -eq '[autogenerated] update deps: c-pal') "interactive title: $($interactive_description.PrTitle)"
        assert-true ((select-pr-body -description $interactive_description -max_length 3999) -match 'abc1234') 'the detailed body was not used.'

        $many = @(1..200 | ForEach-Object { @{ Repo = "repo$($_ % 3)"; SHA = ('{0:x7}' -f $_); Subject = ('subject ' * 5) + $_ } })
        $long_description = build-propagation-description $many
        assert-true ($long_description.PrBody.Length -gt 3999) 'the test needs a detailed body over the limit.'
        assert-true ((select-pr-body -description $long_description -max_length 3999) -eq $long_description.PrSummaryBody) 'the summary body was not used when the detailed body is too long.'
        $truncated = select-pr-body -description $long_description -max_length 50
        assert-true ($truncated.Length -le 50 -and $truncated.EndsWith('... (truncated)')) "truncation exceeded the limit: $($truncated.Length)"
    }

    run-test 'GitHub PR polling classifies checks' {
        $script:propagation_mode = 'pipeline'
        initialize-repo-status -repos @('c-pal')
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
        $desc = @{ Repo = 'c-pal'; Type = 'github'; PrUrl = 'https://github.com/Azure/c-pal/pull/1' }

        $script:gh_checks = '[{"name":"Gate","state":"IN_PROGRESS","bucket":"pending"}]'
        assert-true ((poll-github-pr-state $desc) -eq 'pending') 'a running check must keep the PR pending.'
        assert-true ($global:repo_status['c-pal'].Details -match '1 running') "details: $($global:repo_status['c-pal'].Details)"

        $script:gh_checks = '[{"name":"Gate","state":"FAILURE","bucket":"fail"},{"name":"license/cla","state":"SUCCESS","bucket":"pass"}]'
        assert-true ((poll-github-pr-state $desc) -eq 'failed') 'a failed check must fail the PR.'

        $script:gh_checks = '[{"name":"Gate","state":"SUCCESS","bucket":"pass"}]'
        $script:gh_calls.Clear()
        assert-true ((poll-github-pr-state $desc) -eq 'pending') 'an unmerged PR stays pending.'
        assert-true (@($script:gh_calls | Where-Object { $_ -like 'pr merge*' }).Count -eq 1) 'a PR whose checks passed was not nudged to merge.'

        $script:gh_state = 'MERGED'
        assert-true ((poll-github-pr-state $desc) -eq 'merged') 'a merged PR was not detected.'
    }

    run-test 'Azure work item links and PR creation are safe to repeat' {
        $azure_work_item = 4242
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

        link-work-item-to-pr-azure 7 'https://dev.azure.com/org' 6>$null
        assert-true (@($script:ado_calls | Where-Object { $_ -like 'PATCH*' }).Count -eq 0) 'an existing work item link was added again.'
        $script:linked = $false
        $script:ado_calls.Clear()
        link-work-item-to-pr-azure 7 'https://dev.azure.com/org' 6>$null
        assert-true (@($script:ado_calls | Where-Object { $_ -like 'PATCH*/_apis/wit/workitems/4242*' }).Count -eq 1) 'a missing work item link was not added.'

        function get-azure-org-project { param([string] $repo_name) return @{ Organization = 'https://dev.azure.com/org'; Project = 'proj' } }
        function find-active-azure-pr { param([string] $repo_name, [string] $branch_name) return 'https://dev.azure.com/org/proj/_git/repo/pullrequest/7' }
        $pr = create-pr-azure 'repo' 'new_deps_1' (build-propagation-description @()) 6>$null
        assert-true ($pr.pullRequestId -eq 7) 'the active PR was not reused after the create call failed.'
    }

    run-test 'Azure policy watcher reads REST evaluations' {
        $script:evaluations = @(
            [pscustomobject]@{ status = 'rejected'; context = [pscustomobject]@{ buildId = 99 }; configuration = [pscustomobject]@{ isBlocking = $true; type = [pscustomobject]@{ id = '0609b952-1397-4640-95ec-e00a01b2c241'; displayName = 'Build' }; settings = [pscustomobject]@{ displayName = 'PR-Gate' } } },
            [pscustomobject]@{ status = 'approved'; context = $null; configuration = [pscustomobject]@{ isBlocking = $true; type = [pscustomobject]@{ id = 'fa4e907d-c16b-4a4c-9dfa-4906e5d171dd'; displayName = 'Minimum number of reviewers' }; settings = [pscustomobject]@{} } }
        )
        function get-ado-pull-request { param([string] $org_url, [int] $pr_id) return [pscustomobject]@{ pullRequestId = $pr_id; repository = [pscustomobject]@{ name = 'zrpc'; project = [pscustomobject]@{ id = 'project-id'; name = 'One' } } } }
        function get-azure-pr-policy-evaluations { param([string] $org, [object] $pr) return $script:evaluations }
        $data = get-policy-display-data -pr_id 5 -org 'https://dev.azure.com/msazure'
        assert-true ($data.PrUrl -eq 'https://dev.azure.com/msazure/One/_git/zrpc/pullrequest/5') "PR URL: $($data.PrUrl)"
        assert-true (@($data.Checks).Count -eq 2) "checks: $(@($data.Checks).Count)"
        $completion = Test-ChecksComplete -checks $data.Checks
        assert-true ($completion.Complete -and -not $completion.Success -and $completion.Message -eq 'Failed: Build') "completion: $($completion.Message)"
        assert-true ((get-azure-policy-name $script:evaluations[0]) -eq 'PR-Gate') 'pipeline gate names use the build name.'
        assert-true ((get-azure-policy-gate-state $script:evaluations[0]) -eq 'failed') 'a rejected build is a failed gate.'
        assert-true ((get-azure-policy-gate-state $script:evaluations[1]) -eq 'done') 'an approved policy is a done gate.'
    }

    run-test 'a failure while reporting a failure does not recurse' {
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
        $result = invoke-entry-script -command "& '$child_script'; exit `$LASTEXITCODE"
        assert-true ($result.ExitCode -ne 0) 'fail-with-status must end the run with a failure.'
        $closes = [regex]::Matches($result.Output, 'closing the failed PR').Count
        assert-true ($closes -eq 1) "the failed PR was closed $closes times: $($result.Output)"
        assert-true ($result.Output -match 'outer failure') "the original failure was not reported: $($result.Output)"
    }

    run-test 'cancelling an Azure PR watch stops watching' {
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
        try
        {
            wait-until-complete-azure -pr_id 5 -org 'https://dev.azure.com/org' -repo_name 'repo' -pr_url 'https://dev.azure.com/org/project/_git/repo/pullrequest/5'
            assert-true $global:propagation_cancelled 'the cancellation was not recorded.'
            assert-true ($script:watch_calls -eq 1) "the PR was watched $($script:watch_calls) times."
        }
        finally
        {
            $global:propagation_cancelled = $false
        }
    }

    run-test 'interactive sign-in keeps the console' {
        # Piping the run (e.g. to Out-Host) would redirect native stdout, so 'gh auth login' could not prompt.
        $ast = get-script-ast $entry_script
        $calls = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'propagate-updates' }, $true))
        assert-true ($calls.Count -gt 0) 'propagate_updates.ps1 does not call propagate-updates.'
        foreach ($call in $calls)
        {
            assert-true ($call.Parent.PipelineElements.Count -eq 1) "propagate-updates is piped at line $($call.Extent.StartLineNumber)."
        }
    }

    run-test 'update-local-repo commits only submodule changes in both modes' {
        foreach ($mode in @('pipeline', 'interactive'))
        {
            $script:propagation_mode = $mode
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

            commit-with-message $child_src 'Revert "Fix the thing" (#12)'
            $child_head = "$(invoke-git @('-C', $child_src, 'rev-parse', 'HEAD'))".Trim()
            invoke-git @('-C', $child_src, 'push', '-q', $child_bare, 'master') | Out-Null

            $work = Join-Path $root 'work'
            New-Item -ItemType Directory -Path $work | Out-Null
            Set-Location $work
            $global:work_dir = $work
            $global:git_mirror_index = @{}
            $global:fixed_commits = @{ child = $child_head }
            $global:repo_change_descriptions = @{}
            initialize-repo-status -repos @('child', 'parent')
            set-repo-status -repo_name 'child' -status $script:STATUS_UPDATED -pr_url 'https://example.com/child/pull/1'

            clone-repo-with-retry -repo_url $parent_bare -target_dir 'parent'
            Set-Content -Path (Join-Path $work 'parent\stray.txt') -Value 'not part of the update'
            $result = update-local-repo 'parent' 'new_deps_test'

            assert-true ($result -is [hashtable]) "$mode update-local-repo returned extra output: $(@($result).Count) objects."
            assert-true ($result.HasChanges) "$mode run did not report its commit."
            $tree = "$(invoke-git @('--git-dir', $parent_bare, 'ls-tree', 'new_deps_test', 'deps/child'))"
            assert-true ($tree -match $child_head) "$mode push did not move deps/child to the fixed commit: $tree"
            $message = (invoke-git @('--git-dir', $parent_bare, 'log', '-1', '--format=%B', 'new_deps_test')) -join "`n"
            assert-true ($message.Contains('Revert "Fix the thing"')) "$mode commit message lost the quoted subject: $message"
            $files = @(invoke-git @('--git-dir', $parent_bare, 'show', '--name-only', '--format=', 'new_deps_test') | Where-Object { $_ })
            assert-true (($files -join ',') -eq 'deps/child') "$mode commit contains unexpected files: $($files -join ',')"
            assert-true (Test-Path (Join-Path $work '_gitmirrors\child.git')) "$mode run did not use the mirror cache."
            $expected_prefix = if ($mode -eq 'pipeline') { '[no begging] [autogenerated]' } else { '[autogenerated]' }
            assert-true ($result.Description.PrTitle.StartsWith($expected_prefix)) "$mode PR title: $($result.Description.PrTitle)"
            assert-true ($result.Description.PrBody -match 'https://example.com/child/pull/1') "$mode PR body lacks the related PR link."
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
