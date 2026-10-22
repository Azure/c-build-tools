# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# GitHub repository operations for propagate_updates.ps1. Every gh call is time-bounded so a hung
# request cannot stall the run.


# Find an active GitHub PR for a given branch. Returns the PR URL or $null.
function find-active-github-pr
{
    param(
        [string] $repo_name,
        [string] $branch_name
    )
    $result = $null

    Push-Location $repo_name
    $list = Invoke-NativeWithTimeout -File gh -Arguments @('pr', 'list', '--head', $branch_name, '--state', 'open', '--json', 'url', '--jq', '.[0].url')
    if ($list.ExitCode -eq 0 -and $list.StdOut.Trim())
    {
        $result = $list.StdOut.Trim()
    }
    else
    {
        # no active PR for this branch
    }
    Pop-Location

    return $result
}


# Get the status of a GitHub PR. Returns "MERGED", "CLOSED", or "OPEN" (also when it cannot be read).
function get-github-pr-status
{
    param(
        [string] $pr_url
    )
    $result = "OPEN"

    $view = Invoke-NativeWithTimeout -File gh -Arguments @('pr', 'view', $pr_url, '--json', 'state')
    if ($view.ExitCode -eq 0)
    {
        try { $result = ($view.StdOut | ConvertFrom-Json).state } catch { $result = "OPEN" }
    }
    else
    {
        # couldn't check PR status, assume open
    }

    return $result
}


# Checks of a GitHub PR. Returns @{ Checks; Error }: Checks is the parsed check list ($null when it
# could not be read), Error the first line of gh's error output.
function get-github-pr-checks
{
    param(
        [string] $pr_url,
        [string] $fields = 'name,state,bucket'
    )
    $checks = $null
    $run = Invoke-NativeWithTimeout -File gh -Arguments @('pr', 'checks', $pr_url, '--json', $fields)
    if ($run.StdOut -and $run.StdOut.Trim())
    {
        try
        {
            $parsed = $run.StdOut | ConvertFrom-Json
            $checks = @($parsed | ForEach-Object { $_ })
        }
        catch
        {
            $checks = $null
        }
    }
    else
    {
        # no output, e.g. no checks reported yet or gh timed out
    }
    $error_line = ""
    if ($run.StdErr)
    {
        $error_line = ($run.StdErr.Trim() -split "`r?`n")[0]
    }
    else
    {
        # no error output
    }
    return @{ Checks = $checks; Error = $error_line }
}


# Close a GitHub PR, checking status first.
function close-pr-github
{
    param(
        [string] $pr_url
    )

    $pr_state = get-github-pr-status -pr_url $pr_url
    if ($pr_state -eq "MERGED")
    {
        Write-Host "GitHub PR is already merged, skipping close" -ForegroundColor Green
    }
    elseif ($pr_state -eq "CLOSED")
    {
        Write-Host "GitHub PR is already closed, skipping" -ForegroundColor Gray
    }
    else
    {
        Write-Host "Closing GitHub PR: $pr_url" -ForegroundColor Yellow
        $close = Invoke-NativeWithTimeout -File gh -Arguments @('pr', 'close', $pr_url)
        if ($close.ExitCode -eq 0)
        {
            Write-Host "GitHub PR closed successfully" -ForegroundColor Green
        }
        else
        {
            Write-Log WARN "Failed to close GitHub PR ${pr_url}: $($close.StdErr.Trim())"
        }
    }
}


# Arm a GitHub PR to merge on its own: enable auto-merge, then trigger the pipeline (in that order,
# to avoid the "PR was updated after run command" rejection). Safe to repeat.
function arm-github-pr
{
    param(
        [string] $pr_url
    )
    Write-Host "Enabling auto-merge"
    $auto_merge = Invoke-NativeWithTimeout -File gh -Arguments @('pr', 'merge', $pr_url, '--auto', '--squash', '--delete-branch')
    if ($auto_merge.ExitCode -ne 0)
    {
        Write-Log WARN "Could not enable auto-merge; the PR will be merged directly once checks pass: $($auto_merge.StdErr.Trim())"
    }
    else
    {
        Write-Host "Auto-merge enabled" -ForegroundColor Green
    }

    Write-Host "Triggering pipeline..." -ForegroundColor Cyan
    $null = Invoke-NativeWithTimeout -File gh -Arguments @('pr', 'comment', $pr_url, '--body', '/AzurePipelines run')
}


# Reopen a closed GitHub PR and arm it again (closing a PR cancels auto-merge).
function reopen-pr-github
{
    param(
        [string] $pr_url
    )

    Write-Host "Reopening GitHub PR: $pr_url" -ForegroundColor Cyan
    $reopen = Invoke-NativeWithTimeout -File gh -Arguments @('pr', 'reopen', $pr_url)
    if ($reopen.ExitCode -eq 0)
    {
        Write-Host "GitHub PR reopened successfully" -ForegroundColor Green
        arm-github-pr -pr_url $pr_url
    }
    else
    {
        Write-Host "Warning: Failed to reopen GitHub PR: $pr_url" -ForegroundColor Yellow
    }
}


# Create the dependency-update PR for a GitHub repo and arm it to auto-merge, without waiting for
# it. Returns a descriptor consumed by the scheduler (@{ Repo; Type='github'; PrUrl; RepoName }).
# If the PR cannot be created the whole propagation FAILS and stops: skipping a repo and continuing
# would update repos that depend on it out of order (e.g. bumping c-build-tools in Metrics while the
# intervening macro-utils-c was never updated). In-order propagation is a hard invariant.
function create-pr-github-armed
{
    param(
        [string] $repo_name,
        [string] $new_branch_name,
        [hashtable] $description
    )
    $desc = $null

    if (-not $description)
    {
        $description = build-propagation-description @()
    }
    else
    {
        # description provided
    }

    Push-Location $repo_name
    try
    {
        Write-Host "`nCreating PR"

        # Write body to temp file to avoid command line length limits (GitHub allows 65536 characters)
        $body_file = [System.IO.Path]::GetTempFileName()
        [System.IO.File]::WriteAllText($body_file, (select-pr-body -description $description -max_length 65000), (New-Object System.Text.UTF8Encoding $false))
        try
        {
            $create = Invoke-NativeWithTimeout -File gh -Arguments @('pr', 'create', '--title', $description.PrTitle, '--body-file', $body_file, '--head', $new_branch_name)
        }
        finally
        {
            Remove-Item $body_file -ErrorAction SilentlyContinue
        }
        if ($create.ExitCode -ne 0)
        {
            Write-Log WARN "gh pr create returned non-zero (PR may already exist): $($create.StdOut)$($create.StdErr)"
        }
        else
        {
            Write-Host "PR created" -ForegroundColor Green
        }

        $pr_url = $null
        $view = Invoke-NativeWithTimeout -File gh -Arguments @('pr', 'view', $new_branch_name, '--json', 'url')
        if ($view.ExitCode -eq 0)
        {
            try { $pr_url = ($view.StdOut | ConvertFrom-Json).url } catch { $pr_url = $null }
        }
        else
        {
            Write-Log WARN "gh pr view could not find the PR: $($view.StdErr.Trim())"
        }

        if ([string]::IsNullOrWhiteSpace($pr_url))
        {
            # No PR exists. Do NOT skip and continue: that would update downstream repos out of order.
            # Fail the whole run so the chain stays consistent. This is almost always a GitHub auth
            # limitation on the upstream repo (push/PR returned 403 SAML SSO, or the token lacks write).
            fail-with-status (@(
                "Could not create a GitHub PR for $repo_name, so propagation cannot continue without",
                "updating repos that depend on it out of order. Aborting to keep the chain consistent.",
                "This is almost always GitHub auth: the token must have write access to this repo AND be",
                "SSO-authorized for its organization. Authorize it at https://github.com -> Settings ->",
                "Developer settings -> Personal access tokens -> Configure SSO, then re-run."
            ) -join "`n")
        }
        else
        {
            Write-Log INFO "GitHub PR: $pr_url"
        }

        # Update status with PR URL immediately so it shows even if later steps fail
        set-repo-status -repo_name $repo_name -status $script:STATUS_IN_PROGRESS -pr_url $pr_url

        arm-github-pr -pr_url $pr_url

        $desc = @{ Repo = $repo_name; Type = 'github'; PrUrl = $pr_url; RepoName = $repo_name }
    }
    finally
    {
        Pop-Location
    }

    return $desc
}


# --- Interactive monitoring ---------------------------------------------------------------------

# Wait (up to 3 minutes) for CI checks other than license/CLA checks to appear on a new PR.
function wait-for-github-ci-checks
{
    param(
        [string] $pr_url
    )
    Write-Host "Waiting for CI checks to start... (Press Ctrl+C to cancel)" -ForegroundColor Gray
    $max_wait = 180
    $waited = 0
    $checks_started = $false
    while ($waited -lt $max_wait -and -not $checks_started)
    {
        if (wait-or-cancel -seconds 5)
        {
            $global:propagation_cancelled = $true
            return
        }
        else
        {
            $waited += 5
        }
        Write-Host "`r  Waited ${waited}s / ${max_wait}s..." -NoNewline -ForegroundColor Gray
        $checks = (get-github-pr-checks -pr_url $pr_url -fields 'name,state').Checks
        # Filter out license/CLA checks - wait for actual CI checks
        $ci_checks = @(@($checks) | Where-Object { $_ -and $_.name -notmatch "license|cla" })
        if ($ci_checks.Count -gt 0)
        {
            $checks_started = $true
            Write-Host ""
            Write-Host "CI checks detected after ${waited}s ($($ci_checks.Count) check(s))" -ForegroundColor Green
        }
        else
        {
            # only CLA/license checks so far, keep waiting
        }
    }
    if (-not $checks_started)
    {
        Write-Host ""
        Write-Host "No checks detected after ${max_wait}s, proceeding to watch anyway" -ForegroundColor Yellow
    }
    else
    {
        # checks started
    }
}


# Watch a GitHub PR's checks until it merges, running AutoFix on build failures when enabled.
# Merges directly if auto-merge did not engage after the checks passed.
function monitor-github-pr
{
    param(
        [string] $repo_name,
        [string] $pr_url
    )
    $autofix_attempts = 0
    $merged = $false

    while (-not $merged -and -not $global:propagation_cancelled)
    {
        Write-Host "Waiting for build to complete"
        $watch_result = watch-github-pr-checks -pr_url $pr_url -poll_interval $global:poll_interval -timeout 120 -OnIteration { [void](show-propagation-status) }

        if ((get-github-pr-status -pr_url $pr_url) -eq "MERGED")
        {
            $merged = $true
            Write-Host "PR auto-merged successfully" -ForegroundColor Green
        }
        elseif (-not $watch_result.Success)
        {
            if ($global:propagation_cancelled)
            {
                # User cancelled - stop watching; the cancel prompt already handled the PR
            }
            elseif ($global:auto_fix -and $watch_result.Message -match "^Failed:" -and $autofix_attempts -lt $global:MAX_AUTOFIX_ATTEMPTS)
            {
                $autofix_attempts++
                Write-Host "`n  AutoFix attempt $autofix_attempts of $global:MAX_AUTOFIX_ATTEMPTS" -ForegroundColor Magenta
                Push-Location $repo_name
                $branch_name = git rev-parse --abbrev-ref HEAD 2>$null
                $fix_result = invoke-copilot-autofix -repo_name $repo_name -branch_name $branch_name -pr_url $pr_url
                Pop-Location
                if ($fix_result)
                {
                    Write-Host "  AutoFix pushed a fix, restarting watch..." -ForegroundColor Magenta
                }
                else
                {
                    fail-with-status "PR checks failed for repo ${repo_name}: $($watch_result.Message). AutoFix could not resolve."
                }
            }
            else
            {
                fail-with-status "PR checks failed for repo ${repo_name}: $($watch_result.Message)"
            }
        }
        else
        {
            # Checks passed but auto-merge hasn't completed yet, wait and retry
            Write-Host "PR checks passed" -ForegroundColor Green
            Write-Host "Waiting for auto-merge to complete..."
            $max_wait = 120
            $waited = 0
            while ($waited -lt $max_wait -and -not $merged)
            {
                if (wait-or-cancel -seconds 2)
                {
                    $global:propagation_cancelled = $true
                    break
                }
                else
                {
                    $waited += 2
                }
                if ((get-github-pr-status -pr_url $pr_url) -eq "MERGED")
                {
                    $merged = $true
                    Write-Host "PR auto-merged successfully" -ForegroundColor Green
                }
                else
                {
                    # still waiting
                }
            }

            if (-not $merged -and -not $global:propagation_cancelled)
            {
                # Auto-merge didn't fire - try merging directly
                Write-Host "Auto-merge did not complete, attempting direct merge..." -ForegroundColor Yellow
                $merge = Invoke-NativeWithTimeout -File gh -Arguments @('pr', 'merge', $pr_url, '--squash', '--delete-branch')
                if ($merge.ExitCode -eq 0)
                {
                    $merged = $true
                    Write-Host "PR merged successfully" -ForegroundColor Green
                }
                else
                {
                    fail-with-status "PR for repo $repo_name could not be merged. Check PR status."
                }
            }
            else
            {
                # merged or cancelled
            }
        }
    }
}


# --- Pipeline polling ---------------------------------------------------------------------------

# Map a `gh pr checks` entry to a gate state for format-gate-summary.
function get-github-check-gate-state
{
    param([object] $check)
    switch ($check.bucket)
    {
        'pass' { $result = 'done' }
        'skipping' { $result = 'done' }
        'fail' { $result = 'failed' }
        'cancel' { $result = 'failed' }
        default
        {
            # 'pending': queued, waiting, or actually executing
            if ($check.state -eq 'IN_PROGRESS')
            {
                $result = 'running'
            }
            else
            {
                $result = 'not-started'
            }
        }
    }
    return $result
}

# Poll a GitHub PR once and classify it as 'merged', 'failed', or 'pending'. cwd-independent: all gh
# calls take the PR URL. When all checks pass but the PR is still open, nudge a direct squash merge
# in case auto-merge did not engage. Every gh call is time-bounded so a hung request cannot stall
# the scheduler, and the PR's gates are recorded for the status table.
function poll-github-pr-state
{
    param([hashtable] $desc)
    $url = $desc.PrUrl

    # Defensive: a descriptor with no PR URL must never be waited on (would poll forever). Callers
    # do not enqueue these, but treat it as a failure if one ever reaches here.
    if ([string]::IsNullOrWhiteSpace($url))
    {
        Write-Log WARN "No PR URL for $($desc.Repo); treating as failed instead of waiting."
        return 'failed'
    }

    $view = Invoke-NativeWithTimeout -File gh -Arguments @('pr', 'view', $url, '--json', 'state,reviewDecision,mergeStateStatus,isDraft,autoMergeRequest')
    $pr = $null
    if ($view.ExitCode -eq 0)
    {
        try { $pr = $view.StdOut | ConvertFrom-Json } catch { $pr = $null }
    }
    if (-not $pr)
    {
        Write-Log WARN "gh pr view failed for $($desc.Repo) (exit $($view.ExitCode)); will retry next poll: $($view.StdErr.Trim())"
        set-repo-details -repo_name $desc.Repo -details "PR state unavailable; retrying on the next poll"
        return 'pending'
    }
    $state = $pr.state
    if ($state -eq 'MERGED')
    {
        return 'merged'
    }
    if ($state -eq 'CLOSED')
    {
        Write-Log WARN "GitHub PR for $($desc.Repo) was closed without merging."
        return 'failed'
    }

    # OPEN: inspect checks
    $gates = @()
    $notes = @()
    $check_result = get-github-pr-checks -pr_url $url -fields 'name,state,bucket'
    $check_list = @($check_result.Checks)
    if ($null -eq $check_result.Checks)
    {
        # e.g. no checks reported yet on a new branch, or gh timed out
        $check_list = @()
        $notes += "checks unavailable: " + $check_result.Error
    }
    else
    {
        # checks read
    }
    if ($check_list.Count -gt 0)
    {
        $gates = @($check_list | ForEach-Object { @{ Name = $_.name; State = (get-github-check-gate-state $_) } })
        $buckets = @($check_list | ForEach-Object { $_.bucket })
        if (($buckets -contains 'fail') -or ($buckets -contains 'cancel'))
        {
            set-repo-details -repo_name $desc.Repo -details (format-gate-summary -gates $gates)
            Write-Log WARN ("GitHub PR checks failed for {0}: {1}" -f $desc.Repo, (format-gate-names -gates @($gates | Where-Object { $_.State -eq 'failed' })))
            return 'failed'
        }
        $still_running = @($buckets | Where-Object { $_ -eq 'pending' })
        if ($still_running.Count -eq 0)
        {
            # all checks passed but not merged yet; nudge in case auto-merge did not engage
            $nudge = Invoke-NativeWithTimeout -File gh -Arguments @('pr', 'merge', $url, '--squash', '--delete-branch')
            if ($nudge.ExitCode -ne 0)
            {
                $notes += "merge attempt failed: " + ($nudge.StdErr.Trim() -split "`r?`n")[0]
            }
        }
    }

    switch ($pr.reviewDecision)
    {
        'APPROVED' { $gates += @{ Name = 'approval'; State = 'done' } }
        'REVIEW_REQUIRED' { $gates += @{ Name = 'approval'; State = 'awaiting-action' } }
        'CHANGES_REQUESTED' { $gates += @{ Name = 'changes requested'; State = 'awaiting-action' } }
        default { }
    }
    if ($pr.mergeStateStatus -eq 'DIRTY')
    {
        $notes += "merge conflicts"
    }
    elseif ($pr.mergeStateStatus -eq 'BEHIND')
    {
        $notes += "branch is behind its base"
    }
    elseif ($pr.mergeStateStatus -eq 'BLOCKED' -and @($gates | Where-Object { $_.State -ne 'done' }).Count -eq 0)
    {
        # gh lists only reported checks; a required check that never reported still blocks the merge
        $notes += "merge blocked by a requirement not listed here (e.g. a required check that has not reported)"
    }
    if ($pr.isDraft)
    {
        $notes += "draft"
    }
    if (-not $pr.autoMergeRequest)
    {
        $notes += "auto-merge not enabled"
    }
    set-repo-details -repo_name $desc.Repo -details (format-gate-summary -gates $gates -notes $notes)

    Write-Log INFO "Waiting for GitHub PR ($($desc.Repo)) to merge (state: $state)..."
    return 'pending'
}
