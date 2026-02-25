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

PS> .\propagate_updates.ps1 -azure_work_item 12345 -useCachedRepoOrder -root_list root1, root2, ...
# Uses cached repo order if root_list matches the cached root_list

.EXAMPLE

PS> .\propagate_updates.ps1 -Resume
# Resumes the most recent failed propagation run from the last failed repo
#>


param(
    [Parameter(Mandatory=$false)][string]$azure_token, # Personal Access Token for Azure DevOps (optional, WAM used if not provided)
    [Parameter(Mandatory=$false)][Int32]$azure_work_item, # Work item id to link to Azure PRs
    [switch]$useCachedRepoOrder, # use cached repo order if root_list matches
    [switch]$NoCloseFailedPr, # keep the PR open if it fails (default: close/abandon failed PRs)
    [switch]$Resume, # resume a previously failed propagation run
    [Parameter(Mandatory=$false)][string[]]$root_list # comma-separated list of URLs for repositories upto which updates must be propagated
)


# Source helper scripts
$helper_scripts = "$PSScriptRoot\helper_scripts"
. "$helper_scripts\check_powershell_version.ps1"
. "$helper_scripts\check_script_update.ps1"
. "$helper_scripts\install_az_cli.ps1"
. "$helper_scripts\install_gh_cli.ps1"
. "$helper_scripts\repo_order_cache.ps1"
. "$helper_scripts\status_tracking.ps1"
. "$helper_scripts\git_operations.ps1"
. "$helper_scripts\watch_azure_pr.ps1"
. "$helper_scripts\watch_github_pr.ps1"
. "$helper_scripts\azure_repo_ops.ps1"
. "$helper_scripts\github_repo_ops.ps1"
. "$helper_scripts\success_animation.ps1"
. "$helper_scripts\propagation_state.ps1"


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

    [string]$git_output = (update-local-repo $repo_name $new_branch_name)
    if($git_output.Contains("nothing to commit"))
    {
        Write-Host "Nothing to commit, skipping repo $repo_name"
        set-repo-status -repo_name $repo_name -status $script:STATUS_SKIPPED -message "No changes"
    }
    else
    {
        $repo_type = get-repo-type $repo_name
        $pr_url = $null
        if($repo_type -eq "github")
        {
            $pr_url = update-repo-github $repo_name $new_branch_name
            set-repo-status -repo_name $repo_name -status $script:STATUS_UPDATED -pr_url $pr_url
            update-fixed-commit $repo_name
        }
        elseif ($repo_type -eq "azure")
        {
            $pr_url = update-repo-azure $repo_name $new_branch_name
            set-repo-status -repo_name $repo_name -status $script:STATUS_UPDATED -pr_url $pr_url
            update-fixed-commit $repo_name
        }
        else
        {
            fail-with-status "Unable to update repository $repo_name. Only Github and Azure repositories are supported."
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

    # Check PowerShell version first
    check-powershell-version

    # Check for script updates before starting
    check-for-script-updates -script_root $PSScriptRoot

    check-az-cli-exists -pat_token $azure_token
    check-gh-cli-exists

    $repo_order = $null
    $repo_urls = $null
    $new_branch_name = $null

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
        $azure_work_item = $saved_state.azure_work_item
        $root_list = $saved_state.root_list

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

        # Show what was already done
        Write-Host "`nResumed propagation status:" -ForegroundColor Cyan
        show-propagation-status
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

        # Create a new directory for this update session
        $global:work_dir = Join-Path (Get-Location).Path $new_branch_name
        New-Item -ItemType Directory -Path $global:work_dir -Force | Out-Null
        Set-Location $global:work_dir
        Write-Host "Working directory: $global:work_dir"

        # build dependency graph (or use cache)
        $cached_data = $null

        if ($useCachedRepoOrder)
        {
            $cached_data = get-cached-repo-order -root_list $root_list
        }
        else
        {
            # will build fresh
        }

        if ($cached_data)
        {
            $repo_order = $cached_data.repo_order
            $repo_urls = $cached_data.repo_urls
            Write-Host "Using cached repo order"
            Set-Content -Path .\order.json -Value ($repo_order | ConvertTo-Json)
            # Clone repos that aren't already present using cached URLs
            Write-Host "Cloning repositories..."
            foreach ($repo_name in $repo_order)
            {
                if (-not (Test-Path -Path $repo_name))
                {
                    $repo_url = $repo_urls.$repo_name
                    if ($repo_url)
                    {
                        Write-Host "Cloning: $repo_name" -ForegroundColor Cyan
                        git clone $repo_url
                    }
                    else
                    {
                        Write-Host "Warning: No URL cached for $repo_name, skipping" -ForegroundColor Yellow
                    }
                }
                else
                {
                    # already present
                }
            }
            Write-Host "Done cloning repositories"
        }
        else
        {
            Write-Host "Building dependency graph..."
            .$helper_scripts\build_graph.ps1 -root_list $root_list
            if($LASTEXITCODE -ne 0)
            {
                fail-with-status "Could not build dependency graph for $root_list."
            }
            else
            {
                # graph built successfully
            }
            Write-Host "Done building dependency graph"
            # build_graph.ps1 sets the cache, so read from it
            $cached_data = get-cached-repo-order -root_list $root_list
            if (-not $cached_data)
            {
                fail-with-status "Failed to get cached repo order after building graph."
            }
            else
            {
                # cache retrieved
            }
            $repo_order = $cached_data.repo_order
            $repo_urls = $cached_data.repo_urls
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
    for($i = 0; $i -lt $repo_order.Length; $i++)
    {
        Write-Host "$($i+1). $($repo_order[$i])"
    }

    foreach ($repo in $repo_order)
    {
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

propagate-updates
