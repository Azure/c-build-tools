# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS

Runs the same end-to-end propagation scenarios against the scripts the merged c-build-tools version
replaced and against the merged version, with identical assertions.

.DESCRIPTION

Two baselines:
- Pipeline scenarios run -Pipeline the way the Azure-MessagingStore ("EBS") pipeline does. Their
  baseline is the EBS copy of the propagation scripts.
- Interactive scenarios run propagate_updates.ps1 the way a developer does, in a console with gh and
  the Azure CLI signed in. Their baseline is the c-build-tools version before the merge.

Each scenario builds a fake world:
- Local bare git repositories stand in for Azure DevOps and GitHub. A test system git config routes
  the repositories' real URLs to them (e2e_world.ps1).
- A fake Azure DevOps service answers REST calls through Invoke-RestMethod (fake_ado.ps1) and, in
  interactive runs, Azure CLI commands through az (fake_az.ps1).
- A fake gh CLI (fake_gh.ps1) runs behind a gh.exe shim on PATH.
run_propagation.ps1 runs the propagation. The scenario then checks what happened
(e2e_scenarios.ps1):
- which pull requests were opened, and in what order;
- how they were armed, by whom, and what they say;
- what was merged, and the final submodule state;
- what the run reported, and (interactive) that it never asked for input.
Some scenarios run twice in the same world: a failed run, then its -Resume. Nothing leaves the
machine: git may only use file:// URLs, and other web requests are blocked.

Not covered: the credentials themselves. file:// transfers need none, so the unit tests cover them
(test_propagate_updates.ps1). Interactive Ctrl+C handling and AutoFix are not covered either.

The assertions describe the baselines' behavior. After changing one, run -Implementation both to
confirm the baseline still passes it.

.PARAMETER Implementation

merged (default): the scripts in this repository. baseline (or ebs): the baselines. both: the
baselines, then merged.

.PARAMETER EbsRoot

Folder with the EBS copy's propagate_updates.ps1, needed when baseline pipeline scenarios run. The
baseline is Azure-MessagingStore commit 03122f16a9117680d1a0f9512457dcc6e9b690e3. To extract it from
a clone:

    git -C <Azure-MessagingStore clone> archive --format=zip -o ebs.zip 03122f16a9117680d1a0f9512457dcc6e9b690e3 scripts/update_deps
    Expand-Archive ebs.zip ebs

and pass -EbsRoot ebs\scripts\update_deps.

.PARAMETER CbtRoot

Folder with the c-build-tools version before the merge (its update_deps folder), for baseline
interactive scenarios. By default it is extracted from this repository's commit
10d0c0ff323a235fa5d1618fa470e1076fda186c with git archive.

.PARAMETER Shell

PowerShell editions for interactive scenarios: powershell (Windows PowerShell 5.1) and pwsh
(PowerShell 7). Defaults to both when pwsh is installed. Pipeline scenarios always use Windows
PowerShell, the pipeline task's runtime.

.PARAMETER Kind

all (default), pipeline, or interactive: which scenarios to run.

.PARAMETER Scenario

Run only these scenarios.

.PARAMETER WorkRoot

Folder for the CLI shims (default: a new temporary folder).

.PARAMETER KeepWorlds

Keep every scenario's world folder. Worlds of failed scenarios are always kept.

.PARAMETER ThrottleLimit

How many propagations run at once (default: half the processors, 2 to 8). Every fake service
advances by poll count, never by time, so running in parallel cannot change any outcome.

.EXAMPLE

PS> .\test_e2e.ps1

.EXAMPLE

PS> .\test_e2e.ps1 -Implementation both -EbsRoot C:\temp\ebs\scripts\update_deps
#>

param(
    [ValidateSet('merged', 'baseline', 'ebs', 'both')][string] $Implementation = 'merged',
    [ValidateSet('all', 'pipeline', 'interactive')][string] $Kind = 'all',
    [string] $EbsRoot,
    [string] $CbtRoot,
    [ValidateSet('powershell', 'pwsh')][string[]] $Shell,
    [string[]] $Scenario,
    [string] $WorkRoot,
    [switch] $KeepWorlds,
    [int] $ThrottleLimit = [Math]::Min(8, [Math]::Max(2, [int]([Environment]::ProcessorCount / 2)))
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'fake_services.ps1')
. (Join-Path $PSScriptRoot 'e2e_world.ps1')
. (Join-Path $PSScriptRoot 'e2e_scenarios.ps1')

$e2e_powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$e2e_run_timeout_sec = 1500
$e2e_system_token = 'fake-system-access-token-' + [guid]::NewGuid().ToString('N')
$e2e_gh_token = 'ghp_' + ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')).Substring(0, 36)
$e2e_cbt_baseline_commit = '10d0c0ff323a235fa5d1618fa470e1076fda186c'
$e2e_update_deps = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$e2e_with_baseline = ($Implementation -ne 'merged')
$e2e_with_merged = ($Implementation -eq 'merged' -or $Implementation -eq 'both')

$e2e_selected = @($e2e_scenarios)
if ($Scenario)
{
    $unknown = @($Scenario | Where-Object { $name = $_; -not ($e2e_scenarios | Where-Object { $_.Name -eq $name }) })
    if ($unknown.Count -gt 0)
    {
        Write-Host "ERROR: unknown scenario(s): $($unknown -join ', '). Known: $(($e2e_scenarios | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor Red
        exit 2
    }
    else
    {
        $e2e_selected = @($e2e_scenarios | Where-Object { $Scenario -contains $_.Name })
    }
}
else
{
    # every scenario
}
if ($Kind -ne 'all')
{
    $e2e_selected = @($e2e_selected | Where-Object { [bool]$_.Interactive -eq ($Kind -eq 'interactive') })
}
else
{
    # pipeline and interactive scenarios
}
$e2e_any_pipeline = (@($e2e_selected | Where-Object { -not $_.Interactive }).Count -gt 0)
$e2e_any_interactive = (@($e2e_selected | Where-Object { $_.Interactive }).Count -gt 0)

$e2e_pwsh = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $Shell)
{
    $Shell = @('powershell')
    if ($e2e_pwsh)
    {
        $Shell += 'pwsh'
    }
    else
    {
        Write-Host 'PowerShell 7 (pwsh.exe) is not installed; interactive scenarios run with Windows PowerShell only.' -ForegroundColor Yellow
    }
}
elseif ($Shell -contains 'pwsh' -and -not $e2e_pwsh)
{
    Write-Host 'ERROR: -Shell pwsh needs PowerShell 7 (pwsh.exe) on PATH.' -ForegroundColor Red
    exit 2
}
else
{
    # caller-chosen editions
}

function get-e2e-shell-path
{
    param([string] $name)
    if ($name -eq 'pwsh')
    {
        return $e2e_pwsh.Path
    }
    else
    {
        return $e2e_powershell
    }
}

function test-e2e-pipeline-switch
{
    param([string] $entry)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($entry, [ref]$null, [ref]$null)
    return [bool]($ast.ParamBlock -and @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Pipeline' }).Count -gt 0)
}

$e2e_saved_environment = @{}
$e2e_temp_root = Join-Path ([System.IO.Path]::GetTempPath()) ('cbte' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path $e2e_temp_root | Out-Null

# The implementations each kind of scenario runs against, the baselines first.
$e2e_pipeline_implementations = @()
$e2e_interactive_implementations = @()
if ($e2e_with_baseline -and $e2e_any_pipeline)
{
    $ebs_entry = $null
    if ($EbsRoot)
    {
        $ebs_entry = Join-Path $EbsRoot 'propagate_updates.ps1'
    }
    else
    {
        # reported below
    }
    if (-not $ebs_entry -or -not (Test-Path -LiteralPath $ebs_entry))
    {
        Write-Host "ERROR: baseline pipeline scenarios need -EbsRoot, the folder with the EBS copy's propagate_updates.ps1 (see Get-Help $PSCommandPath -Detailed)." -ForegroundColor Red
        exit 2
    }
    else
    {
        $e2e_pipeline_implementations += @{ Name = 'ebs'; Code = 'e'; Entry = (Resolve-Path -LiteralPath $ebs_entry).Path; Baseline = $true }
    }
}
else
{
    # no baseline pipeline runs
}
if ($e2e_with_baseline -and $e2e_any_interactive)
{
    if (-not $CbtRoot)
    {
        # The c-build-tools version before the merge, from this repository's history.
        $archive = Join-Path $e2e_temp_root 'cbt_baseline.zip'
        $repo_root = Split-Path $e2e_update_deps -Parent
        $extract = invoke-fake-git -git_args @('-C', $repo_root, 'archive', '--format=zip', '-o', $archive, $e2e_cbt_baseline_commit, 'update_deps') -AllowFail
        if ($extract.ExitCode -ne 0)
        {
            Write-Host "ERROR: could not extract the c-build-tools baseline ($e2e_cbt_baseline_commit): $($extract.StdErr). Pass -CbtRoot." -ForegroundColor Red
            exit 2
        }
        else
        {
            Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $e2e_temp_root 'cbt_baseline')
            $CbtRoot = Join-Path $e2e_temp_root 'cbt_baseline\update_deps'
        }
    }
    else
    {
        # caller-provided copy
    }
    $cbt_entry = Join-Path $CbtRoot 'propagate_updates.ps1'
    if (-not (Test-Path -LiteralPath $cbt_entry))
    {
        Write-Host "ERROR: -CbtRoot $CbtRoot has no propagate_updates.ps1." -ForegroundColor Red
        exit 2
    }
    else
    {
        foreach ($shell_name in $Shell)
        {
            $name = 'cbt'
            $code = 'c'
            if ($shell_name -eq 'pwsh')
            {
                $name = 'cbt-pwsh'
                $code = 'cp'
            }
            else
            {
                # Windows PowerShell
            }
            $e2e_interactive_implementations += @{ Name = $name; Code = $code; Entry = (Resolve-Path -LiteralPath $cbt_entry).Path; Shell = (get-e2e-shell-path $shell_name); ShellName = $shell_name; Baseline = $true }
        }
    }
}
else
{
    # no baseline interactive runs
}
if ($e2e_with_merged)
{
    $merged_entry = Join-Path $e2e_update_deps 'propagate_updates.ps1'
    $e2e_pipeline_implementations += @{ Name = 'merged'; Code = 'm'; Entry = $merged_entry; Baseline = $false }
    foreach ($shell_name in $Shell)
    {
        $name = 'merged'
        $code = 'm'
        if ($shell_name -eq 'pwsh')
        {
            $name = 'merged-pwsh'
            $code = 'mp'
        }
        else
        {
            # Windows PowerShell
        }
        $e2e_interactive_implementations += @{ Name = $name; Code = $code; Entry = $merged_entry; Shell = (get-e2e-shell-path $shell_name); ShellName = $shell_name; Baseline = $false }
    }
}
else
{
    # baselines only
}
foreach ($e2e_implementation in @($e2e_pipeline_implementations + $e2e_interactive_implementations))
{
    # The merged version needs -Pipeline; the EBS copy is pipeline-only and has no such switch.
    $e2e_implementation['HasPipelineSwitch'] = test-e2e-pipeline-switch $e2e_implementation.Entry
}

# Fixture git commands must not see the developer's or agent's git configuration or credentials.
foreach ($variable in @(Get-ChildItem Env: | Where-Object { $_.Name -match '^(GIT_|GH_|GCM_|SYSTEM_ACCESSTOKEN$|AZURE_DEVOPS_EXT_PAT$|AZURE_CONFIG_DIR$|ghToken$|FAKE_)' }))
{
    $e2e_saved_environment[$variable.Name] = $variable.Value
    Remove-Item -LiteralPath "Env:$($variable.Name)"
}
$env:GIT_CONFIG_NOSYSTEM = '1'
$env:GIT_CONFIG_GLOBAL = Join-Path $e2e_temp_root 'fixture.gitconfig'
[System.IO.File]::WriteAllText($env:GIT_CONFIG_GLOBAL, "[core]`n`tautocrlf = false`n[commit]`n`tgpgsign = false`n")
$env:GIT_AUTHOR_NAME = 'Fixture Author'
$env:GIT_AUTHOR_EMAIL = 'fixture-author@example.com'
$env:GIT_COMMITTER_NAME = 'Fixture Author'
$env:GIT_COMMITTER_EMAIL = 'fixture-author@example.com'

# Start the job's next run, applying the run's world settings first.
function start-e2e-job-run
{
    param([hashtable] $job)
    $job.RunIndex++
    $run = $job.Scenario.Runs[$job.RunIndex - 1]
    if ($job.RunIndex -gt 1 -and $run.Settings)
    {
        update-e2e-world -world $job.World -settings $run.Settings
    }
    else
    {
        # the world as created
    }
    $job['Started'] = start-e2e-propagation -world $job.World -implementation $job.Implementation -scenario $job.Scenario -run_index $job.RunIndex -run $run
}

# Check one finished scenario, report it, and remove its world unless it failed or -KeepWorlds.
function complete-e2e-job
{
    param([hashtable] $job)
    $r = read-e2e-result -world $job.World -implementation $job.Implementation -scenario $job.Scenario -runs @($job.RunResults)
    assert-e2e-common $r
    try
    {
        & $job.Scenario.Assert $r
    }
    catch
    {
        $r.Failures.Add("the scenario's checks threw: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)")
    }
    $passed = ($r.Failures.Count -eq 0)
    $seconds = 0
    foreach ($run in $job.RunResults)
    {
        $seconds += $run.Seconds
    }
    $job['Result'] = [pscustomobject]@{ Scenario = $job.Scenario.Name; Implementation = $job.Implementation.Name; Passed = $passed; Seconds = $seconds }
    if ($passed)
    {
        Write-Host ("--- {0} ({1}): PASS in {2}s" -f $job.Scenario.Name, $job.Implementation.Name, $seconds) -ForegroundColor Green
        if (-not $KeepWorlds)
        {
            Remove-Item -LiteralPath $job.World.Path -Recurse -Force -ErrorAction SilentlyContinue
        }
        else
        {
            # kept on request
        }
    }
    else
    {
        $codes = ($job.RunResults | ForEach-Object { $_.ExitCode }) -join ', '
        Write-Host ("--- {0} ({1}): FAIL in {2}s (exit codes {3}); world kept at {4}; output in transcript-N.txt / output-N.txt" -f $job.Scenario.Name, $job.Implementation.Name, $seconds, $codes, $job.World.Path) -ForegroundColor Red
        foreach ($failure in $r.Failures)
        {
            Write-Host "    FAILED: $failure" -ForegroundColor Red
        }
    }
}

$e2e_jobs = New-Object System.Collections.ArrayList
$e2e_running = New-Object System.Collections.ArrayList
$e2e_no_jobs = $false
try
{
    $index = 0
    foreach ($e2e_scenario in $e2e_selected)
    {
        $index++
        if (-not $e2e_scenario.Runs)
        {
            $e2e_scenario['Runs'] = @(@{})
        }
        else
        {
            # a run and its -Resume
        }
        $candidates = $e2e_pipeline_implementations
        if ($e2e_scenario.Interactive)
        {
            # A scenario may limit the baseline to the editions where the baseline works (see the scenario).
            $candidates = @($e2e_interactive_implementations | Where-Object { -not $_.Baseline -or -not $e2e_scenario.BaselineShells -or $e2e_scenario.BaselineShells -contains $_.ShellName })
        }
        else
        {
            # pipeline implementations
        }
        foreach ($e2e_implementation in $candidates)
        {
            [void]$e2e_jobs.Add(@{ Scenario = $e2e_scenario; Implementation = $e2e_implementation; Path = (Join-Path $e2e_temp_root ("{0}{1}" -f $index, $e2e_implementation.Code)); RunIndex = 0; RunResults = (New-Object System.Collections.ArrayList) })
        }
    }
    if ($e2e_jobs.Count -eq 0)
    {
        # e.g. only resume scenarios, against the baseline, without PowerShell 7
        Write-Host 'ERROR: none of the selected scenarios runs against the selected implementations and PowerShell editions.' -ForegroundColor Red
        $e2e_no_jobs = $true
    }
    else
    {
        if (-not $WorkRoot)
        {
            $WorkRoot = $e2e_temp_root
        }
        else
        {
            # caller-chosen folder, e.g. the CMake build directory
        }
        $e2e_shim_directory = build-e2e-shims -directory (Join-Path $WorkRoot 'bin')
        Write-Host "Fake gh: $e2e_shim_directory\gh.exe"

        $e2e_templates = @{}
        foreach ($mode in @($e2e_selected | ForEach-Object { $_.Mode } | Select-Object -Unique))
        {
            Write-Host "Building the '$mode' fixture repositories..."
            $e2e_templates[$mode] = new-e2e-template -directory (Join-Path $e2e_temp_root "t-$mode") -mode $mode
        }

        # Keep up to $ThrottleLimit propagations running; check each scenario as soon as its last run
        # ends. A run that timed out ends its scenario: the next run would only time out as well.
        $pending = New-Object System.Collections.Queue
        foreach ($job in $e2e_jobs)
        {
            $pending.Enqueue($job)
        }
        while ($pending.Count -gt 0 -or $e2e_running.Count -gt 0)
        {
            while ($pending.Count -gt 0 -and $e2e_running.Count -lt $ThrottleLimit)
            {
                $job = $pending.Dequeue()
                $job['World'] = new-e2e-world -directory $job.Path -template $e2e_templates[$job.Scenario.Mode] -settings $job.Scenario.Settings -Interactive:([bool]$job.Scenario.Interactive)
                $job.World['Entry'] = copy-e2e-implementation -world $job.World -implementation $job.Implementation
                start-e2e-job-run $job
                Write-Host ("    started {0} ({1})" -f $job.Scenario.Name, $job.Implementation.Name)
                [void]$e2e_running.Add($job)
            }
            $finished = @($e2e_running | Where-Object { test-e2e-process-done $_.Started })
            if ($finished.Count -eq 0)
            {
                Start-Sleep -Milliseconds 500
            }
            else
            {
                foreach ($job in $finished)
                {
                    $run_result = complete-e2e-propagation -world $job.World -started $job.Started -run_index $job.RunIndex
                    [void]$job.RunResults.Add($run_result)
                    if ($job.RunIndex -lt $job.Scenario.Runs.Count -and -not $run_result.TimedOut)
                    {
                        start-e2e-job-run $job
                        Write-Host ("    started {0} ({1}) run {2}" -f $job.Scenario.Name, $job.Implementation.Name, $job.RunIndex)
                    }
                    else
                    {
                        $e2e_running.Remove($job)
                        complete-e2e-job $job
                    }
                }
            }
        }
    }
}
finally
{
    # Stopped early (e.g. Ctrl+C): end the propagations still running. Each has its own hidden
    # console, so nothing else would stop them.
    foreach ($job in @($e2e_running))
    {
        if ($job.Started -and -not $job.Started.Process.HasExited)
        {
            $kill = New-Object System.Diagnostics.ProcessStartInfo
            $kill.FileName = 'taskkill.exe'
            $kill.Arguments = "/PID $($job.Started.Process.Id) /T /F"
            $kill.UseShellExecute = $false
            $kill.CreateNoWindow = $true
            $kill.RedirectStandardOutput = $true
            $kill.RedirectStandardError = $true
            [void]([System.Diagnostics.Process]::Start($kill)).WaitForExit(30000)
        }
        else
        {
            # already finished
        }
    }
    Remove-Item -LiteralPath Env:GIT_CONFIG_NOSYSTEM, Env:GIT_CONFIG_GLOBAL, Env:GIT_AUTHOR_NAME, Env:GIT_AUTHOR_EMAIL, Env:GIT_COMMITTER_NAME, Env:GIT_COMMITTER_EMAIL -ErrorAction SilentlyContinue
    foreach ($name in $e2e_saved_environment.Keys)
    {
        Set-Item -LiteralPath "Env:$name" -Value $e2e_saved_environment[$name]
    }
}
if ($e2e_no_jobs)
{
    Remove-Item -LiteralPath $e2e_temp_root -Recurse -Force -ErrorAction SilentlyContinue
    exit 2
}
else
{
    # report below
}

$e2e_results = @($e2e_jobs | Where-Object { $_.Result } | ForEach-Object { $_.Result })
$e2e_failed = ($e2e_results.Count -ne $e2e_jobs.Count) -or (@($e2e_results | Where-Object { -not $_.Passed }).Count -gt 0)
Write-Host ''
Write-Host 'End-to-end results:'
foreach ($result in $e2e_results)
{
    $status = if ($result.Passed) { 'PASS' } else { 'FAIL' }
    Write-Host ("  {0,-38} {1,-12} {2}  {3,4}s" -f $result.Scenario, $result.Implementation, $status, $result.Seconds)
}
if ($e2e_failed)
{
    Write-Host "Some scenarios failed; their worlds are under $e2e_temp_root" -ForegroundColor Red
    exit 1
}
else
{
    if (-not $KeepWorlds)
    {
        Remove-Item -LiteralPath $e2e_temp_root -Recurse -Force -ErrorAction SilentlyContinue
    }
    else
    {
        Write-Host "Worlds kept under $e2e_temp_root"
    }
    Write-Host 'All end-to-end scenarios passed.' -ForegroundColor Green
    exit 0
}
