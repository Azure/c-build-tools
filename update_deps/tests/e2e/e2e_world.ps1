# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Builds the fake worlds for test_e2e.ps1 and runs one propagation in a world.
#
# A world is a folder with local bare repositories that stand in for Azure DevOps and GitHub. The
# propagation scripts keep using the real https URLs (both versions derive behavior from them).
# url.<base>.insteadOf rules in a test system git config send every transfer to the bare repositories.

$e2e_ado_url = 'https://msazure.visualstudio.com/One/_git/'
$e2e_github_url = 'https://github.com/Azure/'

# The dependency graph, in creation order. FakeRoot reaches FakeLib through a relative submodule URL,
# and libuv is listed in ignores.json, so it is never updated.
$e2e_repo_specs = [ordered]@{
    'c-build-tools' = @{ Host = 'github'; Deps = @() }
    'libuv' = @{ Host = 'github'; Deps = @() }
    'fake-pal' = @{ Host = 'github'; Deps = @('c-build-tools') }
    'fake-logging' = @{ Host = 'github'; Deps = @('c-build-tools') }
    'fake-util' = @{ Host = 'github'; Deps = @('c-build-tools', 'fake-pal'); PipelineYaml = $true }
    'FakeLib' = @{ Host = 'ado'; Deps = @('c-build-tools', 'fake-logging', 'fake-util'); PipelineYaml = $true }
    'FakeApp' = @{ Host = 'ado'; Deps = @('c-build-tools', 'fake-util'); PipelineYaml = $true }
    'FakeRoot' = @{ Host = 'ado'; Deps = @('c-build-tools', 'fake-util', 'FakeLib', 'libuv'); PipelineYaml = $true; RelativeDeps = @('FakeLib') }
}

# Two roots, like the production pipeline, in both Azure DevOps URL forms.
$e2e_roots = @('https://msazure.visualstudio.com/One/_git/FakeRoot', 'https://msazure.visualstudio.com/DefaultCollection/One/_git/FakeApp')

# The CLI shim, built as gh.exe (the fake gh) and as az.exe (a tripwire). It saves its arguments
# (base64, one per line) and runs the script named by FAKE_<NAME>_SCRIPT (FAKE_GH_SCRIPT for gh.exe)
# with Windows PowerShell, relaying stdout, stderr and the exit code.
$e2e_gh_shim_source = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

public static class FakeCliShim
{
    public static int Main(string[] args)
    {
        string name = Path.GetFileNameWithoutExtension(Assembly.GetExecutingAssembly().Location);
        string script = Environment.GetEnvironmentVariable("FAKE_" + name.ToUpperInvariant() + "_SCRIPT");
        string world = Environment.GetEnvironmentVariable("FAKE_WORLD");
        if (string.IsNullOrEmpty(world))
        {
            world = Path.GetTempPath();
        }
        string argsFile = Path.Combine(world, name.ToLowerInvariant() + "-args-" + Guid.NewGuid().ToString("N") + ".txt");
        string[] lines = new string[args.Length];
        for (int i = 0; i < args.Length; i++)
        {
            lines[i] = "a:" + Convert.ToBase64String(Encoding.UTF8.GetBytes(args[i]));
        }
        File.WriteAllLines(argsFile, lines);
        string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        ProcessStartInfo info = new ProcessStartInfo(powershell, "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + script + "\" -ArgsFile \"" + argsFile + "\"");
        info.UseShellExecute = false;
        info.RedirectStandardOutput = true;
        info.RedirectStandardError = true;
        info.StandardOutputEncoding = Encoding.UTF8;
        info.StandardErrorEncoding = Encoding.UTF8;
        using (Process child = Process.Start(info))
        {
            var error = child.StandardError.ReadToEndAsync();
            string output = child.StandardOutput.ReadToEnd();
            child.WaitForExit();
            UTF8Encoding utf8 = new UTF8Encoding(false);
            byte[] outBytes = utf8.GetBytes(output);
            Stream stdout = Console.OpenStandardOutput();
            stdout.Write(outBytes, 0, outBytes.Length);
            stdout.Flush();
            byte[] errorBytes = utf8.GetBytes(error.Result);
            Stream stderr = Console.OpenStandardError();
            stderr.Write(errorBytes, 0, errorBytes.Length);
            stderr.Flush();
            try { File.Delete(argsFile); } catch (IOException) { }
            return child.ExitCode;
        }
    }
}
'@

# Start a process with a clean environment. complete-e2e-process waits for it, within
# $timeout_sec of its start. With -Console the process gets its own hidden console and no redirected
# streams, like a developer's terminal: console APIs work, nothing is read from stdin (no key is ever
# pressed), and the output is not captured (interactive runs record a transcript instead).
function start-e2e-process
{
    param(
        [string] $file,
        [string[]] $arguments,
        [string] $directory = $null,
        [hashtable] $environment = $null,
        [int] $timeout_sec = 600,
        [switch] $Console
    )
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $file
    $info.Arguments = (@($arguments | ForEach-Object { format-fake-argument $_ }) -join ' ')
    if ($directory)
    {
        $info.WorkingDirectory = $directory
    }
    else
    {
        # current directory
    }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    if (-not $Console)
    {
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $info.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    }
    else
    {
        # the hidden console keeps the streams
    }
    if ($environment)
    {
        $info.EnvironmentVariables.Clear()
        foreach ($name in $environment.Keys)
        {
            $info.EnvironmentVariables[$name] = [string]$environment[$name]
        }
    }
    else
    {
        # inherit this process's environment
    }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = [System.Diagnostics.Process]::Start($info)
    $stdout = $null
    $stderr = $null
    if (-not $Console)
    {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
    }
    else
    {
        # nothing to read
    }
    return [pscustomobject]@{
        Process = $process
        StdOut = $stdout
        StdErr = $stderr
        Watch = $watch
        TimeoutSec = $timeout_sec
    }
}

# True once a started process has exited or run out of time.
function test-e2e-process-done
{
    param($started)
    return ($started.Process.HasExited -or $started.Watch.Elapsed.TotalSeconds -ge $started.TimeoutSec)
}

# Wait for a started process (killing its whole tree when it runs out of time). Returns ExitCode,
# StdOut, StdErr, TimedOut and Seconds.
function complete-e2e-process
{
    param($started)
    $remaining = [Math]::Max(0, [int]($started.TimeoutSec * 1000 - $started.Watch.ElapsedMilliseconds))
    $timed_out = -not $started.Process.WaitForExit($remaining)
    if ($timed_out)
    {
        $kill = New-Object System.Diagnostics.ProcessStartInfo
        $kill.FileName = 'taskkill.exe'
        $kill.Arguments = "/PID $($started.Process.Id) /T /F"
        $kill.UseShellExecute = $false
        $kill.CreateNoWindow = $true
        $kill.RedirectStandardOutput = $true
        $kill.RedirectStandardError = $true
        $killer = [System.Diagnostics.Process]::Start($kill)
        [void]$killer.WaitForExit(30000)
        [void]$started.Process.WaitForExit(30000)
    }
    else
    {
        # finished in time
    }
    $result = [pscustomobject]@{
        ExitCode = -1
        StdOut = ''
        StdErr = ''
        TimedOut = $timed_out
        Seconds = [int]$started.Watch.Elapsed.TotalSeconds
    }
    if ($started.StdOut -and $started.StdOut.Wait(30000))
    {
        $result.StdOut = $started.StdOut.Result
    }
    else
    {
        # not captured, or still open (orphaned child)
    }
    if ($started.StdErr -and $started.StdErr.Wait(30000))
    {
        $result.StdErr = $started.StdErr.Result
    }
    else
    {
        # not captured, or still open (orphaned child)
    }
    if (-not $timed_out)
    {
        $result.ExitCode = $started.Process.ExitCode
    }
    else
    {
        # killed
    }
    $started.Process.Dispose()
    return $result
}

function invoke-e2e-process
{
    param(
        [string] $file,
        [string[]] $arguments,
        [string] $directory = $null,
        [hashtable] $environment = $null,
        [int] $timeout_sec = 600
    )
    return (complete-e2e-process (start-e2e-process -file $file -arguments $arguments -directory $directory -environment $environment -timeout_sec $timeout_sec))
}

# Build the CLI shims (gh.exe, the fake gh; az.exe, a tripwire) with Windows PowerShell's Add-Type
# (the .NET Framework compiler ships with Windows). Returns their folder.
function build-e2e-shims
{
    param([string] $directory)
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $source = Join-Path $directory 'cli_shim.cs'
    $current = $null
    if (Test-Path -LiteralPath $source)
    {
        $current = [System.IO.File]::ReadAllText($source)
    }
    else
    {
        # first build
    }
    $stale = ($current -cne $e2e_gh_shim_source)
    [System.IO.File]::WriteAllText($source, $e2e_gh_shim_source)
    foreach ($name in @('gh', 'az'))
    {
        $exe = Join-Path $directory "$name.exe"
        if ($stale -or -not (Test-Path -LiteralPath $exe))
        {
            Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
            $command = "Add-Type -TypeDefinition ([System.IO.File]::ReadAllText('$source')) -OutputAssembly '$exe' -OutputType ConsoleApplication"
            $build = invoke-e2e-process -file $e2e_powershell -arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $command) -timeout_sec 300
            if (-not (Test-Path -LiteralPath $exe))
            {
                throw "Could not build the fake $name shim: $($build.StdOut) $($build.StdErr)"
            }
            else
            {
                # built
            }
        }
        else
        {
            # already built from this source
        }
    }
    return $directory
}

function invoke-e2e-fixture-git
{
    param(
        [string] $directory,
        [string[]] $git_args
    )
    return (invoke-fake-git -git_args $git_args -directory $directory).StdOut.Trim()
}

function write-e2e-pipeline-yaml
{
    param(
        [string] $repo_dir,
        [string] $c_build_tools_ref
    )
    $build = Join-Path $repo_dir 'build'
    New-Item -ItemType Directory -Force -Path $build | Out-Null
    $lines = @(
        'resources:',
        '  repositories:',
        '  - repository: c_build_tools',
        '    type: github',
        '    name: azure/c-build-tools',
        '    endpoint: github.com_azure',
        "    ref: $c_build_tools_ref",
        '',
        'jobs:',
        '- template: /pipeline_templates/build_all_flavors.yml@c_build_tools'
    )
    [System.IO.File]::WriteAllText((Join-Path $build 'pipeline.yml'), (($lines -join "`r`n") + "`r`n"))
}

# known_graph.json for the fixture graph, as a discovery run writes it (ignored libuv left out).
function get-e2e-known-graph-json
{
    $edges = [ordered]@{}
    $urls = [ordered]@{}
    foreach ($name in @($e2e_repo_specs.Keys | Where-Object { $_ -ne 'libuv' }))
    {
        $spec = $e2e_repo_specs[$name]
        $edges[$name] = @($spec.Deps | Where-Object { $_ -ne 'libuv' })
        if ($spec.Host -eq 'ado')
        {
            $urls[$name] = "$e2e_ado_url$name"
        }
        else
        {
            $urls[$name] = "$e2e_github_url$name"
        }
    }
    return (ConvertTo-Json -Depth 5 -InputObject ([ordered]@{ _comment = 'Known dependency graph of the end-to-end test fixtures.'; edges = $edges; urls = $urls }))
}

# Create every fixture repository and its bare copy under $directory\remote. In 'stale' mode each
# dependent points at its dependencies' first commits, so every repository with dependencies needs a
# propagation. In 'current' mode it points at their latest commits, so nothing does. The interactive
# modes are 'stale' with a short c-build-tools history (the original interactive scripts truncate a
# long Azure DevOps description past the 4000-character limit) and a known_graph.json in
# c-build-tools: the repository's own file, which does not know the fixtures ('interactive'), or one
# that matches them ('interactive-known'). Returns the manifest.
function new-e2e-template
{
    param(
        [string] $directory,
        [ValidateSet('stale', 'current', 'interactive', 'interactive-known')][string] $mode
    )
    $interactive = ($mode -like 'interactive*')
    # The c-build-tools change every dependent lists. The original interactive scripts drop upstream
    # commits whose subject starts with a, d, e, g, n, o, r, t or u: they filter "[autogenerated]"
    # commits with -like "`[autogenerated`]*" in double quotes, which leaves a [...] wildcard. The
    # interactive fixtures use a subject that filter keeps.
    $helper_subject = 'Add build helper'
    if ($interactive)
    {
        $helper_subject = 'Build helper added'
    }
    else
    {
        # the pipeline baseline matches the literal prefix
    }
    $fixtures = Join-Path $directory 'fixtures'
    New-Item -ItemType Directory -Force -Path $fixtures, (Join-Path $directory 'remote\ado'), (Join-Path $directory 'remote\github') | Out-Null
    $manifest = [ordered]@{}
    foreach ($name in $e2e_repo_specs.Keys)
    {
        $spec = $e2e_repo_specs[$name]
        $work = Join-Path $fixtures $name
        [void](invoke-e2e-fixture-git -directory $directory -git_args @('init', '-q', '-b', 'master', $work))
        [System.IO.File]::WriteAllText((Join-Path $work 'README.md'), "# $name`r`n")
        $paths = @('README.md')
        $c_build_tools_link = $null
        foreach ($dep in $spec.Deps)
        {
            $url = $manifest[$dep].Url
            if (@($spec.RelativeDeps) -contains $dep)
            {
                $url = "../$dep"
            }
            else
            {
                # absolute URL
            }
            if ($dep -eq 'libuv')
            {
                $target = $manifest[$dep].Initial
            }
            elseif ($name -eq 'FakeApp' -and $dep -eq 'c-build-tools')
            {
                # FakeApp already uses a c-build-tools commit that is ahead of master; it must be kept.
                $target = $manifest[$dep].Side
            }
            elseif ($mode -ne 'current')
            {
                $target = $manifest[$dep].Initial
            }
            else
            {
                $target = $manifest[$dep].Final
            }
            if ($dep -eq 'c-build-tools')
            {
                $c_build_tools_link = $target
            }
            else
            {
                # not the pipeline template repository
            }
            [void](invoke-e2e-fixture-git -directory $work -git_args @('config', '-f', '.gitmodules', "submodule.deps/$dep.path", "deps/$dep"))
            [void](invoke-e2e-fixture-git -directory $work -git_args @('config', '-f', '.gitmodules', "submodule.deps/$dep.url", $url))
            [void](invoke-e2e-fixture-git -directory $work -git_args @('update-index', '--add', '--cacheinfo', "160000,$target,deps/$dep"))
        }
        if ($spec.Deps.Count -gt 0)
        {
            $paths += '.gitmodules'
        }
        else
        {
            # no submodules
        }
        if ($spec.PipelineYaml)
        {
            write-e2e-pipeline-yaml -repo_dir $work -c_build_tools_ref $c_build_tools_link
            $paths += 'build'
        }
        else
        {
            # no pipeline YAML
        }
        if ($interactive -and $name -eq 'c-build-tools')
        {
            # Interactive runs read raw.githubusercontent.com/Azure/c-build-tools/master/update_deps/known_graph.json.
            $graph_json = $null
            if ($mode -eq 'interactive-known')
            {
                $graph_json = get-e2e-known-graph-json
            }
            else
            {
                $graph_json = [System.IO.File]::ReadAllText((Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'known_graph.json'))
            }
            New-Item -ItemType Directory -Force -Path (Join-Path $work 'update_deps') | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $work 'update_deps\known_graph.json'), $graph_json)
            $paths += 'update_deps'
        }
        else
        {
            # no known graph
        }
        [void](invoke-e2e-fixture-git -directory $work -git_args (@('add', '--') + $paths))
        [void](invoke-e2e-fixture-git -directory $work -git_args @('commit', '-q', '-m', "Initial $name"))
        $initial = invoke-e2e-fixture-git -directory $work -git_args @('rev-parse', 'HEAD')
        $side = $null
        if ($name -eq 'c-build-tools')
        {
            [System.IO.File]::WriteAllText((Join-Path $work 'helper.txt'), "helper`r`n")
            [void](invoke-e2e-fixture-git -directory $work -git_args @('add', '--', 'helper.txt'))
            [void](invoke-e2e-fixture-git -directory $work -git_args @('commit', '-q', '-m', $helper_subject))
            # Enough commits that listing each one exceeds the 4000-character Azure DevOps limit,
            # made in one fast-import run (empty commits keep their parent's tree).
            $helper = invoke-e2e-fixture-git -directory $work -git_args @('rev-parse', 'HEAD')
            $stream = New-Object System.Text.StringBuilder
            $filler_count = 60
            if ($interactive)
            {
                $filler_count = 0
            }
            else
            {
                # pipeline fixtures exercise the description limit
            }
            for ($i = 1; $i -le $filler_count; $i++)
            {
                $message = 'Refine build helper step {0:D2} so the propagated commit list exceeds the description limit' -f $i
                [void]$stream.Append("commit refs/heads/master`n")
                [void]$stream.Append("committer Fixture Author <fixture-author@example.com> $(1767225600 + $i) +0000`n")
                [void]$stream.Append("data $($message.Length)`n$message`n")
                if ($i -eq 1)
                {
                    [void]$stream.Append("from $helper`n")
                }
                else
                {
                    # continues the branch
                }
                [void]$stream.Append("`n")
            }
            $stream_file = Join-Path $directory 'c-build-tools-commits.txt'
            [System.IO.File]::WriteAllText($stream_file, $stream.ToString())
            [void](invoke-fake-git -git_args @('fast-import', '--quiet') -directory $work -input_file $stream_file)
            [void](invoke-e2e-fixture-git -directory $work -git_args @('reset', '-q', '--hard', 'master'))
            [void](invoke-e2e-fixture-git -directory $work -git_args @('checkout', '-q', '-b', 'side'))
            [System.IO.File]::WriteAllText((Join-Path $work 'side.txt'), "side`r`n")
            [void](invoke-e2e-fixture-git -directory $work -git_args @('add', '--', 'side.txt'))
            [void](invoke-e2e-fixture-git -directory $work -git_args @('commit', '-q', '-m', 'Side branch build tweak'))
            $side = invoke-e2e-fixture-git -directory $work -git_args @('rev-parse', 'HEAD')
            [void](invoke-e2e-fixture-git -directory $work -git_args @('checkout', '-q', 'master'))
        }
        elseif ($name -eq 'fake-pal')
        {
            [System.IO.File]::WriteAllText((Join-Path $work 'pal.txt'), "pal`r`n")
            [void](invoke-e2e-fixture-git -directory $work -git_args @('add', '--', 'pal.txt'))
            [void](invoke-e2e-fixture-git -directory $work -git_args @('commit', '-q', '-m', 'Pal improvement (#7)'))
        }
        elseif ($name -eq 'libuv')
        {
            [System.IO.File]::WriteAllText((Join-Path $work 'NEWS.txt'), "release`r`n")
            [void](invoke-e2e-fixture-git -directory $work -git_args @('add', '--', 'NEWS.txt'))
            [void](invoke-e2e-fixture-git -directory $work -git_args @('commit', '-q', '-m', 'libuv newer release'))
        }
        else
        {
            # no further commits
        }
        $final = invoke-e2e-fixture-git -directory $work -git_args @('rev-parse', 'master')
        if ($spec.Host -eq 'ado')
        {
            $url = "$e2e_ado_url$name"
            $bare = "remote\ado\$name"
        }
        else
        {
            $url = "$e2e_github_url$name.git"
            $bare = "remote\github\$name.git"
        }
        [void](invoke-e2e-fixture-git -directory $directory -git_args @('clone', '-q', '--bare', $work, (Join-Path $directory $bare)))
        $manifest[$name] = @{
            Host = $spec.Host
            Url = $url
            Slug = "Azure/$name"
            Id = [guid]::NewGuid().ToString()
            Bare = $bare
            Deps = @($spec.Deps | Where-Object { $_ -ne 'libuv' })
            Initial = $initial
            Final = $final
            Side = $side
        }
    }
    return @{ Directory = $directory; Mode = $mode; Repos = $manifest; HelperSubject = $helper_subject }
}

# Make a scenario's world from a template: a copy of its bare repositories, the system git config that
# routes the real URLs to them, and world.json for the fake services. $settings holds the scenario's
# Ado, Gh and Az settings (see fake_ado.ps1, fake_gh.ps1 and fake_az.ps1). An interactive world also
# gets a developer's global git config, an Azure CLI config folder, and runs on virtual time with a
# larger sleep budget: interactive runs wait in 100 ms steps.
function new-e2e-world
{
    param(
        [string] $directory,
        [hashtable] $template,
        [hashtable] $settings,
        [switch] $Interactive
    )
    foreach ($folder in @('agent_temp', 'agent_work', 'tmp', 'home', 'azure_config'))
    {
        New-Item -ItemType Directory -Force -Path (Join-Path $directory $folder) | Out-Null
    }
    Copy-Item -Recurse -LiteralPath (Join-Path $template.Directory 'remote') -Destination $directory

    $remote = 'file:///' + ((Join-Path $directory 'remote') -replace '\\', '/')
    $system_config = Join-Path $directory 'gitconfig'
    $entries = @(
        @('init.defaultBranch', 'master'),
        @('protocol.file.allow', 'always'),
        @('core.autocrlf', 'false'),
        @('core.longpaths', 'true'),
        @("url.$remote/ado/.insteadOf", 'https://msazure.visualstudio.com/One/_git/'),
        @("url.$remote/ado/.insteadOf", 'https://msazure.visualstudio.com/DefaultCollection/One/_git/'),
        @("url.$remote/ado/.insteadOf", 'https://dev.azure.com/msazure/One/_git/'),
        @("url.$remote/github/.insteadOf", $e2e_github_url)
    )
    foreach ($entry in $entries)
    {
        [void](invoke-fake-git -git_args @('config', '-f', $system_config, '--add', $entry[0], $entry[1]))
    }

    # The developer's own global git config (interactive runs): their identity, nothing else.
    $developer_config = Join-Path $directory 'home\.gitconfig'
    [System.IO.File]::WriteAllText($developer_config, "[user]`n`tname = Test Developer`n`temail = test-developer@example.com`n")
    if ($Interactive)
    {
        # The developer signed in with 'gh auth login', which keeps the account in the gh config
        # folder (and its token in the Windows credential store).
        New-Item -ItemType Directory -Force -Path (Join-Path $directory 'gh_config') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $directory 'gh_config\hosts.yml'), "github.com:`n    git_protocol: https`n    users:`n        test-developer:`n    user: test-developer`n")
    }
    else
    {
        # pipelines sign gh in through GH_TOKEN
    }

    $repos = [ordered]@{}
    $initial_masters = @{}
    foreach ($name in $template.Repos.Keys)
    {
        $repo = $template.Repos[$name]
        $bare = Join-Path $directory $repo.Bare
        $repos[$name] = @{ Host = $repo.Host; Url = $repo.Url; Slug = $repo.Slug; Id = $repo.Id; Bare = $bare }
        $initial_masters[$name] = get-fake-revision $bare 'refs/heads/master'
    }
    $ado = @{
        BotId = [guid]::NewGuid().ToString()
        BotName = 'Fake Build Service (msazure)'
        UserId = [guid]::NewGuid().ToString()
        UserName = 'Test Developer'
        TenantId = [guid]::NewGuid().ToString()
        Pat = 'fakepat' + [guid]::NewGuid().ToString('N')
        ReviewerId = [guid]::NewGuid().ToString()
        ProjectId = [guid]::NewGuid().ToString()
        ProjectName = 'One'
        InstanceId = [guid]::NewGuid().ToString()
        WorkItems = @(42)
        DefaultCompleteAfter = 1
        CompleteAfter = @{}
        BuildOutcome = @{}
        Reject = @()
        Faults = @()
        RevokeTokensAfterWrites = 0
        RequeueFailedBuilds = $false
    }
    $gh = @{
        Login = 'fake-propagation-bot'
        Interactive = [bool]$Interactive
        DefaultReadyAfter = 1
        ReadyAfter = @{}
        ChecksOutcome = @{}
        NoPush = @()
        Faults = @()
        LateCommit = $null
    }
    $az = @{
        LoggedIn = $true
        Account = 'test-developer@example.com'
        HomeTenantId = [guid]::NewGuid().ToString()
    }
    $world = @{ Path = $directory; Repos = $repos; Ado = $ado; Gh = $gh; Az = $az; SleepBudget = 600; SleepBudgetSeconds = 0 }
    if ($Interactive)
    {
        $world.SleepBudget = 100000
        $world.SleepBudgetSeconds = 6 * 3600
    }
    else
    {
        # pipeline runs poll with short sleeps
    }
    $world['SystemConfig'] = $system_config
    $world['DeveloperConfig'] = $developer_config
    $world['DeveloperConfigText'] = [System.IO.File]::ReadAllText($developer_config)
    $world['InitialMasters'] = $initial_masters
    $world['Template'] = $template
    update-e2e-world -world $world -settings $settings
    [System.IO.File]::WriteAllText((Join-Path $directory 'events.jsonl'), '')
    return $world
}

# Apply scenario settings to a world (each named setting replaces the default) and save world.json.
function update-e2e-world
{
    param(
        [hashtable] $world,
        [hashtable] $settings
    )
    foreach ($service in @('Ado', 'Gh', 'Az'))
    {
        if ($settings -and $settings[$service])
        {
            foreach ($key in @($settings[$service].Keys | Where-Object { $_ }))
            {
                $world[$service][$key] = $settings[$service][$key]
            }
        }
        else
        {
            # defaults
        }
    }
    $env_world = $env:FAKE_WORLD
    $env:FAKE_WORLD = $world.Path
    try
    {
        write-fake-json 'world.json' @{ Repos = $world.Repos; Ado = $world.Ado; Gh = $world.Gh; Az = $world.Az; SleepBudget = $world.SleepBudget; SleepBudgetSeconds = $world.SleepBudgetSeconds }
    }
    finally
    {
        $env:FAKE_WORLD = $env_world
    }
}

# Copy an implementation's update_deps folder (without its tests) into the world, so a run cannot
# change the original (the original interactive scripts save known_graph.json next to themselves).
# Returns the copy's entry script.
function copy-e2e-implementation
{
    param(
        [hashtable] $world,
        [hashtable] $implementation
    )
    $source = Split-Path $implementation.Entry -Parent
    $target = Join-Path $world.Path 'impl\update_deps'
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $source -Force | Where-Object { $_.Name -ne 'tests' }))
    {
        Copy-Item -LiteralPath $item.FullName -Destination $target -Recurse -Force
    }
    return (Join-Path $target (Split-Path $implementation.Entry -Leaf))
}

# The environment of a propagation run, built from scratch so no developer or agent git, gh or token
# settings leak in: the one the Azure-MessagingStore pipeline maps into its propagation task, or a
# developer's console for interactive scenarios. Only file:// git transfers are allowed.
function get-e2e-environment
{
    param(
        [hashtable] $world,
        [hashtable] $scenario,
        [int] $run_index = 1
    )
    $environment = @{}
    foreach ($name in @('SystemRoot', 'SystemDrive', 'windir', 'ComSpec', 'PATHEXT', 'OS', 'PROCESSOR_ARCHITECTURE', 'PROCESSOR_IDENTIFIER', 'PROCESSOR_LEVEL', 'PROCESSOR_REVISION', 'NUMBER_OF_PROCESSORS', 'USERPROFILE', 'USERNAME', 'USERDOMAIN', 'HOMEDRIVE', 'HOMEPATH', 'APPDATA', 'LOCALAPPDATA', 'ProgramData', 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432', 'CommonProgramFiles', 'CommonProgramFiles(x86)', 'CommonProgramW6432', 'PUBLIC', 'ALLUSERSPROFILE', 'COMPUTERNAME'))
    {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value)
        {
            $environment[$name] = $value
        }
        else
        {
            # not set on this machine
        }
    }
    # The fake gh and the az tripwire first, and no real gh or Azure CLI anywhere on PATH.
    $path_entries = @($env:PATH -split ';' | Where-Object {
        $entry = $_
        $keep = $false
        if ($entry)
        {
            try { $keep = -not (@('gh.exe', 'az.cmd', 'az.exe') | Where-Object { Test-Path -LiteralPath (Join-Path $entry $_) }) } catch { $keep = $false }
        }
        else
        {
            # empty entry
        }
        $keep
    })
    $environment['PATH'] = (@($e2e_shim_directory) + $path_entries) -join ';'
    $environment['TEMP'] = Join-Path $world.Path 'tmp'
    $environment['TMP'] = Join-Path $world.Path 'tmp'
    $environment['GIT_CONFIG_SYSTEM'] = $world.SystemConfig
    $environment['GIT_ALLOW_PROTOCOL'] = 'file'
    $environment['GIT_TERMINAL_PROMPT'] = '0'
    $environment['GCM_INTERACTIVE'] = 'never'
    $environment['GH_PROMPT_DISABLED'] = '1'
    $environment['GIT_HTTP_LOW_SPEED_LIMIT'] = '1'
    $environment['GIT_HTTP_LOW_SPEED_TIME'] = '60'
    $environment['GH_CONFIG_DIR'] = Join-Path $world.Path 'gh_config'
    $environment['AZURE_CONFIG_DIR'] = Join-Path $world.Path 'azure_config'
    $environment['FAKE_WORLD'] = $world.Path
    $environment['FAKE_GH_SCRIPT'] = Join-Path $PSScriptRoot 'fake_gh.ps1'
    $environment['FAKE_AZ_SCRIPT'] = Join-Path $PSScriptRoot 'fake_az_exe.ps1'
    $environment['FAKE_RUN_INDEX'] = [string]$run_index
    if ($scenario.Interactive)
    {
        # A developer's console: their own global git config, signed in to gh (gh_config\hosts.yml)
        # and to the Azure CLI (fake_az.ps1), and no pipeline variables or tokens.
        $environment['GIT_CONFIG_GLOBAL'] = $world.DeveloperConfig
    }
    else
    {
        $environment['AGENT_TEMPDIRECTORY'] = Join-Path $world.Path 'agent_temp'
        $environment['GIT_CONFIG_GLOBAL'] = Join-Path $world.Path 'agent_temp\propagate.gitconfig'
        if (-not $scenario.NoSystemToken)
        {
            $environment['SYSTEM_ACCESSTOKEN'] = $e2e_system_token
        }
        else
        {
            # the scenario leaves SYSTEM_ACCESSTOKEN unset
        }
        if (-not $scenario.NoGhToken)
        {
            $environment['GH_TOKEN'] = $e2e_gh_token
        }
        else
        {
            # the scenario leaves GH_TOKEN unset
        }
    }
    return $environment
}

# Start run $run_index of a scenario in the world with run_propagation.ps1: as the pipeline's
# PowerShell@2 task runs it, or (interactive scenarios) as a developer runs it in a console, with the
# implementation's PowerShell. $run holds the run's options (Resume).
function start-e2e-propagation
{
    param(
        [hashtable] $world,
        [hashtable] $implementation,
        [hashtable] $scenario,
        [int] $run_index = 1,
        [hashtable] $run = @{}
    )
    $parameters = [ordered]@{ root_list = $e2e_roots }
    if (-not $scenario.NoWorkItem)
    {
        $parameters['azure_work_item'] = 42
    }
    else
    {
        # the scenario omits the work item
    }
    if ($scenario.NoCloseFailedPr)
    {
        $parameters['NoCloseFailedPr'] = $true
    }
    else
    {
        # failed pull requests are closed (the default)
    }
    if ($scenario.Interactive)
    {
        if ($scenario.Pat)
        {
            $parameters['azure_token'] = $world.Ado.Pat
        }
        else
        {
            # WAM sign-in through the Azure CLI
        }
        if ($run.Resume)
        {
            # The resume command the failed run printed: its parameters plus -Resume.
            $parameters['Resume'] = $true
        }
        else
        {
            # a new propagation
        }
    }
    elseif ($implementation.HasPipelineSwitch)
    {
        $parameters['Pipeline'] = $true
    }
    else
    {
        # the EBS copy is pipeline-only
    }
    $run_file = Join-Path $world.Path "run-$run_index.json"
    $work = Join-Path $world.Path 'agent_work'
    $entry = $implementation.Entry
    if ($world.Entry)
    {
        $entry = $world.Entry
    }
    else
    {
        # the implementation's own copy
    }
    $run_config = @{ EntryScript = $entry; WorkDirectory = $work; Parameters = $parameters; Interactive = [bool]$scenario.Interactive; Transcript = (Join-Path $world.Path "transcript-$run_index.txt") }
    [System.IO.File]::WriteAllText($run_file, (ConvertTo-Json -InputObject $run_config -Depth 10), (New-Object System.Text.UTF8Encoding $false))
    $driver = Join-Path $PSScriptRoot 'run_propagation.ps1'
    $shell = $e2e_powershell
    if ($implementation.Shell)
    {
        $shell = $implementation.Shell
    }
    else
    {
        # Windows PowerShell, the pipeline task's runtime
    }
    return (start-e2e-process -file $shell -arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Unrestricted', '-Command', ". '$driver' '$run_file'") -directory $work -environment (get-e2e-environment -world $world -scenario $scenario -run_index $run_index) -timeout_sec $e2e_run_timeout_sec -Console:([bool]$scenario.Interactive))
}

# Wait for a propagation started by start-e2e-propagation and save its output in the world. An
# interactive run's output is its transcript.
function complete-e2e-propagation
{
    param(
        [hashtable] $world,
        $started,
        [int] $run_index = 1
    )
    $result = complete-e2e-process $started
    $transcript = Join-Path $world.Path "transcript-$run_index.txt"
    $text = ''
    if (Test-Path -LiteralPath $transcript)
    {
        $text = [System.IO.File]::ReadAllText($transcript)
    }
    else
    {
        # a pipeline run, or the run never started its transcript
    }
    $result | Add-Member -NotePropertyName Transcript -NotePropertyValue $text
    $result | Add-Member -NotePropertyName Index -NotePropertyValue $run_index
    [System.IO.File]::WriteAllText((Join-Path $world.Path "output-$run_index.txt"), ($result.StdOut + "`r`n----- stderr -----`r`n" + $result.StdErr))
    return $result
}

# Everything a scenario checks: the runs (Run is the last one), the recorded events (with their
# order), and the fake services' state.
function read-e2e-result
{
    param(
        [hashtable] $world,
        [hashtable] $implementation,
        [hashtable] $scenario,
        [object[]] $runs
    )
    $events = New-Object System.Collections.ArrayList
    $events_file = Join-Path $world.Path 'events.jsonl'
    if (Test-Path -LiteralPath $events_file)
    {
        foreach ($line in [System.IO.File]::ReadAllLines($events_file))
        {
            if ($line.Trim())
            {
                $event = $line | ConvertFrom-Json
                $event | Add-Member -NotePropertyName Index -NotePropertyValue $events.Count
                [void]$events.Add($event)
            }
            else
            {
                # blank line
            }
        }
    }
    else
    {
        # no events recorded
    }
    $ado_state = $null
    $ado_file = Join-Path $world.Path 'ado_state.json'
    if (Test-Path -LiteralPath $ado_file)
    {
        $ado_state = [System.IO.File]::ReadAllText($ado_file) | ConvertFrom-Json
    }
    else
    {
        # no Azure DevOps state was saved
    }
    $outputs = @($runs | ForEach-Object { "$($_.Transcript)`n$($_.StdOut)`n$($_.StdErr)" })
    return @{
        Scenario = $scenario.Name
        Spec = $scenario
        Implementation = $implementation.Name
        World = $world
        Runs = @($runs)
        Run = @($runs)[-1]
        Outputs = $outputs
        Output = ($outputs -join "`n")
        Events = @($events)
        Ado = $ado_state
        Failures = (New-Object System.Collections.Generic.List[string])
    }
}
