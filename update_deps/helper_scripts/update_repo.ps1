# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Per-repo update orchestration for propagate_updates.ps1.
#   Shared: create-repo-pr updates a repo's submodules and opens an armed PR.
#   Interactive (update-repo): resolves existing PRs on -Resume, then follows each PR with the rich
#   watchers (AutoFix, Ctrl+C prompt) before moving to the next repo.
#   Pipeline (update-repos-greedily): opens each repo's PR as soon as every repo it depends on is
#   propagated and polls all open PRs together, so independent dependency chains never wait for
#   each other.


# --- Shared -------------------------------------------------------------------------------------

# Mark a repo as the one being updated and move to the work directory.
function start-repo-update
{
    param(
        [string] $repo_name
    )
    Write-Log STEP "Updating repo $repo_name"
    set-repo-status -repo_name $repo_name -status $script:STATUS_IN_PROGRESS
    $global:current_repo = $repo_name
    Set-Location $global:work_dir
}

# Update one repo's submodules to the snapshotted commits and, if anything changed, create and arm
# its PR WITHOUT waiting for it. Returns a PR descriptor (@{ Repo; Type; PrUrl; ... }) or $null if
# the repo had no changes (skipped).
function create-repo-pr
{
    param(
        [string] $repo_name,
        [string] $new_branch_name
    )
    $repo_type = get-repo-type $repo_name
    $update_result = update-local-repo $repo_name $new_branch_name

    if (-not $update_result.HasChanges)
    {
        Write-Log INFO "Nothing to commit; skipping repo $repo_name"
        set-repo-status -repo_name $repo_name -status $script:STATUS_SKIPPED -message "No changes"
        return $null
    }
    elseif ($repo_type -eq "github")
    {
        return (create-pr-github-armed $repo_name $new_branch_name $update_result.Description)
    }
    elseif ($repo_type -eq "azure")
    {
        return (create-pr-azure-armed $repo_name $new_branch_name $update_result.Description)
    }
    else
    {
        fail-with-status "Unable to update repository $repo_name. Only GitHub and Azure repositories are supported."
    }
}

# Record a merged PR: mark the repo updated and advance its fixed commit so that the repos depending
# on it pin the merged commit.
function complete-repo-update
{
    param(
        [string] $repo_name,
        [string] $pr_url
    )
    set-repo-status -repo_name $repo_name -status $script:STATUS_UPDATED -pr_url $pr_url
    update-fixed-commit $repo_name
    Write-Log INFO "Done updating repo $repo_name"
}


# --- Interactive --------------------------------------------------------------------------------

# Resolve an existing PR URL for a repo - from saved state or by querying the remote.
# Always checks the remote first for an active PR on the branch (the latest one),
# then falls back to the saved PrUrl if no active PR exists.
# Returns the PR URL or $null.
function resolve-existing-pr
{
    param(
        [string] $repo_name,
        [string] $new_branch_name
    )
    $result = $null

    # Always check remote first - there may be a newer PR than what's saved
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
        Write-Host "Found active PR on branch: $result" -ForegroundColor Cyan
    }
    else
    {
        # No active PR on remote - check saved PrUrl (may be closed/abandoned)
        if ($global:repo_status.ContainsKey($repo_name) -and $global:repo_status[$repo_name].PrUrl)
        {
            $result = $global:repo_status[$repo_name].PrUrl
            Write-Host "Found saved PR from previous run: $result" -ForegroundColor Cyan
        }
        else
        {
            # no existing PR found
        }
    }

    return $result
}


# Get the disposition of a PR: "merged", "abandoned", or "active".
function get-pr-disposition
{
    param(
        [string] $pr_url,
        [string] $repo_name,
        [string] $repo_type
    )
    $result = "active"

    if ($repo_type -eq "azure")
    {
        $status = get-azure-pr-status -pr_url $pr_url -repo_name $repo_name
        if ($status -eq "completed")
        {
            $result = "merged"
        }
        elseif ($status -eq "abandoned")
        {
            $result = "abandoned"
        }
        else
        {
            $result = "active"
        }
    }
    elseif ($repo_type -eq "github")
    {
        $status = get-github-pr-status -pr_url $pr_url
        if ($status -eq "MERGED")
        {
            $result = "merged"
        }
        elseif ($status -eq "CLOSED")
        {
            $result = "abandoned"
        }
        else
        {
            $result = "active"
        }
    }
    else
    {
        # unknown repo type
    }

    return $result
}


# Check if a PR's BUILD checks have already failed (complete + unsuccessful).
# Only considers Build-type checks - Status, Required reviewers, etc. are not
# fixable by autofix and should not trigger it.
# Returns a hashtable with AlreadyFailed ($true/$false) and Message.
function test-pr-checks-already-failed
{
    param(
        [string] $pr_url,
        [string] $repo_name,
        [string] $repo_type
    )
    $result = @{ AlreadyFailed = $false; Message = "" }

    if ($repo_type -eq "github")
    {
        $checks = (get-github-pr-checks -pr_url $pr_url -fields 'name,state,bucket').Checks
        # Only consider build/CI checks - filter out non-build checks
        $build_checks = @(@($checks) | Where-Object {
            $_ -and
            $_.name -match "Gate|Build|build|CI|ci" -and
            $_.name -notmatch "license|cla|proof.of.presence"
        })
        $failed_builds = @($build_checks | Where-Object { $_.bucket -eq "fail" })
        if ($failed_builds.Count -gt 0)
        {
            $failed_names = ($failed_builds | ForEach-Object { $_.name }) -join ", "
            $result.AlreadyFailed = $true
            $result.Message = "Failed: $failed_names"
        }
        else
        {
            # no build checks have failed
        }
    }
    elseif ($repo_type -eq "azure")
    {
        $pr_id = get-azure-pr-id-from-url $pr_url
        if ($pr_id)
        {
            $azure_info = get-azure-org-project $repo_name
            $display_data = get-policy-display-data -pr_id $pr_id -org $azure_info.Organization
            if ($display_data -and $display_data.Checks)
            {
                # Only consider Build policies - not Status, Required reviewers, etc.
                $build_checks = @($display_data.Checks | Where-Object {
                    $_.Name -match "Build" -and
                    $_.Name -notmatch "license|cla|proof.of.presence"
                })
                $failed_builds = @($build_checks | Where-Object { $_.Status -eq [PrCheckStatus]::Failed })
                if ($failed_builds.Count -gt 0)
                {
                    $failed_names = ($failed_builds | ForEach-Object { $_.Name }) -join ", "
                    $result.AlreadyFailed = $true
                    $result.Message = "Failed: $failed_names"
                }
                else
                {
                    # no build checks have failed
                }
            }
            else
            {
                # no policy data
            }
        }
        else
        {
            # couldn't parse PR ID
        }
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
        monitor-github-pr -repo_name $repo_name -pr_url $pr_url
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


# Arm an existing PR again (auto-merge / auto-complete may have been lost, e.g. by a close/reopen).
function arm-existing-pr
{
    param(
        [string] $pr_url,
        [string] $repo_name,
        [string] $repo_type
    )

    if ($repo_type -eq "github")
    {
        arm-github-pr -pr_url $pr_url
    }
    elseif ($repo_type -eq "azure")
    {
        $azure_info = get-azure-org-project $repo_name
        arm-azure-pr (get-azure-pr-id-from-url $pr_url) $azure_info.Organization
    }
    else
    {
        # unknown repo type
    }
}


# Run AutoFix on an existing PR's build failure; fails the run with $failure_message if it cannot.
function invoke-autofix-for-pr
{
    param(
        [string] $repo_name,
        [string] $pr_url,
        [string] $failure_message
    )
    $logs = get-failed-build-logs -repo_name $repo_name -pr_url $pr_url
    Push-Location $repo_name
    $branch_name = git rev-parse --abbrev-ref HEAD 2>$null
    $fix_result = invoke-copilot-autofix -repo_name $repo_name -branch_name $branch_name -pr_url $pr_url -build_logs $logs
    Pop-Location
    if (-not $fix_result)
    {
        fail-with-status $failure_message
    }
    else
    {
        Write-Host "  AutoFix pushed a fix, monitoring PR..." -ForegroundColor Magenta
    }
}


# Follow a PR until it merges, then record the repo as updated (unless the user cancelled).
function wait-for-pr-merge
{
    param(
        [string] $pr_url,
        [string] $repo_name,
        [string] $repo_type
    )
    set-repo-status -repo_name $repo_name -status $script:STATUS_IN_PROGRESS -pr_url $pr_url
    monitor-pr -pr_url $pr_url -repo_name $repo_name -repo_type $repo_type
    if ($global:propagation_cancelled)
    {
        # the cancel prompt already recorded the repo's status
    }
    else
    {
        if ($repo_type -eq "github")
        {
            # Wait for merge to settle
            Start-Sleep -Seconds 2
        }
        else
        {
            # Azure DevOps reports completion only after the merge
        }
        complete-repo-update -repo_name $repo_name -pr_url $pr_url
    }
}


# Update dependencies for a given repo and wait for its PR to merge.
# Handles resume (existing PR) and fresh run (create new PR) paths.
function update-repo
{
    param(
        [string] $repo_name,
        [string] $new_branch_name
    )
    start-repo-update -repo_name $repo_name

    # --- Resolve existing PR (resume only) ---
    # On fresh runs the branch is new, so no PR can exist.
    # On resume, check for an existing PR to avoid duplicate pushes/PRs.
    $existing_pr_url = $null
    $repo_type = get-repo-type $repo_name

    if ($global:is_resume)
    {
        $existing_pr_url = resolve-existing-pr -repo_name $repo_name -new_branch_name $new_branch_name
    }
    else
    {
        # fresh run - skip PR lookup
    }

    if ($existing_pr_url)
    {
        # Check PR disposition: merged, abandoned, or active
        $disposition = get-pr-disposition -pr_url $existing_pr_url -repo_name $repo_name -repo_type $repo_type

        if ($disposition -eq "merged")
        {
            Write-Host "PR already merged, skipping repo" -ForegroundColor Green
            complete-repo-update -repo_name $repo_name -pr_url $existing_pr_url
        }
        elseif ($disposition -eq "abandoned")
        {
            if ($global:auto_fix)
            {
                # Reopen the PR so autofix can fix it
                Write-Host "Previous PR was abandoned - reopening for autofix..." -ForegroundColor Magenta
                if ($repo_type -eq "github")
                {
                    reopen-pr-github -pr_url $existing_pr_url
                }
                elseif ($repo_type -eq "azure")
                {
                    reopen-pr-azure -pr_url $existing_pr_url -repo_name $repo_name
                    arm-existing-pr -pr_url $existing_pr_url -repo_name $repo_name -repo_type $repo_type
                }
                else
                {
                    fail-with-status "Unable to reopen PR for $repo_name. Unknown repo type."
                }

                # Now treat as active - run autofix + monitor
                Write-Host "Running AutoFix on reopened PR..." -ForegroundColor Magenta
                invoke-autofix-for-pr -repo_name $repo_name -pr_url $existing_pr_url -failure_message "AutoFix could not resolve build failure for $repo_name."
                wait-for-pr-merge -pr_url $existing_pr_url -repo_name $repo_name -repo_type $repo_type
            }
            else
            {
                # No autofix - fall through to fresh update to check if changes are still needed.
                Write-Host "Previous PR was abandoned: $existing_pr_url" -ForegroundColor Yellow
                Write-Host "Checking if changes are still needed..." -ForegroundColor Yellow
                $existing_pr_url = $null
            }
        }
        else
        {
            # PR is still active - check for regression or redundancy
            $pr_check = check-pr-would-regress -repo_name $repo_name
            if ($pr_check.WouldRegress)
            {
                fail-with-status "PR for $repo_name would regress submodules. Someone has already updated this repo with newer versions. Abandon the PR and start a new propagation."
            }
            elseif ($pr_check.AlreadyUpToDate)
            {
                Write-Host "Master already has all the submodule versions this PR would set. Closing PR and skipping." -ForegroundColor Green
                close-pr -repo_name $repo_name -pr_url $existing_pr_url
                set-repo-status -repo_name $repo_name -status $script:STATUS_SKIPPED -message "Already up to date"
                update-fixed-commit $repo_name
            }
            else
            {
                # PR still has changes to contribute.
                # If autofix is enabled, check if the PR's checks have already failed.
                # If so, run autofix immediately instead of re-watching a known-bad build.
                if ($global:auto_fix)
                {
                    $check_status = test-pr-checks-already-failed -pr_url $existing_pr_url -repo_name $repo_name -repo_type $repo_type
                    if ($check_status.AlreadyFailed)
                    {
                        Write-Host "PR checks already failed: $($check_status.Message)" -ForegroundColor Yellow
                        Write-Host "Running AutoFix before re-watching..." -ForegroundColor Magenta
                        invoke-autofix-for-pr -repo_name $repo_name -pr_url $existing_pr_url -failure_message "PR checks failed for repo ${repo_name}: $($check_status.Message). AutoFix could not resolve."
                    }
                    else
                    {
                        # checks not failed yet, proceed to normal monitoring
                    }
                }
                else
                {
                    # autofix not enabled
                }

                Write-Host "Monitoring existing PR..."
                # Re-arm in case auto-merge/auto-complete was lost (e.g., PR was closed and reopened)
                arm-existing-pr -pr_url $existing_pr_url -repo_name $repo_name -repo_type $repo_type
                wait-for-pr-merge -pr_url $existing_pr_url -repo_name $repo_name -repo_type $repo_type
            }
        }
    }
    else
    {
        # no existing PR
    }

    # Fresh update path: no existing PR, or previous PR was abandoned
    if (-not $existing_pr_url -and
        $global:repo_status[$repo_name].Status -ne $script:STATUS_UPDATED -and
        $global:repo_status[$repo_name].Status -ne $script:STATUS_SKIPPED)
    {
        $desc = create-repo-pr $repo_name $new_branch_name
        if ($desc)
        {
            # Show Windows notification with PR link
            show-pr-notification -repo_name $repo_name -pr_url $desc.PrUrl
            if ($repo_type -eq "github")
            {
                # Poll until CI checks appear (not just CLA/license checks which are always present)
                wait-for-github-ci-checks -pr_url $desc.PrUrl
            }
            else
            {
                # Azure DevOps policies are listed as soon as the PR exists
            }
            if (-not $global:propagation_cancelled)
            {
                wait-for-pr-merge -pr_url $desc.PrUrl -repo_name $repo_name -repo_type $repo_type
            }
            else
            {
                # cancelled while waiting for checks
            }
        }
        else
        {
            # no changes; create-repo-pr marked the repo skipped
        }
    }
    else
    {
        # already handled through the existing PR
    }
}


# --- Pipeline -----------------------------------------------------------------------------------

# Poll a single PR descriptor once: returns 'merged', 'failed', or 'pending'.
function poll-pr-state
{
    param([hashtable] $desc)
    if ($desc.Type -eq 'azure')
    {
        return (poll-azure-pr-state -pr_id $desc.PrId -org $desc.Org -repo_name $desc.Repo)
    }
    elseif ($desc.Type -eq 'github')
    {
        return (poll-github-pr-state $desc)
    }
    else
    {
        fail-with-status "Unknown PR type '$($desc.Type)' for repo $($desc.Repo)."
    }
}

# The dependencies of $repo_name that are not propagated yet.
function get-unfinished-dependencies
{
    param(
        [string] $repo_name,
        $repo_edges,
        $done
    )
    $result = @()
    if ($repo_edges.ContainsKey($repo_name))
    {
        $result = @($repo_edges[$repo_name] | Where-Object { -not $done.Contains($_) } | Select-Object -Unique)
    }
    else
    {
        # not in the graph, so nothing to wait for
    }
    return $result
}

# Propagate greedily: open each repo's PR as soon as every repo it depends on is propagated, and
# poll all open PRs together. A merge advances that repo's fixed commit before anything depending
# on it starts, so dependents pin the merged commit. Fails the run on the first PR that is
# abandoned, closed or rejected, or if the remaining repos can never start.
function update-repos-greedily
{
    param(
        [System.Collections.IList] $repo_order,
        $repo_edges,
        [string] $new_branch_name
    )
    $poll = [Math]::Max([int]$global:poll_interval, 30)
    $done = New-Object -TypeName "System.Collections.Generic.HashSet[string]"
    $started = New-Object -TypeName "System.Collections.Generic.HashSet[string]"
    $open_prs = New-Object -TypeName "System.Collections.ArrayList"

    while ($true)
    {
        # Start every repo whose dependencies are all propagated. A repo without changes is done at
        # once and may unblock others, so repeat until nothing new starts.
        do
        {
            $started_any = $false
            foreach ($repo in $repo_order)
            {
                if ($started.Contains($repo) -or @(get-unfinished-dependencies $repo $repo_edges $done).Count -gt 0)
                {
                    continue
                }
                [void]$started.Add($repo)
                $started_any = $true
                set-repo-details -repo_name $repo -details ""
                start-repo-update -repo_name $repo
                $desc = create-repo-pr $repo $new_branch_name
                if ($desc)
                {
                    [void]$open_prs.Add($desc)
                }
                else
                {
                    [void]$done.Add($repo)
                }
            }
        } while ($started_any)

        if ($done.Count -eq $repo_order.Count)
        {
            break
        }
        if ($open_prs.Count -eq 0)
        {
            $blocked = @($repo_order | Where-Object { -not $started.Contains($_) } | ForEach-Object {
                "{0} (needs {1})" -f $_, (@(get-unfinished-dependencies $_ $repo_edges $done) -join ', ')
            })
            fail-with-status "No PR is open and no remaining repo can start: $($blocked -join '; ')"
        }

        $merged_any = $false
        foreach ($desc in @($open_prs))
        {
            $global:current_repo = $desc.Repo
            $state = poll-pr-state $desc
            if ($state -eq 'merged')
            {
                Write-Log INFO "PR for $($desc.Repo) merged ($($desc.PrUrl))"
                [void]$open_prs.Remove($desc)
                complete-repo-update -repo_name $desc.Repo -pr_url $desc.PrUrl
                [void]$done.Add($desc.Repo)
                $merged_any = $true
            }
            elseif ($state -eq 'failed')
            {
                fail-with-status "PR for $($desc.Repo) failed (abandoned, closed, or rejected): $($desc.PrUrl)"
            }
            else
            {
                # still pending
            }
        }

        if ($merged_any)
        {
            # start whatever the merges unblocked right away
        }
        else
        {
            foreach ($repo in $repo_order)
            {
                if (-not $started.Contains($repo))
                {
                    set-repo-details -repo_name $repo -details ("waiting for " + (@(get-unfinished-dependencies $repo $repo_edges $done) -join ", "))
                }
                else
                {
                    # started; its PR poll keeps the details current
                }
            }
            [void](show-propagation-status)
            [void](wait-poll-interval -seconds $poll)
        }
    }
}
