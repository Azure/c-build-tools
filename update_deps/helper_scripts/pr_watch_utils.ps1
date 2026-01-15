# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS

Common utilities for watching PR status across different platforms.

.DESCRIPTION

This module provides normalized status enums, display formatting functions, and a generic
watch loop that can be used by both Azure DevOps and GitHub PR watching scripts.

#>


#
# Normalized Status Enum
#
# Maps platform-specific statuses to a common set of values for consistent display.
#
enum PrCheckStatus {
    Pending     # Queued, waiting to start
    Running     # Currently executing
    Succeeded   # Completed successfully
    Failed      # Completed with failure
    Skipped     # Skipped/not applicable
    Cancelled   # Cancelled before completion
    Unknown     # Unknown status
}


#
# Status Display Configuration
#
# Maps normalized status to symbol and color for consistent display.
#
function get-status-display {
    param(
        [PrCheckStatus] $status
    )
    $result = $null

    switch($status) {
        ([PrCheckStatus]::Succeeded) {
            $result = @{
                Symbol = [char]0x2713  # checkmark ✓
                Color = "Green"
            }
        }
        ([PrCheckStatus]::Failed) {
            $result = @{
                Symbol = [char]0x2717  # X mark ✗
                Color = "Red"
            }
        }
        ([PrCheckStatus]::Running) {
            $result = @{
                Symbol = "*"
                Color = "Yellow"
            }
        }
        ([PrCheckStatus]::Pending) {
            $result = @{
                Symbol = "-"
                Color = "Gray"
            }
        }
        ([PrCheckStatus]::Skipped) {
            $result = @{
                Symbol = "-"
                Color = "DarkGray"
            }
        }
        ([PrCheckStatus]::Cancelled) {
            $result = @{
                Symbol = "x"
                Color = "Gray"
            }
        }
        default {
            $result = @{
                Symbol = "?"
                Color = "DarkYellow"
            }
        }
    }

    return $result
}


#
# Azure DevOps Status Mapping
#
function convert-azure-status-to-normalized {
    param(
        [string] $azure_status
    )
    $result = $null

    switch($azure_status.ToLower()) {
        "approved"   { $result = [PrCheckStatus]::Succeeded }
        "succeeded"  { $result = [PrCheckStatus]::Succeeded }
        "rejected"   { $result = [PrCheckStatus]::Failed }
        "failed"     { $result = [PrCheckStatus]::Failed }
        "running"    { $result = [PrCheckStatus]::Running }
        "inprogress" { $result = [PrCheckStatus]::Running }
        "queued"     { $result = [PrCheckStatus]::Pending }
        "pending"    { $result = [PrCheckStatus]::Pending }
        "notstarted" { $result = [PrCheckStatus]::Pending }
        "canceled"   { $result = [PrCheckStatus]::Cancelled }
        "cancelled"  { $result = [PrCheckStatus]::Cancelled }
        "skipped"    { $result = [PrCheckStatus]::Skipped }
        default      { $result = [PrCheckStatus]::Unknown }
    }

    return $result
}


#
# GitHub Status Mapping (uses bucket field from gh pr checks)
#
function convert-github-bucket-to-normalized {
    param(
        [string] $bucket
    )
    $result = $null

    switch($bucket.ToLower()) {
        "pass"     { $result = [PrCheckStatus]::Succeeded }
        "fail"     { $result = [PrCheckStatus]::Failed }
        "pending"  { $result = [PrCheckStatus]::Running }
        "skipping" { $result = [PrCheckStatus]::Skipped }
        "cancel"   { $result = [PrCheckStatus]::Cancelled }
        default    { $result = [PrCheckStatus]::Unknown }
    }

    return $result
}


#
# Format elapsed time duration
#
function format-elapsed-time {
    param(
        [string] $start_time,
        [string] $finish_time = $null
    )
    $result = ""

    if(-not $start_time) {
        $result = ""
    }
    else {
        $start_parsed = Get-Date -Date $start_time -ErrorAction SilentlyContinue
        if(-not $start_parsed) {
            $result = ""
        }
        else {
            $start = $start_parsed.ToUniversalTime()
            $duration = $null

            if($finish_time) {
                $finish_parsed = Get-Date -Date $finish_time -ErrorAction SilentlyContinue
                if($finish_parsed) {
                    $finish = $finish_parsed.ToUniversalTime()
                    $duration = $finish - $start
                }
                else {
                    # finish time parse error
                }
            }
            else {
                # No finish time, calculate from now
                $duration = (Get-Date).ToUniversalTime() - $start
            }

            if($duration -and $duration.TotalSeconds -ge 0) {
                if($duration.TotalHours -ge 1) {
                    $result = "{0}h{1}m" -f [int]$duration.TotalHours, $duration.Minutes
                }
                elseif($duration.TotalMinutes -ge 1) {
                    $result = "{0}m{1}s" -f [int]$duration.TotalMinutes, $duration.Seconds
                }
                else {
                    $result = "{0}s" -f [int]$duration.TotalSeconds
                }
            }
            else {
                # negative or null duration
                $result = ""
            }
        }
    }

    return $result
}


#
# Truncate string to fit width
#
function truncate-string {
    param(
        [string] $text,
        [int] $max_width
    )
    $result = $null

    if(-not $text) {
        $result = ""
    }
    elseif($text.Length -le $max_width) {
        $result = $text
    }
    else {
        $result = $text.Substring(0, $max_width - 3) + "..."
    }

    return $result
}


#
# Normalized Check Item structure
#
# Properties:
#   Name       - Display name of the check
#   Status     - PrCheckStatus enum value
#   StartTime  - Start time string (can be null)
#   FinishTime - Finish time string (can be null)
#   Url        - URL to the check details (can be null/empty)
#


#
# Display normalized check items in a table
#
function show-pr-check-table {
    param(
        [array] $checks,
        [int] $name_width = 70,
        [int] $elapsed_width = 12,
        [int] $url_width = 80
    )

    # Table header
    $header = "   {0,-$name_width} {1,-$elapsed_width} {2}" -f "NAME", "ELAPSED", "URL"
    Write-Host $header -ForegroundColor White

    # Display each check
    foreach($check in $checks) {
        $check_name = truncate-string -text $check.Name -max_width $name_width
        $elapsed = format-elapsed-time -start_time $check.StartTime -finish_time $check.FinishTime
        $url = truncate-string -text $check.Url -max_width $url_width

        $display = get-status-display -status $check.Status
        $symbol = $display.Symbol
        $color = $display.Color

        $line = "{0}  {1,-$name_width} {2,-$elapsed_width} {3}" -f $symbol, $check_name, $elapsed, $url
        Write-Host $line -ForegroundColor $color
    }
}


#
# Count checks by status
#
function get-check-status-counts {
    param(
        [array] $checks
    )
    $result = $null

    $succeeded_count = ($checks | Where-Object { $_.Status -eq [PrCheckStatus]::Succeeded }).Count
    $failed_count = ($checks | Where-Object { $_.Status -eq [PrCheckStatus]::Failed }).Count
    $running_count = ($checks | Where-Object { $_.Status -eq [PrCheckStatus]::Running }).Count
    $pending_count = ($checks | Where-Object { $_.Status -eq [PrCheckStatus]::Pending }).Count
    $skipped_count = ($checks | Where-Object { $_.Status -eq [PrCheckStatus]::Skipped }).Count
    $cancelled_count = ($checks | Where-Object { $_.Status -eq [PrCheckStatus]::Cancelled }).Count
    $unknown_count = ($checks | Where-Object { $_.Status -eq [PrCheckStatus]::Unknown }).Count

    $result = @{
        Succeeded = $succeeded_count
        Failed = $failed_count
        Running = $running_count
        Pending = $pending_count
        Skipped = $skipped_count
        Cancelled = $cancelled_count
        Unknown = $unknown_count
        InProgress = $running_count + $pending_count
        Total = $checks.Count
    }

    return $result
}


#
# Test if checks are complete
#
# For Azure DevOps: checks have IsBlocking property, only blocking checks matter
# For GitHub: all checks matter (IsBlocking = $null means treat as blocking)
#
function Test-ChecksComplete {
    param(
        [array] $checks
    )
    $result = $null

    if(-not $checks -or $checks.Count -eq 0) {
        $result = @{ Complete = $false; Success = $false; Message = "No checks found" }
    }
    else {
        # Filter to blocking checks (if IsBlocking exists, use it; otherwise all are blocking)
        $blocking_checks = $checks | Where-Object {
            $_.IsBlocking -eq $true -or $_.IsBlocking -eq $null
        }

        # Check if any blocking check is still in progress
        $in_progress = $blocking_checks | Where-Object {
            $_.Status -eq [PrCheckStatus]::Running -or $_.Status -eq [PrCheckStatus]::Pending
        }

        if($in_progress.Count -gt 0) {
            $in_progress_names = ($in_progress | ForEach-Object { $_.Name }) -join ", "
            $result = @{ Complete = $false; Success = $false; Message = "Waiting for: $in_progress_names" }
        }
        else {
            # All checks have reached terminal state - check if any failed
            $failed = $blocking_checks | Where-Object { $_.Status -eq [PrCheckStatus]::Failed }
            $cancelled = $blocking_checks | Where-Object { $_.Status -eq [PrCheckStatus]::Cancelled }
            $succeeded = $blocking_checks | Where-Object { $_.Status -eq [PrCheckStatus]::Succeeded }

            if($failed.Count -gt 0) {
                $failed_names = ($failed | ForEach-Object { $_.Name }) -join ", "
                $result = @{ Complete = $true; Success = $false; Message = "Failed: $failed_names" }
            }
            elseif($cancelled.Count -gt 0 -and $succeeded.Count -eq 0) {
                $result = @{ Complete = $true; Success = $false; Message = "Checks were cancelled" }
            }
            else {
                $result = @{ Complete = $true; Success = $true; Message = "All checks passed" }
            }
        }
    }

    return $result
}


#
# Display summary status header
#
function show-status-summary {
    param(
        [hashtable] $counts,
        [string] $pr_url = $null,
        [int] $poll_interval = 30
    )

    Write-Host "Refreshing checks status every $poll_interval seconds. Press Ctrl+C to quit." -ForegroundColor Gray
    if($pr_url) {
        Write-Host "PR: $pr_url" -ForegroundColor Cyan
    }
    else {
        # no PR URL
    }
    Write-Host ""

    # Summary status
    if($counts.Failed -gt 0) {
        Write-Host "Some checks were not successful" -ForegroundColor Red
    }
    elseif($counts.InProgress -gt 0) {
        Write-Host "Some checks are still pending" -ForegroundColor Yellow
    }
    else {
        Write-Host "All checks were successful" -ForegroundColor Green
    }

    # Stats line
    $stats = "{0} cancelled, {1} failing, {2} successful, {3} skipped, and {4} pending checks`n" -f `
        $counts.Cancelled, $counts.Failed, $counts.Succeeded, $counts.Skipped, $counts.InProgress
    Write-Host $stats -ForegroundColor Gray
}


#
# Generic PR watch loop
#
# Parameters:
#   FetchData     - ScriptBlock that returns display data (checks array, pr_url, etc.)
#   ShowStatus    - ScriptBlock that displays the status given display data
#   TestComplete  - ScriptBlock that returns @{ Complete = $bool; Success = $bool; Message = $string }
#   poll_interval - Seconds between polls
#   timeout       - Minutes before timeout
#   OnIteration   - Optional callback after each status display
#
function watch-pr-status {
    param(
        [scriptblock] $FetchData,
        [scriptblock] $ShowStatus,
        [scriptblock] $TestComplete,
        [int] $poll_interval = 30,
        [int] $timeout = 120,
        [scriptblock] $OnIteration = $null
    )
    $fn_result = $null

    $start_time = Get-Date
    $timeout_time = $start_time.AddMinutes($timeout)

    Write-Host "Watching PR checks..." -ForegroundColor Cyan
    Write-Host "Poll interval: ${poll_interval}s, Timeout: ${timeout}m`n"

    while($fn_result -eq $null) {
        # Check timeout
        if((Get-Date) -gt $timeout_time) {
            Write-Host "`nTimeout reached after $timeout minutes" -ForegroundColor Red
            $fn_result = @{ Success = $false; Message = "Timeout" }
        }
        else {
            # Pre-fetch all data before clearing screen
            $display_data = & $FetchData
            if(-not $display_data) {
                Write-Host "Failed to get checks status, retrying..." -ForegroundColor Yellow
                Start-Sleep -Seconds $poll_interval
                # continue loop with fn_result still null
            }
            else {
                # Clear screen and show status
                Clear-Host
                & $ShowStatus -displayData $display_data

                # Run callback if provided
                if($OnIteration) {
                    Write-Host ""
                    & $OnIteration
                }
                else {
                    # no callback
                }

                # Check if complete
                $completion_result = & $TestComplete -displayData $display_data
                if($completion_result.Complete) {
                    Write-Host ""
                    $fn_result = $completion_result
                }
                else {
                    Start-Sleep -Seconds $poll_interval
                }
            }
        }
    }

    return $fn_result
}

