# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Status tracking functions for propagate_updates.ps1

# Global status tracking
$global:repo_status = @{}
$global:repo_order_list = @()
$global:current_repo = ""  # Track current repo for error handling in nested functions

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
    foreach($repo in $repos)
    {
        $global:repo_status[$repo] = @{
            Status = $script:STATUS_PENDING
            Message = ""
            PrUrl = ""
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

# Fail with status - marks current repo as failed, shows final status, and exits
# Exits on failure (always)
function fail-with-status
{
    param(
        [string] $message
    )
    if ($global:current_repo -and $global:repo_status.ContainsKey($global:current_repo))
    {
        set-repo-status -repo_name $global:current_repo -status $script:STATUS_FAILED -message $message
    }
    else
    {
        # no current repo to mark as failed
    }
    show-propagation-status -Final
    Write-Error $message
    exit -1
}

# Get status display info (symbol, color, text)
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
                Symbol = [char]0x2713  # checkmark
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
                Symbol = [char]0x2717  # X mark
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
        }
        $index++
    }

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
        Write-Host "--- Propagation Status ---" -ForegroundColor Cyan
    }

    # Print table header
    $header = "   {0,-$index_width} {1,-$repo_width} {2,-$status_width} {3}" -f "#", "REPOSITORY", "STATUS", "PR"
    Write-Host $header -ForegroundColor White

    # Print each row
    foreach($row in $rows)
    {
        $index_str = "{0}." -f $row.Index
        $status_display = $row.StatusText
        if($row.Message)
        {
            $status_display = "{0} ({1})" -f $row.StatusText, $row.Message
        }
        else
        {
            # no message to append
        }

        # Build the line with fixed-width columns
        $symbol = $row.Symbol
        $line = "{0}  {1,-$index_width} {2,-$repo_width} {3,-$status_width} {4}" -f $symbol, $index_str, $row.Repo, $row.StatusText, $row.PrUrl

        Write-Host $line -ForegroundColor $row.Color
    }

    if($Final)
    {
        Write-Host "========================================" -ForegroundColor Cyan

        # Summary counts
        $updated = ($global:repo_status.Values | Where-Object { $_.Status -eq $script:STATUS_UPDATED }).Count
        $skipped = ($global:repo_status.Values | Where-Object { $_.Status -eq $script:STATUS_SKIPPED }).Count
        $failed = ($global:repo_status.Values | Where-Object { $_.Status -eq $script:STATUS_FAILED }).Count
        $pending = ($global:repo_status.Values | Where-Object { $_.Status -eq $script:STATUS_PENDING }).Count

        Write-Host ""
        Write-Host "Summary: " -NoNewline
        Write-Host "$updated updated" -ForegroundColor Green -NoNewline
        Write-Host ", $skipped skipped" -ForegroundColor Gray -NoNewline
        Write-Host ", $failed failed" -ForegroundColor Red -NoNewline
        Write-Host ", $pending pending" -ForegroundColor DarkGray
        Write-Host ""

        # Return success if no failures
        if($failed -eq 0)
        {
            $result = $true
        }
        else
        {
            # there were failures
        }
    }
    else
    {
        # not final - no summary, result stays false
    }

    Write-Host ""

    return $result
}
