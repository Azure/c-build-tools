# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
#
# Greedy update scheduling. A repo's PR is opened as soon as every repo it depends on has been
# propagated (its PR merged, or it had no changes), and all open PRs are polled together, so
# independent dependency chains never wait for each other. Dot-sourced by propagate_updates.ps1.

# Update one repo's submodules to the snapshotted commits and, if anything changed, create and arm
# its PR WITHOUT blocking. Returns a PR descriptor (@{ Repo; Type; PrUrl; ... }) or $null if the
# repo had no changes (skipped).
function create-repo-pr
{
    param(
        [string] $repo_name,
        [string] $new_branch_name
    )
    Write-Log STEP "Updating repo $repo_name"
    set-repo-status -repo_name $repo_name -status $script:STATUS_IN_PROGRESS
    $global:current_repo = $repo_name

    Set-Location $global:work_dir
    $repo_type = get-repo-type $repo_name

    $update_result = (update-local-repo $repo_name $new_branch_name)
    [string] $git_output = $update_result.GitOutput
    $description = $update_result.Description

    if ($git_output.Contains("nothing to commit"))
    {
        Write-Log INFO "Nothing to commit; skipping repo $repo_name"
        set-repo-status -repo_name $repo_name -status $script:STATUS_SKIPPED -message "No changes"
        Write-Log INFO "Done updating repo $repo_name"
        return $null
    }

    if ($repo_type -eq "github")
    {
        $desc = create-pr-github-armed $repo_name $new_branch_name $description
    }
    elseif ($repo_type -eq "azure")
    {
        $desc = create-pr-azure-armed $repo_name $new_branch_name $description
    }
    else
    {
        fail-with-status "Unable to update repository $repo_name. Only GitHub and Azure repositories are supported."
    }

    return $desc
}

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
                set-repo-status -repo_name $desc.Repo -status $script:STATUS_UPDATED -pr_url $desc.PrUrl
                update-fixed-commit $desc.Repo
                [void]$done.Add($desc.Repo)
                $merged_any = $true
                Write-Log INFO "Done updating repo $($desc.Repo)"
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
