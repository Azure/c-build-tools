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

Authentication for Azure DevOps uses WAM (Web Account Manager) by default on Windows, which
provides SSO using your Windows login. If WAM is not available or fails, you can provide a
PAT token as a fallback. GitHub authentication is handled via 'gh auth login'.

.PARAMETER root_list

Comma-separated list of URLs of the repositories up to which updates must be propagated.

.PARAMETER azure_work_item

Work item id that is linked to PRs made to Azure repos.

.PARAMETER azure_token

(Optional) Personal Access Token for Azure DevOps authentication. If not provided, WAM
authentication will be used. PAT must have Code (Read & Write) and Work Items (Read) permissions.

.PARAMETER NoCloseFailedPr

(Optional) When set, disables the default behavior of automatically closing/abandoning the
PR that caused a failure. By default, failed PRs are closed (GitHub via 'gh pr close',
Azure via 'az repos pr update --status abandoned').

.PARAMETER Resume

(Optional) Resume a previously failed propagation run. Finds the most recent work directory
(new_deps_*) in the current folder, loads saved state (repo order, fixed commits, branch name),
and continues from the repo that failed. Repos that were already updated or skipped are not
re-processed.

.INPUTS

ignore.json: list of repositories that must be ignored for updates.

.OUTPUTS

None.

.EXAMPLE

PS> .\propagate_updates.ps1 -azure_work_item 12345 -root_list root1, root2, ...

.EXAMPLE

PS> .\propagate_updates.ps1 -azure_token <your-pat-token> -azure_work_item 12345 -root_list root1, root2, ...

.EXAMPLE

PS> .\propagate_updates.ps1 -Resume
# Resumes the most recent failed propagation run from the last failed repo
#>


param(
    [Parameter(Mandatory=$false)][string]$azure_token, # Personal Access Token for Azure DevOps (optional, WAM used if not provided)
    [Parameter(Mandatory=$false)][Int32]$azure_work_item, # Work item id to link to Azure PRs
    [Parameter(Mandatory=$false)][Int32]$poll_interval = 15, # Seconds between status polls during PR watch
    [switch]$NoCloseFailedPr, # keep the PR open if it fails (default: close/abandon failed PRs)
    [switch]$ForceBuildGraph, # force graph rebuild even if known graph matches
    [switch]$Resume, # resume a previously failed propagation run
    [Parameter(Mandatory=$false)][string[]]$root_list # comma-separated list of URLs for repositories upto which updates must be propagated
)


# Source helper scripts
$helper_scripts = "$PSScriptRoot\helper_scripts"
. "$helper_scripts\check_powershell_version.ps1"
. "$helper_scripts\check_script_update.ps1"
. "$helper_scripts\install_az_cli.ps1"
. "$helper_scripts\install_gh_cli.ps1"
. "$helper_scripts\status_tracking.ps1"
. "$helper_scripts\git_operations.ps1"
. "$helper_scripts\watch_azure_pr.ps1"
. "$helper_scripts\watch_github_pr.ps1"
. "$helper_scripts\azure_repo_ops.ps1"
. "$helper_scripts\github_repo_ops.ps1"
. "$helper_scripts\success_animation.ps1"
. "$helper_scripts\propagation_state.ps1"


# Check if resuming with a PR would regress any submodule compared to current master.
# Returns $true if any submodule on master is already ahead of the fixed commit.
function check-pr-would-regress
{
    param(
        [string] $repo_name
    )
    $would_regress = $false

    Push-Location $repo_name

    # Fetch latest master
    git fetch origin master 2>$null

    if (Test-Path ".gitmodules")
    {
        $submodule_lines = git config --file .gitmodules --get-regexp '\.path$'
        if ($submodule_lines)
        {
            foreach ($line in $submodule_lines)
            {
                $sub_path = ($line -split "\s+", 2)[1]
                $sub_repo_name = Split-Path $sub_path -Leaf

                if ($global:fixed_commits -and $global:fixed_commits.ContainsKey($sub_repo_name))
                {
                    $target_sha = $global:fixed_commits[$sub_repo_name]

                    # Get what master currently has for this submodule
                    $master_sub_sha = git ls-tree origin/master -- $sub_path 2>$null
                    if ($master_sub_sha -match '([0-9a-f]{40})')
                    {
                        $current_sha = $matches[1]

                        if ($current_sha -ne $target_sha)
                        {
                            # Check if target is ancestor of current (current is ahead)
                            Push-Location $sub_path
                            git fetch origin 2>$null
                            git merge-base --is-ancestor $target_sha $current_sha 2>$null
                            if ($LASTEXITCODE -eq 0)
                            {
                                Write-Host "  REGRESSION: $sub_repo_name on master is at $($current_sha.Substring(0, 8)) which is AHEAD of fixed commit $($target_sha.Substring(0, 8))" -ForegroundColor Red
                                Write-Host "  Someone has already updated this repo with newer submodule versions." -ForegroundColor Red
                                $would_regress = $true
                            }
                            else
                            {
                                # target is not ancestor of current — not a regression
                            }
                            Pop-Location
                        }
                        else
                        {
                            # same SHA, no issue
                        }
                    }
                    else
                    {
                        # couldn't parse submodule SHA from master
                    }
                }
                else
                {
                    # no fixed commit for this submodule
                }
            }
        }
        else
        {
            # no submodule lines
        }
    }
    else
    {
        # no .gitmodules
    }

    Pop-Location
    return $would_regress
}


# update dependencies for given repo
function update-repo
{
    param(
        [string] $repo_name,
        [string] $new_branch_name
    )
    Write-Host "`n`nUpdating repo $repo_name"
    set-repo-status -repo_name $repo_name -status $script:STATUS_IN_PROGRESS
    $global:current_repo = $repo_name

    # Ensure we're in the work directory
    Set-Location $global:work_dir

    # Check if we already have a PR URL from a previous run (resume scenario)
    # Do this BEFORE update-local-repo to avoid pushing new commits to an existing PR
    $existing_pr_url = $null
    if ($global:repo_status.ContainsKey($repo_name))
    {
        $existing_pr_url = $global:repo_status[$repo_name].PrUrl
    }
    else
    {
        # no existing status
    }

    if ($existing_pr_url)
    {
        Write-Host "Found existing PR from previous run: $existing_pr_url" -ForegroundColor Cyan
        $repo_type = get-repo-type $repo_name

        # Check if the PR is already merged/completed
        $already_merged = $false
        if ($repo_type -eq "azure" -and $existing_pr_url -match "/pullrequest/(\d+)")
        {
            $pr_id = [int]$matches[1]
            $azure_info = get-azure-org-project $repo_name
            $pr_check = az repos pr show --id $pr_id --organization $azure_info.Organization --output json 2>&1
            if ($LASTEXITCODE -eq 0)
            {
                $pr_info = $pr_check | ConvertFrom-Json
                if ($pr_info.status -eq "completed")
                {
                    $already_merged = $true
                }
                else
                {
                    # PR still active
                }
            }
            else
            {
                # couldn't check PR status
            }
        }
        elseif ($repo_type -eq "github")
        {
            Push-Location $repo_name
            $pr_check = gh pr view $existing_pr_url --json state 2>&1
            if ($LASTEXITCODE -eq 0)
            {
                $pr_info = $pr_check | ConvertFrom-Json
                if ($pr_info.state -eq "MERGED")
                {
                    $already_merged = $true
                }
                else
                {
                    # PR still active
                }
            }
            else
            {
                # couldn't check PR status
            }
            Pop-Location
        }
        else
        {
            # unknown repo type
        }

        if ($already_merged)
        {
            Write-Host "PR already merged, skipping repo" -ForegroundColor Green
            set-repo-status -repo_name $repo_name -status $script:STATUS_UPDATED -pr_url $existing_pr_url
            update-fixed-commit $repo_name
        }
        else
        {
            # PR is still active — check for regression before monitoring
            $would_regress = check-pr-would-regress -repo_name $repo_name
            if ($would_regress)
            {
                fail-with-status "PR for $repo_name would regress submodules. Someone has already updated this repo with newer versions. Abandon the PR and start a new propagation."
            }
            else
            {
                # no regression, safe to monitor
            }

            Write-Host "Monitoring existing PR..."
            $pr_url = $existing_pr_url
            if ($repo_type -eq "github")
            {
                Push-Location $repo_name
                $watch_result = watch-github-pr-checks -poll_interval $global:poll_interval -timeout 120 -OnIteration { [void](show-propagation-status) }
                if (-not $watch_result.Success)
                {
                    fail-with-status "PR checks failed for repo ${repo_name}: $($watch_result.Message)"
                }
                else
                {
                    Write-Host "PR checks passed" -ForegroundColor Green
                }
                Pop-Location
            }
            elseif ($repo_type -eq "azure")
            {
                # Extract PR ID and org from the saved URL
                $azure_info = get-azure-org-project $repo_name
                if ($existing_pr_url -match "/pullrequest/(\d+)")
                {
                    $pr_id = [int]$matches[1]
                    wait-until-complete-azure $pr_id $azure_info.Organization $repo_name
                }
                else
                {
                    fail-with-status "Could not parse PR ID from URL: $existing_pr_url"
                }
            }
            else
            {
                fail-with-status "Unable to update repository $repo_name. Only Github and Azure repositories are supported."
            }
            set-repo-status -repo_name $repo_name -status $script:STATUS_UPDATED -pr_url $pr_url
            update-fixed-commit $repo_name
        }
    }
    else
    {
        # No saved PR URL — check if there's an active PR for this branch on the remote
        # (handles case where state file was saved before PrUrl was set)
        Write-Host "  Checking for active PR on branch $new_branch_name..." -ForegroundColor Gray
        $repo_type = get-repo-type $repo_name
        $discovered_pr_url = $null

        if ($repo_type -eq "azure")
        {
            $azure_info = get-azure-org-project $repo_name
            $org = $azure_info.Organization
            $project = $azure_info.Project
            Write-Host "  Checking for active PR on branch..." -ForegroundColor Gray
            $pr_list_output = az repos pr list `
                --repository $repo_name `
                --source-branch $new_branch_name `
                --target-branch master `
                --status active `
                --organization $org `
                --project $project `
                --output json 2>$null
            if ($LASTEXITCODE -eq 0 -and $pr_list_output)
            {
                $prs = @($pr_list_output | ConvertFrom-Json)
                if ($prs.Count -gt 0)
                {
                    $pr_id = $prs[0].pullRequestId
                    # az repos pr list doesn't populate repository.webUrl,
                    # so construct the URL from org/project/repo
                    $discovered_pr_url = "$org/$project/_git/$repo_name/pullrequest/$pr_id"
                }
                else
                {
                    # no active PRs for this branch
                }
            }
            else
            {
                Write-Host "  PR list query failed or returned empty" -ForegroundColor Yellow
            }
        }
        elseif ($repo_type -eq "github")
        {
            Push-Location $repo_name
            $pr_check = gh pr list --head $new_branch_name --state open --json url --jq '.[0].url' 2>$null
            if ($LASTEXITCODE -eq 0 -and $pr_check)
            {
                $discovered_pr_url = $pr_check.Trim()
            }
            else
            {
                # no active PR for this branch
            }
            Pop-Location
        }
        else
        {
            # unknown repo type
        }

        if ($discovered_pr_url)
        {
            Write-Host "Discovered active PR for branch $new_branch_name`: $discovered_pr_url" -ForegroundColor Cyan

            # Check for regression before monitoring
            $would_regress = check-pr-would-regress -repo_name $repo_name
            if ($would_regress)
            {
                fail-with-status "PR for $repo_name would regress submodules. Someone has already updated this repo with newer versions. Abandon the PR and start a new propagation."
            }
            else
            {
                # no regression, safe to monitor
            }

            Write-Host "Monitoring existing PR..."
            set-repo-status -repo_name $repo_name -status $script:STATUS_IN_PROGRESS -pr_url $discovered_pr_url

            if ($repo_type -eq "github")
            {
                Push-Location $repo_name
                $watch_result = watch-github-pr-checks -poll_interval $global:poll_interval -timeout 120 -OnIteration { [void](show-propagation-status) }
                if (-not $watch_result.Success)
                {
                    fail-with-status "PR checks failed for repo ${repo_name}: $($watch_result.Message)"
                }
                else
                {
                    Write-Host "PR checks passed" -ForegroundColor Green
                }
                Pop-Location
            }
            elseif ($repo_type -eq "azure")
            {
                if ($discovered_pr_url -match "/pullrequest/(\d+)")
                {
                    $pr_id = [int]$matches[1]
                    wait-until-complete-azure $pr_id $azure_info.Organization $repo_name
                }
                else
                {
                    fail-with-status "Could not parse PR ID from URL: $discovered_pr_url"
                }
            }
            else
            {
                # shouldn't reach here
            }
            set-repo-status -repo_name $repo_name -status $script:STATUS_UPDATED -pr_url $discovered_pr_url
            update-fixed-commit $repo_name
        }
        else
        {
            # No existing PR — do the full update-local-repo + create PR flow
            $update_result = (update-local-repo $repo_name $new_branch_name)
            [string]$git_output = $update_result.GitOutput
            $description = $update_result.Description
            if($git_output.Contains("nothing to commit"))
            {
                Write-Host "Nothing to commit, skipping repo $repo_name"
                set-repo-status -repo_name $repo_name -status $script:STATUS_SKIPPED -message "No changes"
            }
            else
            {
                if ($repo_type -eq "github")
                {
                    $pr_url = update-repo-github $repo_name $new_branch_name $description
                    set-repo-status -repo_name $repo_name -status $script:STATUS_UPDATED -pr_url $pr_url
                    update-fixed-commit $repo_name
                }
                elseif ($repo_type -eq "azure")
                {
                    $pr_url = update-repo-azure $repo_name $new_branch_name $description
                    set-repo-status -repo_name $repo_name -status $script:STATUS_UPDATED -pr_url $pr_url
                    update-fixed-commit $repo_name
                }
                else
                {
                    fail-with-status "Unable to update repository $repo_name. Only Github and Azure repositories are supported."
                }
            }
        }
    }
    Write-Host "Done updating repo $repo_name"
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

    # Check PowerShell version first
    check-powershell-version

    # Check for script updates before starting
    check-for-script-updates -script_root $PSScriptRoot

    check-az-cli-exists -pat_token $azure_token
    check-gh-cli-exists

    $repo_order = $null
    $repo_urls = $null
    $new_branch_name = $null

    # Store state params as globals so fail-with-status can save state before exiting
    $global:_state_repo_order = $null
    $global:_state_repo_urls = $null
    $global:_state_branch_name = $null
    $global:_state_root_list = $root_list
    $global:_state_azure_work_item = $azure_work_item

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

        Set-Location $global:work_dir
        Write-Host "Work directory: $global:work_dir"
        Write-Host "Branch name: $new_branch_name"

        # Restore repo statuses (updated/skipped stay, failed resets to pending)
        restore-repo-status -repos $repo_order -saved_statuses $saved_state.repo_statuses

        # Check if the previous run already completed successfully
        $pending_count = ($repo_order | Where-Object {
            $global:repo_status[$_].Status -ne "updated" -and $global:repo_status[$_].Status -ne "skipped"
        }).Count
        if ($pending_count -eq 0)
        {
            Write-Host "`nThe previous propagation run already completed successfully. Nothing to resume." -ForegroundColor Green
            Write-Host "To start a new propagation, run the script without -Resume." -ForegroundColor Cyan
            restore-original-directory
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
        # --- Normal path: validate params, build graph, snapshot ---

        # Validate required parameters for normal (non-resume) runs
        if (-not $azure_work_item)
        {
            fail-with-status "azure_work_item is required. Provide: -azure_work_item [id]"
        }
        else
        {
            # azure_work_item provided
        }
        if (-not $root_list)
        {
            fail-with-status "root_list is required. Provide: -root_list repo1, repo2, ..."
        }
        else
        {
            # root_list provided
        }

        # Generate branch name with timestamp
        $new_branch_name = "new_deps_" + (Get-Date -Format "yyyyMMddHHmmss")
        Write-Host "New branch name: $new_branch_name"

        # Update state globals for fail-with-status
        $global:_state_branch_name = $new_branch_name

        # Create a new directory for this update session
        $global:work_dir = Join-Path (Get-Location).Path $new_branch_name
        New-Item -ItemType Directory -Path $global:work_dir -Force | Out-Null
        Set-Location $global:work_dir
        Write-Host "Working directory: $global:work_dir"

        # build dependency graph
        Write-Host "Building dependency graph..."
        $build_graph_args = @{ root_list = $root_list }
        if ($ForceBuildGraph) { $build_graph_args['ForceBuildGraph'] = $true }
        . "$helper_scripts\build_graph.ps1" @build_graph_args
        if (-not $repo_order -or $repo_order.Count -eq 0)
        {
            fail-with-status "Could not build dependency graph for $root_list."
        }
        else
        {
            # graph built successfully
        }
        Write-Host "Done building dependency graph"

        # Update state globals for fail-with-status
        $global:_state_repo_order = $repo_order
        $global:_state_repo_urls = $repo_urls

        # Clone any repos that aren't already present (known graph path only clones roots)
        Write-Host "Ensuring all repositories are cloned..."
        Set-Location $global:work_dir
        foreach ($repo_name in $repo_order)
        {
            if (-not (Test-Path -Path $repo_name))
            {
                if ($repo_urls.ContainsKey($repo_name))
                {
                    Write-Host "Cloning: $repo_name" -ForegroundColor Cyan
                    git clone $repo_urls[$repo_name]
                }
                else
                {
                    Write-Host "Warning: No URL for $repo_name, skipping clone" -ForegroundColor Yellow
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
        Write-Host "`nSnapshotting master commits for all repos..."
        Set-Location $global:work_dir
        $global:fixed_commits = snapshot-repo-commits -repo_order $repo_order
        Write-Host "Fixed commits captured for $($global:fixed_commits.Count) repos`n"
    }

    Write-Host "Updating repositories in the following order: "
    for($i = 0; $i -lt $repo_order.Count; $i++)
    {
        Write-Host "$($i+1). $($repo_order[$i])"
    }

    # Ctrl+C handling: works during our own sleep intervals (wait-or-cancel).
    # During external commands (az, gh, git), Ctrl+C terminates immediately.
    # State is saved after each repo, so use -Resume to continue.
    $global:propagation_cancelled = $false
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
        exit 1
    }
    else
    {
        # Show final status and check if all succeeded
        $success = show-propagation-status -Final

        # Warn about any repos with newer commits that were not propagated
        show-skipped-commits-summary

        if ($success)
        {
            play-success-animation
        }
        else
        {
            Write-Host "Done updating repos (with some failures)" -ForegroundColor Yellow
        }

        # Restore original directory
        restore-original-directory
    }
}

propagate-updates
