# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Per-repo update orchestration for propagate_updates.ps1.
# Resolves existing PRs (resume), runs local updates (fresh), and monitors PR completion.
# Dependencies: dot-sourced by propagate_updates.ps1 which loads all helper scripts.


# Resolve an existing PR URL for a repo — from saved state or by querying the remote.
# Returns the PR URL or $null.
function resolve-existing-pr
{
    param(
        [string] $repo_name,
        [string] $new_branch_name
    )
    $result = $null

    # Check saved PrUrl from state file
    if ($global:repo_status.ContainsKey($repo_name) -and $global:repo_status[$repo_name].PrUrl)
    {
        $result = $global:repo_status[$repo_name].PrUrl
        Write-Host "Found existing PR from previous run: $result" -ForegroundColor Cyan
    }
    else
    {
        # No saved PrUrl — check remote for an active PR on this branch
        Write-Host "  Checking for active PR on branch $new_branch_name..." -ForegroundColor Gray
        $repo_type = get-repo-type $repo_name
        if ($repo_type -eq "azure")
        {
            $result = find-active-azure-pr -repo_name $repo_name -branch_name $new_branch_name
        }
        elseif ($repo_type -eq "github")
        {
            $result = find-active-github-pr -repo_name $repo_name -branch_name $new_branch_name
        }
        else
        {
            # unknown repo type
        }

        if ($result)
        {
            Write-Host "Discovered active PR: $result" -ForegroundColor Cyan
        }
        else
        {
            # no existing PR found
        }
    }

    return $result
}


# Check if a PR is already merged/completed. Returns $true if merged.
function check-pr-merged
{
    param(
        [string] $pr_url,
        [string] $repo_name,
        [string] $repo_type
    )
    $result = $false

    if ($repo_type -eq "azure")
    {
        $result = check-azure-pr-completed -pr_url $pr_url -repo_name $repo_name
    }
    elseif ($repo_type -eq "github")
    {
        $result = check-github-pr-merged -pr_url $pr_url -repo_name $repo_name
    }
    else
    {
        # unknown repo type
    }

    return $result
}


# Monitor an existing PR until completion.
function monitor-pr
{
    param(
        [string] $pr_url,
        [string] $repo_name,
        [string] $repo_type
    )

    if ($repo_type -eq "github")
    {
        monitor-github-pr -repo_name $repo_name
    }
    elseif ($repo_type -eq "azure")
    {
        monitor-azure-pr -pr_url $pr_url -repo_name $repo_name
    }
    else
    {
        fail-with-status "Unable to update repository $repo_name. Only Github and Azure repositories are supported."
    }
}


# Update dependencies for a given repo.
# Handles resume (existing PR) and fresh run (create new PR) paths.
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

    # --- Resolve existing PR URL (resume scenario) ---
    # Do this BEFORE update-local-repo to avoid pushing new commits to an existing PR.
    $existing_pr_url = resolve-existing-pr -repo_name $repo_name -new_branch_name $new_branch_name
    $repo_type = get-repo-type $repo_name

    if ($existing_pr_url)
    {
        # Check if the PR is already merged/completed
        $already_merged = check-pr-merged -pr_url $existing_pr_url -repo_name $repo_name -repo_type $repo_type

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
            set-repo-status -repo_name $repo_name -status $script:STATUS_IN_PROGRESS -pr_url $existing_pr_url
            monitor-pr -pr_url $existing_pr_url -repo_name $repo_name -repo_type $repo_type
            set-repo-status -repo_name $repo_name -status $script:STATUS_UPDATED -pr_url $existing_pr_url
            update-fixed-commit $repo_name
        }
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
    Write-Host "Done updating repo $repo_name"
}
