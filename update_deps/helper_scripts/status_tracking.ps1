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
function initialize-repo-status {
    param(
        [string[]] $repos
    )
    $global:repo_order_list = $repos
    $global:repo_status = @{}
    foreach($repo in $repos) {
        $global:repo_status[$repo] = @{
            Status = $script:STATUS_PENDING
            Message = ""
        }
    }
}

# Update status for a repo
function set-repo-status {
    param(
        [string] $repo_name,
        [string] $status,
        [string] $message = ""
    )
    if($global:repo_status.ContainsKey($repo_name)) {
        $global:repo_status[$repo_name].Status = $status
        $global:repo_status[$repo_name].Message = $message
    }
    else {
        # unknown repo, ignore
    }
}

# Fail with status - marks current repo as failed, shows final status, and exits
# Exits on failure (always)
function fail-with-status {
    param(
        [string] $message
    )
    if ($global:current_repo -and $global:repo_status.ContainsKey($global:current_repo)) {
        set-repo-status -repo_name $global:current_repo -status $script:STATUS_FAILED -message $message
    }
    else {
        # no current repo to mark as failed
    }
    show-propagation-status -Final
    Write-Error $message
    exit -1
}

# Display propagation status
function show-propagation-status {
    param(
        [switch] $Final
    )

    if($Final) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "     PROPAGATION STATUS SUMMARY" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
    } else {
        Write-Host ""
        Write-Host "--- Propagation Status ---" -ForegroundColor Cyan
    }

    $index = 1
    foreach($repo in $global:repo_order_list) {
        $info = $global:repo_status[$repo]
        $status = $info.Status
        $message = $info.Message

        # Choose symbol and color based on status
        switch($status) {
            $script:STATUS_UPDATED {
                $symbol = [char]0x2713  # checkmark
                $color = "Green"
                $status_text = "UPDATED"
            }
            $script:STATUS_SKIPPED {
                $symbol = "-"
                $color = "Gray"
                $status_text = "SKIPPED"
            }
            $script:STATUS_IN_PROGRESS {
                $symbol = "*"
                $color = "Yellow"
                $status_text = "IN PROGRESS"
            }
            $script:STATUS_PENDING {
                $symbol = "."
                $color = "DarkGray"
                $status_text = "PENDING"
            }
            $script:STATUS_FAILED {
                $symbol = [char]0x2717  # X mark
                $color = "Red"
                $status_text = "FAILED"
            }
            default {
                $symbol = "?"
                $color = "Gray"
                $status_text = $status
            }
        }

        $line = "{0}  {1}. {2} [{3}]" -f $symbol, $index, $repo, $status_text
        if($message) {
            $line += " - $message"
        }
        else {
            # no message
        }
        Write-Host $line -ForegroundColor $color
        $index++
    }

    if($Final) {
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

        # Return success (true if no failures)
        return ($failed -eq 0)
    }
    else {
        # not final, just display
    }

    Write-Host ""
}
