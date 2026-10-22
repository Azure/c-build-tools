# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Helpers shared by the end-to-end test runner and its fake Azure DevOps, Azure CLI and GitHub services.
# $env:FAKE_WORLD is the scenario's world directory. It holds world.json (configuration),
# ado_state.json and gh_state.json (service state), and events.jsonl (every observable action, in order).

function get-fake-path
{
    param([string] $name)
    return (Join-Path $env:FAKE_WORLD $name)
}

function read-fake-json
{
    param([string] $name)
    $path = get-fake-path $name
    if (Test-Path -LiteralPath $path)
    {
        return ([System.IO.File]::ReadAllText($path) | ConvertFrom-Json)
    }
    else
    {
        return $null
    }
}

function write-fake-json
{
    param(
        [string] $name,
        $value
    )
    $json = ConvertTo-Json -InputObject $value -Depth 30
    [System.IO.File]::WriteAllText((get-fake-path $name), $json, (New-Object System.Text.UTF8Encoding $false))
}

function add-fake-event
{
    param([hashtable] $fields)
    # Events of a multi-run scenario (e.g. a run and its -Resume) carry the run's number.
    if ($env:FAKE_RUN_INDEX)
    {
        $fields['run'] = [int]$env:FAKE_RUN_INDEX
    }
    else
    {
        # a single-run scenario
    }
    $line = ConvertTo-Json -InputObject $fields -Depth 30 -Compress
    [System.IO.File]::AppendAllText((get-fake-path 'events.jsonl'), $line + "`n", (New-Object System.Text.UTF8Encoding $false))
}

# Replace the Microsoft.PowerShell.Utility cmdlet $name with a global function that runs $body and
# declares the cmdlet's own parameters, as this PowerShell edition defines them. Code that looks for
# a parameter ((Get-Command $name).Parameters) then sees what it would see for real, and arguments
# the real cmdlet does not accept fail to bind, as they would for real.
function set-fake-cmdlet-proxy
{
    param(
        [string] $name,
        [string] $body
    )
    $metadata = [System.Management.Automation.CommandMetadata]::new((Get-Command "Microsoft.PowerShell.Utility\$name" -CommandType Cmdlet))
    $binding = [System.Management.Automation.ProxyCommand]::GetCmdletBindingAttribute($metadata)
    $parameters = [System.Management.Automation.ProxyCommand]::GetParamBlock($metadata)
    Set-Item -LiteralPath "function:global:$name" -Value ([scriptblock]::Create("$binding`nparam(`n$parameters`n)`n$body"))
}

# The URL a web cmdlet was called with, as given (Uri.ToString() would unescape its query).
function get-fake-request-url
{
    param($uri)
    if ($uri -is [System.Uri])
    {
        return $uri.OriginalString
    }
    else
    {
        return [string]$uri
    }
}

# Quote one argument for a Windows command line, following the CommandLineToArgvW parsing rules.
function format-fake-argument
{
    param([string] $value)
    if ($value.Length -gt 0 -and $value -notmatch '[\s"]')
    {
        return $value
    }
    else
    {
        $escaped = [regex]::Replace($value, '(\\*)"', '$1$1\"')
        $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
        return '"' + $escaped + '"'
    }
}

# Run git through System.Diagnostics.Process so the caller's $LASTEXITCODE and error stream stay
# untouched: the propagation scripts read $LASTEXITCODE after their own commands.
function invoke-fake-git
{
    param(
        [string[]] $git_args,
        [string] $directory = $null,
        [string] $input_file = $null,
        [switch] $AllowFail
    )
    if (-not $global:FakeGitPath)
    {
        $global:FakeGitPath = (Get-Command -Name git -CommandType Application | Select-Object -First 1).Path
    }
    else
    {
        # already resolved
    }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $global:FakeGitPath
    $info.Arguments = (@($git_args | ForEach-Object { format-fake-argument $_ }) -join ' ')
    if ($directory)
    {
        $info.WorkingDirectory = $directory
    }
    else
    {
        $info.WorkingDirectory = [System.IO.Path]::GetTempPath()
    }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $info.RedirectStandardInput = [bool]$input_file
    $process = [System.Diagnostics.Process]::Start($info)
    $stderr = $process.StandardError.ReadToEndAsync()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    if ($input_file)
    {
        $bytes = [System.IO.File]::ReadAllBytes($input_file)
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.Close()
    }
    else
    {
        # no input
    }
    $process.WaitForExit()
    $result = [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdout.Result.TrimEnd(); StdErr = $stderr.Result.TrimEnd() }
    $process.Dispose()
    if ($result.ExitCode -ne 0 -and -not $AllowFail)
    {
        throw ("git {0} failed with exit code {1}: {2}" -f ($git_args -join ' '), $result.ExitCode, $result.StdErr)
    }
    else
    {
        # succeeded, or the caller handles the failure
    }
    return $result
}

# Resolve a revision in a bare repository, or $null when it does not exist.
function get-fake-revision
{
    param(
        [string] $bare,
        [string] $revision
    )
    $result = invoke-fake-git -git_args @("--git-dir=$bare", 'rev-parse', '--verify', '--quiet', $revision) -AllowFail
    if ($result.ExitCode -eq 0 -and $result.StdOut)
    {
        return $result.StdOut.Trim()
    }
    else
    {
        return $null
    }
}

function get-fake-commit-message
{
    param(
        [string] $bare,
        [string] $commit
    )
    return (invoke-fake-git -git_args @("--git-dir=$bare", 'log', '-1', '--format=%B', $commit)).StdOut
}

# Commit $tree on top of master with $message and move master to it. Returns the new commit.
function add-fake-master-commit
{
    param(
        [string] $bare,
        [string] $tree,
        [string] $message
    )
    $master = get-fake-revision $bare 'refs/heads/master'
    $message_file = Join-Path ([System.IO.Path]::GetTempPath()) ('fake-message-' + [guid]::NewGuid().ToString('N') + '.txt')
    [System.IO.File]::WriteAllText($message_file, $message, (New-Object System.Text.UTF8Encoding $false))
    try
    {
        $commit = (invoke-fake-git -git_args @("--git-dir=$bare", '-c', 'user.name=Fake Service', '-c', 'user.email=fake-service@example.com', 'commit-tree', $tree, '-p', $master, '-F', $message_file)).StdOut.Trim()
    }
    finally
    {
        Remove-Item -LiteralPath $message_file -ErrorAction SilentlyContinue
    }
    [void](invoke-fake-git -git_args @("--git-dir=$bare", 'update-ref', 'refs/heads/master', $commit, $master))
    return $commit
}

# Squash-merge $branch into master the way Azure DevOps and GitHub do: one new commit on master with
# the branch's tree. Only this repository's own pull request moves its master in these scenarios, so
# the branch must be based on the current master.
function merge-fake-branch
{
    param(
        [string] $bare,
        [string] $branch,
        [string] $message,
        [bool] $delete_branch
    )
    $master = get-fake-revision $bare 'refs/heads/master'
    $head = get-fake-revision $bare "refs/heads/$branch"
    if (-not $head)
    {
        throw "cannot merge ${branch}: the branch does not exist in $bare"
    }
    else
    {
        # branch present
    }
    $parent = get-fake-revision $bare "$head^"
    if ($parent -ne $master)
    {
        throw "cannot squash-merge $branch in ${bare}: it is based on $parent, not on master $master"
    }
    else
    {
        # based on master, so the branch's tree is the merge result
    }
    $tree = get-fake-revision $bare "$head^{tree}"
    $commit = add-fake-master-commit -bare $bare -tree $tree -message $message
    if ($delete_branch)
    {
        [void](invoke-fake-git -git_args @("--git-dir=$bare", 'update-ref', '-d', "refs/heads/$branch"))
    }
    else
    {
        # keep the source branch
    }
    return $commit
}
