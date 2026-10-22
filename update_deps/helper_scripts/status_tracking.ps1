# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Status tracking functions for propagate_updates.ps1

# Global status tracking
$global:repo_status = @{}
$global:repo_order_list = @()
$global:current_repo = ""  # Track current repo for error handling in nested functions
$script:failure_in_progress = $false  # set while fail-with-status reports a failure

# Status constants
$script:STATUS_PENDING = "pending"
$script:STATUS_IN_PROGRESS = "in-progress"
$script:STATUS_UPDATED = "updated"
$script:STATUS_SKIPPED = "skipped"
$script:STATUS_FAILED = "failed"

# Initialize status for all repos
function initialize-repo-status
{
    param(
        [string[]] $repos
    )
    $global:repo_order_list = $repos
    $global:repo_status = @{}
    $global:current_repo = ""
    foreach($repo in $repos)
    {
        $global:repo_status[$repo] = @{
            Status = $script:STATUS_PENDING
            Message = ""
            PrUrl = ""
            Details = ""
        }
    }
}

# Update status for a repo
function set-repo-status
{
    param(
        [string] $repo_name,
        [string] $status,
        [string] $message = "",
        [string] $pr_url = ""
    )
    if($global:repo_status.ContainsKey($repo_name))
    {
        $global:repo_status[$repo_name].Status = $status
        $global:repo_status[$repo_name].Message = $message
        if($pr_url)
        {
            $global:repo_status[$repo_name].PrUrl = $pr_url
        }
        else
        {
            # keep existing pr_url if not provided
        }
    }
    else
    {
        # unknown repo, ignore
    }
}

# Record what a repo's open PR is currently waiting on; shown under its row in the status table.
function set-repo-details
{
    param(
        [string] $repo_name,
        [string] $details
    )
    if($global:repo_status.ContainsKey($repo_name))
    {
        $global:repo_status[$repo_name].Details = $details
    }
    else
    {
        # unknown repo, ignore
    }
}

# Join gate names for display: unique, at most $max_names of them, each cut to a readable length.
function format-gate-names
{
    param(
        [object[]] $gates,
        [int] $max_names = 4,
        [int] $max_name_length = 60
    )
    $names = @($gates | ForEach-Object { $_.Name } | Select-Object -Unique)
    $shown = @($names | Select-Object -First $max_names | ForEach-Object {
        if ($_.Length -gt $max_name_length) { $_.Substring(0, $max_name_length - 3) + "..." } else { $_ }
    })
    $result = $shown -join ", "
    if ($names.Count -gt $shown.Count)
    {
        $result += ", +{0} more" -f ($names.Count - $shown.Count)
    }
    else
    {
        # every name shown
    }
    return $result
}

# Describe what an open PR is waiting on. $gates lists its blocking checks as @{ Name; State },
# State being 'done', 'running', 'not-started', 'awaiting-action' or 'failed'. $notes are other
# facts that keep the PR from merging (e.g. merge conflicts). Gates awaiting action or failed are
# named since they usually need a human.
function format-gate-summary
{
    param(
        [object[]] $gates = @(),
        [string[]] $notes = @()
    )
    $gates = @($gates | Where-Object { $_ })
    $done = @($gates | Where-Object { $_.State -eq 'done' }).Count

    if ($gates.Count -eq 0)
    {
        $result = "no gates reported yet"
    }
    elseif ($done -eq $gates.Count)
    {
        $result = "all {0} gates done; waiting for the merge" -f $gates.Count
    }
    else
    {
        $parts = @()
        $categories = @(
            @{ State = 'running'; Label = 'running'; Named = $false },
            @{ State = 'not-started'; Label = 'not started'; Named = $false },
            @{ State = 'awaiting-action'; Label = 'awaiting action'; Named = $true },
            @{ State = 'failed'; Label = 'failed'; Named = $true }
        )
        foreach ($category in $categories)
        {
            $matching = @($gates | Where-Object { $_.State -eq $category.State })
            if ($matching.Count -gt 0)
            {
                $part = "{0} {1}" -f $matching.Count, $category.Label
                if ($category.Named)
                {
                    $part += " [{0}]" -f (format-gate-names -gates $matching)
                }
                else
                {
                    # counts only
                }
                $parts += $part
            }
            else
            {
                # nothing in this category
            }
        }
        $result = "waiting on {0} of {1} gates: {2}; {3} done" -f ($gates.Count - $done), $gates.Count, ($parts -join ", "), $done
    }

    foreach ($note in @($notes | Where-Object { $_ }))
    {
        $result += "; $note"
    }
    return $result
}

# Count repos per status.
function get-repo-status-counts
{
    $result = @{ Total = 0; Updated = 0; Skipped = 0; InProgress = 0; Pending = 0; Failed = 0 }
    foreach($repo in $global:repo_order_list)
    {
        $result['Total'] += 1
        switch($global:repo_status[$repo].Status)
        {
            $script:STATUS_UPDATED { $result['Updated'] += 1 }
            $script:STATUS_SKIPPED { $result['Skipped'] += 1 }
            $script:STATUS_IN_PROGRESS { $result['InProgress'] += 1 }
            $script:STATUS_PENDING { $result['Pending'] += 1 }
            $script:STATUS_FAILED { $result['Failed'] += 1 }
            default { }
        }
    }
    return $result
}

# Close/abandon a PR for the given repo.
# Dispatches to platform-specific close functions in azure_repo_ops.ps1 / github_repo_ops.ps1.
function close-pr
{
    param(
        [string] $repo_name,
        [string] $pr_url
    )

    # Ensure we're in the work directory so repo-relative functions work
    Push-Location $global:work_dir
    try
    {
        $repo_type = get-repo-type $repo_name
        if ($repo_type -eq "github")
        {
            close-pr-github -pr_url $pr_url
        }
        elseif ($repo_type -eq "azure")
        {
            close-pr-azure -pr_url $pr_url -repo_name $repo_name
        }
        else
        {
            Write-Host "Warning: Unknown repo type for $repo_name, cannot close PR" -ForegroundColor Yellow
        }
    }
    catch
    {
        Write-Host "Warning: Error closing PR: $_" -ForegroundColor Yellow
    }
    finally
    {
        Pop-Location
    }
}

# Fail with status - marks current repo as failed, shows final status, and exits
# Exits on failure (always)
function fail-with-status
{
    param(
        [string] $message
    )
    if ($script:failure_in_progress)
    {
        # A failure while reporting an earlier one (e.g. while closing the failed PR) must not start
        # the cleanup again, which could recurse. Throw so the cleanup step reports it and the
        # earlier failure finishes.
        throw "fail-with-status while handling an earlier failure: $message"
    }
    else
    {
        $script:failure_in_progress = $true
    }
    if ($global:current_repo -and $global:repo_status.ContainsKey($global:current_repo))
    {
        set-repo-status -repo_name $global:current_repo -status $script:STATUS_FAILED -message $message

        # Close/abandon the failed PR if the flag is set and a PR URL exists
        if ($global:close_failed_pr)
        {
            $pr_url = $global:repo_status[$global:current_repo].PrUrl
            if ($pr_url)
            {
                close-pr -repo_name $global:current_repo -pr_url $pr_url
            }
            else
            {
                # no PR URL to close
            }
        }
        else
        {
            # close_failed_pr not set, leaving PR open
        }
    }
    else
    {
        # no current repo to mark as failed
    }
    [void](show-propagation-status -Final)

    # Save state so -Resume can pick up PrUrls and status from this failed run
    if (-not (test-pipeline-mode) -and $global:_state_branch_name -and $global:_state_repo_order -and $global:work_dir)
    {
        save-propagation-state `
            -branch_name $global:_state_branch_name `
            -repo_order $global:_state_repo_order `
            -repo_urls $global:_state_repo_urls `
            -root_list $global:_state_root_list `
            -azure_work_item $global:_state_azure_work_item
    }
    else
    {
        # pipeline runs are not resumable, or state globals are not initialized yet
    }

    # Restore original directory so we are not stranded in work_dir/<repo>
    restore-original-directory

    Write-Log ERROR $message
    if (-not (test-pipeline-mode))
    {
        Write-Host "`nTo resume from where it stopped, run:" -ForegroundColor Cyan
        if ($global:resume_command)
        {
            Write-Host "  $global:resume_command" -ForegroundColor White
        }
        else
        {
            Write-Host "  propagate_updates.ps1 -Resume" -ForegroundColor White
        }
    }
    else
    {
        # pipeline runs are not resumable
    }
    exit -1
}

# Get status display info (symbol, color, text). Pipeline logs use ASCII symbols.
function get-repo-status-display
{
    param(
        [string] $status
    )
    $result = $null

    switch($status)
    {
        $script:STATUS_UPDATED
        {
            $result = @{
                Symbol = if (test-pipeline-mode) { "+" } else { [char]0x2713 }  # checkmark
                Color = "Green"
                Text = "UPDATED"
            }
        }
        $script:STATUS_SKIPPED
        {
            $result = @{
                Symbol = "-"
                Color = "Gray"
                Text = "SKIPPED"
            }
        }
        $script:STATUS_IN_PROGRESS
        {
            $result = @{
                Symbol = "*"
                Color = "Yellow"
                Text = "IN PROGRESS"
            }
        }
        $script:STATUS_PENDING
        {
            $result = @{
                Symbol = "."
                Color = "DarkGray"
                Text = "PENDING"
            }
        }
        $script:STATUS_FAILED
        {
            $result = @{
                Symbol = if (test-pipeline-mode) { "x" } else { [char]0x2717 }  # X mark
                Color = "Red"
                Text = "FAILED"
            }
        }
        default
        {
            $result = @{
                Symbol = "?"
                Color = "Gray"
                Text = $status
            }
        }
    }

    return $result
}


# Display propagation status as a formatted table
function show-propagation-status
{
    param(
        [switch] $Final
    )
    $result = $false

    if (-not $global:repo_order_list -or $global:repo_order_list.Count -eq 0)
    {
        Write-Host "No repos to display status for." -ForegroundColor Yellow
    }
    else
    {
        # Calculate dynamic column widths
        $index_width = ($global:repo_order_list.Count).ToString().Length + 1  # +1 for the dot
        $repo_width = ($global:repo_order_list | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
        $status_width = 11  # "IN PROGRESS" is the longest status text

        # Build table rows with display info
        $rows = @()
        $index = 1
        foreach($repo in $global:repo_order_list)
        {
            $info = $global:repo_status[$repo]
            $display = get-repo-status-display -status $info.Status
            $rows += @{
                Index = $index
                Repo = $repo
                Status = $info.Status
                StatusText = $display.Text
                Symbol = $display.Symbol
                Color = $display.Color
                Message = $info.Message
                PrUrl = $info.PrUrl
                Details = $info.Details
            }
            $index++
        }
        $counts = get-repo-status-counts

        # Print header
        if($Final)
        {
            Write-Host ""
            Write-Host "========================================" -ForegroundColor Cyan
            Write-Host "     PROPAGATION STATUS SUMMARY" -ForegroundColor Cyan
            Write-Host "========================================" -ForegroundColor Cyan
        }
        else
        {
            Write-Host ""
            Write-Host ("--- Propagation Status ({0}) ---" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor Cyan
            Write-Host ("Repos: {0} of {1} done ({2} updated, {3} skipped), {4} in progress, {5} not started, {6} failed" -f `
                ($counts.Updated + $counts.Skipped), $counts.Total, $counts.Updated, $counts.Skipped, $counts.InProgress, $counts.Pending, $counts.Failed) -ForegroundColor Cyan
        }

        # Print table header
        $header = "   {0,-$index_width} {1,-$repo_width} {2,-$status_width} {3}" -f "#", "REPOSITORY", "STATUS", "PR"
        Write-Host $header -ForegroundColor White

        # Print each row
        foreach($row in $rows)
        {
            $index_str = "{0}." -f $row.Index

            # Build the line with fixed-width columns
            $symbol = $row.Symbol
            $line = "{0}  {1,-$index_width} {2,-$repo_width} {3,-$status_width} {4}" -f $symbol, $index_str, $row.Repo, $row.StatusText, $row.PrUrl

            Write-Host $line -ForegroundColor $row.Color

            # Under an open, failed or not yet started repo's row, what it last reported or is waiting
            # for (indented to the REPOSITORY column)
            if(($row.Status -in @($script:STATUS_IN_PROGRESS, $script:STATUS_FAILED, $script:STATUS_PENDING)) -and $row.Details)
            {
                Write-Host ("{0}{1}" -f (" " * (4 + $index_width)), (Protect-Secret $row.Details)) -ForegroundColor $row.Color
            }
            else
            {
                # no details to show
            }
        }

        if($Final)
        {
            Write-Host "========================================" -ForegroundColor Cyan

            Write-Host ""
            Write-Host "Summary: " -NoNewline
            Write-Host "$($counts.Updated) updated" -ForegroundColor Green -NoNewline
            Write-Host ", $($counts.Skipped) skipped" -ForegroundColor Gray -NoNewline
            Write-Host ", $($counts.Failed) failed" -ForegroundColor Red -NoNewline
            Write-Host ", $($counts.InProgress) in progress" -ForegroundColor Yellow -NoNewline
            Write-Host ", $($counts.Pending) pending" -ForegroundColor DarkGray
            Write-Host ""

            # Return success only if every repo finished (no failures, nothing pending or in flight)
            if($counts.Failed -eq 0 -and $counts.Pending -eq 0 -and $counts.InProgress -eq 0)
            {
                $result = $true
            }
            else
            {
                # there were failures, pending or in-progress repos
            }
        }
        else
        {
            # not final - no summary, result stays false
        }

        Write-Host ""
    }

    return $result
}


# Restore the original working directory. Called on success and failure exit paths.
function restore-original-directory
{
    if ($global:original_dir)
    {
        Set-Location $global:original_dir
    }
    else
    {
        # no original_dir saved
    }
}


# Sleep for the poll interval between PR status checks.
function wait-poll-interval
{
    param([int] $seconds)
    Start-Sleep -Seconds $seconds
}
