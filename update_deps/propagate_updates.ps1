# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS

Propagates dependency updates for git repositories.

.DESCRIPTION

Given a root repo, this script builds the dependency graph and propagates updates from the
lowest level up to the root repo by making PRs to each repo in bottom-up level-order.

By default, if a PR fails (e.g., checks fail), it is automatically closed/abandoned before
exiting. Use -NoCloseFailedPr to leave failed PRs open instead.

Interactive runs (the default) update one repo at a time and follow each PR with a live status
display. Azure DevOps authentication uses WAM (Web Account Manager) through the Azure CLI by
default on Windows, which provides SSO using your Windows login; a PAT can be provided instead.
GitHub authentication is handled via 'gh auth login'.

-Pipeline runs noninteractively in an Azure DevOps pipeline: Azure DevOps REST and git calls use
SYSTEM_ACCESSTOKEN, GitHub calls use GH_TOKEN, nothing prompts, the dependency graph is always
discovered live, and each repo's PR opens as soon as everything it depends on has merged.

.PARAMETER root_list

Comma-separated list of URLs of the repositories up to which updates must be propagated.

.PARAMETER azure_work_item

Work item id that is linked to PRs made to Azure repos.

.PARAMETER azure_token

(Optional, interactive only) Personal Access Token for Azure DevOps authentication. If not
provided, the AZURE_DEVOPS_EXT_PAT environment variable or WAM authentication is used. PAT must
have Code (Read & Write) and Work Items (Read & Write) permissions.

.PARAMETER poll_interval

(Optional) Seconds between PR status polls (default: 15; -Pipeline polls at most every 30 seconds).

.PARAMETER NoCloseFailedPr

(Optional) When set, disables the default behavior of automatically closing/abandoning the
PR that caused a failure.

.PARAMETER ForceBuildGraph

(Optional, interactive only) Rebuild the dependency graph even if known_graph.json matches.

.PARAMETER Resume

(Optional, interactive only) Resume a previously failed propagation run. Finds the most recent
work directory (new_deps_*) in the current folder, loads saved state (repo order, fixed commits,
branch name), and continues from the repo that failed. Repos that were already updated or skipped
are not re-processed.

.PARAMETER AutoFix

(Optional, interactive only) Use Copilot CLI to attempt to fix build failures.

.PARAMETER Pipeline

(Optional) Run noninteractively in an Azure DevOps pipeline. Requires the SYSTEM_ACCESSTOKEN and
GH_TOKEN environment variables. Cannot be combined with -azure_token, -ForceBuildGraph, -Resume,
or -AutoFix.

.INPUTS

ignores.json: list of repositories that must be ignored for updates.

.OUTPUTS

None. Exits with 0 when every repo was updated or skipped, non-zero otherwise.

.EXAMPLE

PS> .\propagate_updates.ps1 -azure_work_item 12345 -root_list root1, root2, ...

.EXAMPLE

PS> .\propagate_updates.ps1 -azure_token <your-pat-token> -azure_work_item 12345 -root_list root1, root2, ...

.EXAMPLE

PS> .\propagate_updates.ps1 -Resume
# Resumes the most recent failed propagation run from the last failed repo

.EXAMPLE

PS> .\propagate_updates.ps1 -Pipeline -azure_work_item 12345 -root_list root1, root2 -NoCloseFailedPr
# Runs noninteractively using SYSTEM_ACCESSTOKEN and GH_TOKEN
#>


param(
    [Parameter(Mandatory=$false)][string]$azure_token, # Personal Access Token for Azure DevOps (optional, WAM used if not provided)
    [Parameter(Mandatory=$false)][Int32]$azure_work_item, # Work item id to link to Azure PRs
    [Parameter(Mandatory=$false)][Int32]$poll_interval = 15, # Seconds between status polls during PR watch
    [switch]$NoCloseFailedPr, # keep the PR open if it fails (default: close/abandon failed PRs)
    [switch]$ForceBuildGraph, # force graph rebuild even if known graph matches
    [switch]$Resume, # resume a previously failed propagation run
    [switch]$AutoFix, # use Copilot CLI to auto-fix build failures
    [switch]$Pipeline, # run noninteractively in an Azure DevOps pipeline
    [Parameter(Mandatory=$false)][string[]]$root_list # comma-separated list of URLs for repositories upto which updates must be propagated
)

# Native commands report failures through exit codes, which this script checks. A caller's 'Stop'
# preference (the Azure Pipelines PowerShell task default) would otherwise turn git's progress
# output on stderr into terminating errors.
$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false

if ($Pipeline.IsPresent)
{
    $unsupported_parameters = @()
    if (-not [string]::IsNullOrWhiteSpace($azure_token)) { $unsupported_parameters += "-azure_token" }
    if ($ForceBuildGraph.IsPresent) { $unsupported_parameters += "-ForceBuildGraph" }
    if ($Resume.IsPresent) { $unsupported_parameters += "-Resume" }
    if ($AutoFix.IsPresent) { $unsupported_parameters += "-AutoFix" }
    if ($unsupported_parameters.Count -gt 0)
    {
        Write-Error "Pipeline mode does not support: $($unsupported_parameters -join ', ')."
        exit 1
    }
    else
    {
        # supported parameters only
    }
}
else
{
    # interactive run
}

$script:propagation_mode = if ($Pipeline.IsPresent) { 'pipeline' } else { 'interactive' }
$script:propagation_succeeded = $false

# Source helper scripts
. "$PSScriptRoot\helper_scripts\load_helpers.ps1"

# Build the resume command from the current invocation args
$resume_args = @()
if ($azure_token) { $resume_args += "-azure_token `"$azure_token`"" }
if ($azure_work_item) { $resume_args += "-azure_work_item $azure_work_item" }
if ($root_list) { $resume_args += "-root_list $($root_list -join ',')" }
if ($poll_interval -ne 15) { $resume_args += "-poll_interval $poll_interval" }
if ($NoCloseFailedPr) { $resume_args += "-NoCloseFailedPr" }
if ($AutoFix) { $resume_args += "-AutoFix" }
$global:resume_command = "$($MyInvocation.MyCommand.Path) $($resume_args -join ' ') -Resume"


# -Pipeline setup: credentials from the environment, nothing may prompt, self-test before any work.
function initialize-pipeline-run
{
    check-powershell-version
    Test-PipelineCredentials
    initialize-pipeline-environment
    ensure-gh-cli

    # Self-test: validate the GitHub token and Azure DevOps access before any work.
    Invoke-Preflight -root_list $root_list

    # Authenticate git pushes to github.com with the gh token. Without this, the branch push for any
    # GitHub repo fails with "could not read Username for 'https://github.com'". gh is confirmed
    # working by preflight; setup-git writes a credential helper into the isolated global git config.
    Write-Log INFO "Configuring git GitHub credential helper (gh auth setup-git)"
    $setup_git = Invoke-NativeWithRetry -File gh -Arguments @('auth', 'setup-git') -MaxAttempts 3 -TimeoutSec 120
    if ($setup_git.ExitCode -ne 0)
    {
        Write-Log WARN "gh auth setup-git returned non-zero; GitHub pushes may fail: $($setup_git.StdErr)"
    }
    else
    {
        # git can push to github.com
    }
}


# Interactive setup: tool installation and sign-in, prompting when needed.
function initialize-interactive-run
{
    # Check PowerShell version first
    check-powershell-version

    # Check for script updates before starting
    check-for-script-updates -script_root $PSScriptRoot

    initialize-interactive-azure-auth -pat_token $azure_token
    ensure-gh-cli
}


# iterate over all repos and update them
function propagate-updates
{
    # Save original directory to restore at exit (including on failure)
    $global:original_dir = (Get-Location).Path

    # Close failed PRs by default unless -NoCloseFailedPr is specified
    $global:close_failed_pr = -not $NoCloseFailedPr.IsPresent

    # Store poll interval for use by repo ops functions
    $global:poll_interval = $poll_interval

    # Store auto-fix flag for use by repo ops functions
    $global:auto_fix = $AutoFix.IsPresent

    # Store resume flag so update-repo knows whether to look for existing PRs
    $global:is_resume = $Resume.IsPresent

    $global:propagation_cancelled = $false

    $repo_order = $null
    $repo_urls = $null
    $repo_edges = $null
    $new_branch_name = $null

    # Store state params as globals so fail-with-status can save state before exiting
    $global:_state_repo_order = $null
    $global:_state_repo_urls = $null
    $global:_state_branch_name = $null
    $global:_state_root_list = $root_list
    $global:_state_azure_work_item = $azure_work_item

    if ($Pipeline.IsPresent)
    {
        Write-Log STEP "Dependency propagation starting"
        Write-Log INFO ("roots: {0}" -f ($root_list -join ', '))
        Write-Log INFO ("work item: {0}; poll interval: {1}s; close failed PR: {2}" -f $azure_work_item, $poll_interval, $global:close_failed_pr)
    }
    else
    {
        # interactive output starts with the tool checks
    }

    if (-not $Resume.IsPresent)
    {
        # Validate required parameters before any tool or network setup
        if (-not $azure_work_item)
        {
            fail-with-status "azure_work_item is required. Provide: -azure_work_item [id]"
        }
        elseif (-not $root_list)
        {
            fail-with-status "root_list is required. Provide: -root_list repo1, repo2, ..."
        }
        else
        {
            foreach ($root in $root_list)
            {
                if ($root -notmatch '^https?://')
                {
                    fail-with-status "Invalid URL in root_list: $root"
                }
                else
                {
                    # URL accepted
                }
            }
        }
    }
    else
    {
        # parameters come from the saved state
    }

    if ($Pipeline.IsPresent)
    {
        initialize-pipeline-run
    }
    else
    {
        initialize-interactive-run
    }

    if ($Resume.IsPresent)
    {
        # --- Resume path: load state from the most recent run ---
        Write-Host "`nResuming previous propagation run..." -ForegroundColor Cyan

        $state_path = find-latest-state-file
        if (-not $state_path)
        {
            fail-with-status "No previous propagation state found. Run without -Resume first."
        }
        else
        {
            # state file found
        }

        Write-Host "Loading state from: $state_path"
        $saved_state = load-propagation-state -state_path $state_path

        if (-not $saved_state)
        {
            fail-with-status "Failed to load propagation state from: $state_path"
        }
        else
        {
            # state loaded successfully
        }

        # Restore globals from saved state
        $new_branch_name = $saved_state.branch_name
        $repo_order = $saved_state.repo_order
        $repo_urls = $saved_state.repo_urls
        $global:fixed_commits = $saved_state.fixed_commits
        $global:work_dir = Split-Path $state_path -Parent

        # Update state globals for fail-with-status
        $global:_state_branch_name = $new_branch_name
        $global:_state_repo_order = $repo_order
        $global:_state_repo_urls = $repo_urls
        $global:_state_root_list = $saved_state.root_list
        $global:_state_azure_work_item = $saved_state.azure_work_item
        $azure_work_item = $saved_state.azure_work_item
        $root_list = $saved_state.root_list

        # Restore change descriptions for recursive bubbling on resume
        $global:repo_change_descriptions = $saved_state.change_descriptions

        # Validate that critical state was restored
        if (-not $global:fixed_commits -or $global:fixed_commits.Count -eq 0)
        {
            fail-with-status "State file is missing fixed_commits. Cannot resume without commit information."
        }
        else
        {
            # fixed_commits restored successfully
        }

        Test-AdoAccess -root_list $root_list

        Set-Location $global:work_dir
        Write-Host "Work directory: $global:work_dir"
        Write-Host "Branch name: $new_branch_name"

        # Restore repo statuses (updated/skipped stay, failed resets to pending)
        restore-repo-status -repos $repo_order -saved_statuses $saved_state.repo_statuses

        # Check if the previous run already completed successfully
        $pending_count = @($repo_order | Where-Object {
            $global:repo_status[$_].Status -ne "updated" -and $global:repo_status[$_].Status -ne "skipped"
        }).Count
        if ($pending_count -eq 0)
        {
            Write-Host "`nThe previous propagation run already completed successfully. Nothing to resume." -ForegroundColor Green
            Write-Host "To start a new propagation, run the script without -Resume." -ForegroundColor Cyan
            restore-original-directory
            $script:propagation_succeeded = $true
            return
        }
        else
        {
            # there are repos to process
        }

        # Show what was already done
        Write-Host "`nResumed propagation status:" -ForegroundColor Cyan
        [void](show-propagation-status)
    }
    else
    {
        # --- Normal path: build graph, clone, snapshot ---
        if (-not $Pipeline.IsPresent)
        {
            # -Pipeline checked this in its preflight
            Test-AdoAccess -root_list $root_list
        }
        else
        {
            # already validated
        }

        # Generate branch name with timestamp
        $new_branch_name = "new_deps_" + (Get-Date -Format "yyyyMMddHHmmss")
        Write-Log INFO "New branch name: $new_branch_name"

        # Update state globals for fail-with-status
        $global:_state_branch_name = $new_branch_name

        # Create a new directory for this update session
        $global:work_dir = Join-Path (Get-Location).Path $new_branch_name
        New-Item -ItemType Directory -Path $global:work_dir -Force | Out-Null
        Set-Location $global:work_dir
        Write-Log INFO "Working directory: $global:work_dir"

        # build dependency graph
        Write-Log STEP "Building dependency graph"
        $graph = build-dependency-graph -root_list $root_list -ForceBuildGraph:$ForceBuildGraph -NoKnownGraph:$Pipeline
        $repo_order = $graph.repo_order
        $repo_urls = $graph.repo_urls
        $repo_edges = $graph.repo_edges
        if (-not $repo_order -or $repo_order.Count -eq 0)
        {
            fail-with-status "Could not build dependency graph for $($root_list -join ', ')."
        }
        else
        {
            Write-Log INFO "Dependency graph built ($($repo_order.Count) repos)"
        }

        # Update state globals for fail-with-status
        $global:_state_repo_order = $repo_order
        $global:_state_repo_urls = $repo_urls

        if ($Pipeline.IsPresent)
        {
            # Now that the graph is known, validate GitHub write access (SSO + push) to the discovered
            # github.com repos before opening any PRs, so a non-authorized token fails fast.
            Test-GitHubRepoAccess -repo_urls @($repo_urls.Values)
        }
        else
        {
            # interactive pushes use the signed-in user's own credentials
        }

        # Clone any repos that aren't already present (graph discovery clones them shallowly; the
        # known graph path only clones roots)
        Write-Log STEP "Ensuring all repositories are cloned"
        Set-Location $global:work_dir
        foreach ($repo_name in $repo_order)
        {
            if (-not (Test-Path -Path $repo_name))
            {
                if ($repo_urls.ContainsKey($repo_name))
                {
                    clone-repo-with-retry -repo_url $repo_urls[$repo_name] -target_dir $repo_name
                }
                else
                {
                    Write-Log WARN "No URL for $repo_name; skipping clone"
                }
            }
            else
            {
                # already cloned
            }
        }

        # Initialize status tracking
        initialize-repo-status -repos $repo_order

        # Snapshot master HEAD commits for all repos before starting updates.
        # This prevents external changes from affecting propagation. After each
        # repo's PR merges, its entry is updated via update-fixed-commit so that
        # downstream repos pick up the new commit created by propagation.
        Write-Log STEP "Snapshotting master commits for all repos"
        Set-Location $global:work_dir
        $global:fixed_commits = snapshot-repo-commits -repo_order $repo_order
        Write-Log INFO "Fixed commits captured for $($global:fixed_commits.Count) repos"
    }

    if ($Pipeline.IsPresent)
    {
        Write-Log INFO "Dependencies (a repo's PR opens as soon as all of these are propagated):"
        foreach ($repo_name in $repo_order)
        {
            $deps = @($repo_edges[$repo_name])
            Write-Log INFO ("  {0} <- {1}" -f $repo_name, $(if ($deps.Count -gt 0) { $deps -join ', ' } else { '(none)' }))
        }

        update-repos-greedily -repo_order $repo_order -repo_edges $repo_edges -new_branch_name $new_branch_name
    }
    else
    {
        Write-Host "Updating repositories in the following order: "
        for($i = 0; $i -lt $repo_order.Count; $i++)
        {
            Write-Host "$($i+1). $($repo_order[$i])"
        }

        # Ctrl+C handling: works during our own sleep intervals (wait-or-cancel).
        # During external commands (az, gh, git), Ctrl+C terminates immediately.
        # State is saved after each repo, so use -Resume to continue.
        [Console]::TreatControlCAsInput = $true

        try
        {
            foreach ($repo in $repo_order)
            {
                # Check for Ctrl+C between repos
                if ($global:propagation_cancelled)
                {
                    break
                }
                else
                {
                    # continue propagation
                }

                # Skip repos that were already updated or skipped (for resume)
                if ($global:repo_status.ContainsKey($repo) -and
                    ($global:repo_status[$repo].Status -eq "updated" -or $global:repo_status[$repo].Status -eq "skipped"))
                {
                    Write-Host "`nSkipping $repo (already $($global:repo_status[$repo].Status))" -ForegroundColor Gray
                }
                else
                {
                    update-repo $repo $new_branch_name
                }

                # Save state after each repo so the run can be resumed
                save-propagation-state -branch_name $new_branch_name -repo_order $repo_order -repo_urls $repo_urls -root_list $root_list -azure_work_item $azure_work_item
            }
        }
        finally
        {
            # Restore normal Ctrl+C behavior
            [Console]::TreatControlCAsInput = $false
        }

        if ($global:propagation_cancelled)
        {
            [void](show-propagation-status -Final)
            restore-original-directory
            Write-Host "`nPropagation cancelled by user." -ForegroundColor Yellow
            Write-Host "To resume from where it stopped, run:" -ForegroundColor Cyan
            Write-Host "  $global:resume_command" -ForegroundColor White
            exit 1
        }
        else
        {
            # every repo was processed
        }
    }

    # Show final status and check if all succeeded
    $success = show-propagation-status -Final

    # Warn about any repos with newer commits that were not propagated
    show-skipped-commits-summary

    # Restore original directory
    restore-original-directory

    if ($success)
    {
        $script:propagation_succeeded = $true
        if ($Pipeline.IsPresent)
        {
            Write-Log STEP "Dependency propagation completed successfully"
        }
        else
        {
            play-success-animation
        }
    }
    elseif ($Pipeline.IsPresent)
    {
        # Do not exit green when repos are still pending or failed.
        fail-with-status "Dependency propagation finished with failures or pending repos."
    }
    else
    {
        Write-Host "Done updating repos (with some failures)" -ForegroundColor Yellow
    }
}

if ($Pipeline.IsPresent)
{
    try
    {
        propagate-updates
    }
    finally
    {
        remove-pipeline-environment
    }
}
else
{
    # Not piped: native sign-in prompts (gh auth login, az login) need the console.
    propagate-updates
}

if ($script:propagation_succeeded)
{
    exit 0
}
else
{
    exit 1
}
