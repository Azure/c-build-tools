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
# Windows toast notification for PR events
#
function global:show-pr-notification
{
    param(
        [string] $repo_name,
        [string] $pr_url,
        [string] $message = "PR created"
    )

    try
    {
        Add-Type -AssemblyName System.Windows.Forms
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Information
        $notify.Visible = $true
        $notify.BalloonTipTitle = $message
        $notify.BalloonTipText = "$repo_name`n$pr_url"
        $notify.ShowBalloonTip(5000)
        # Clean up after a delay so the notification stays visible
        Start-Sleep -Milliseconds 100
    }
    catch
    {
        # Toast notifications are best-effort — don't fail propagation if they don't work
    }
}


#
# Ctrl+C aware sleep - checks for Ctrl+C keypress during the sleep interval.
# If detected, prompts the user to close/abandon the current PR.
# Returns $true if propagation should be cancelled, $false otherwise.
#
function global:wait-or-cancel
{
    param(
        [int] $seconds
    )
    $cancelled = $false

    for ($i = 0; $i -lt ($seconds * 10); $i++)
    {
        Start-Sleep -Milliseconds 100
        if ([Console]::KeyAvailable)
        {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::C -and $key.Modifiers -eq [ConsoleModifiers]::Control)
            {
                $cancelled = prompt-cancel-propagation
                if ($cancelled)
                {
                    break
                }
                else
                {
                    # user chose to continue
                }
            }
            else
            {
                # ignore other keys
            }
        }
        else
        {
            # no key pressed
        }
    }

    return $cancelled
}


#
# Prompt user to close/abandon the current PR after Ctrl+C
# Returns $true if user wants to cancel, $false to continue
#
function global:prompt-cancel-propagation
{
    $result = $false

    Write-Host "`n`nCtrl+C detected." -ForegroundColor Yellow

    $pr_url = $null
    if ($global:current_repo -and $global:repo_status.ContainsKey($global:current_repo))
    {
        $pr_url = $global:repo_status[$global:current_repo].PrUrl
    }
    else
    {
        # no current repo
    }

    if ($pr_url)
    {
        Write-Host "A pull request is currently open for '$($global:current_repo)':" -ForegroundColor Yellow
        Write-Host "  $pr_url" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "What would you like to do?" -ForegroundColor Yellow
        Write-Host "  [Enter] Close the PR and stop propagation (default)" -ForegroundColor White
        Write-Host "  [n]     Stop propagation but leave the PR open" -ForegroundColor White
        Write-Host "  [r]     Go back - resume watching the PR" -ForegroundColor White
        Write-Host ""
        Write-Host "Choice: " -ForegroundColor Yellow -NoNewline

        # Restore normal input for the prompt
        [Console]::TreatControlCAsInput = $false
        $response = Read-Host
        [Console]::TreatControlCAsInput = $true

        if ($response -eq 'r' -or $response -eq 'R')
        {
            Write-Host "Resuming..." -ForegroundColor Cyan
            # result stays false = don't cancel
        }
        elseif ($response -eq 'n' -or $response -eq 'N')
        {
            Write-Host "PR left open." -ForegroundColor Cyan
            set-repo-status -repo_name $global:current_repo -status "failed" -message "Cancelled by user (PR left open)"
            $result = $true
        }
        else
        {
            # default: close PR and exit
            close-pr -repo_name $global:current_repo -pr_url $pr_url
            set-repo-status -repo_name $global:current_repo -status "failed" -message "Cancelled by user"
            # Clear PR URL so downstream error handlers don't try to close it again
            $global:repo_status[$global:current_repo].PrUrl = ""
            $result = $true
        }
    }
    else
    {
        Write-Host "What would you like to do?" -ForegroundColor Yellow
        Write-Host "  [Enter] Stop propagation (default)" -ForegroundColor White
        Write-Host "  [r]     Go back - resume propagation" -ForegroundColor White
        Write-Host ""
        Write-Host "Choice: " -ForegroundColor Yellow -NoNewline

        [Console]::TreatControlCAsInput = $false
        $response = Read-Host
        [Console]::TreatControlCAsInput = $true

        if ($response -eq 'r' -or $response -eq 'R')
        {
            Write-Host "Resuming..." -ForegroundColor Cyan
        }
        else
        {
            # default: exit
            $result = $true
        }
    }

    return $result
}


#
# Normalized Status Enum
#
# Maps platform-specific statuses to a common set of values for consistent display.
#
enum PrCheckStatus
{
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
function global:get-status-display
{
    param(
        [PrCheckStatus] $status
    )
    $result = $null

    switch($status)
    {
        ([PrCheckStatus]::Succeeded)
        {
            $result = @{
                Symbol = [char]0x2713  # checkmark ✓
                Color = "Green"
            }
        }
        ([PrCheckStatus]::Failed)
        {
            $result = @{
                Symbol = [char]0x2717  # X mark ✗
                Color = "Red"
            }
        }
        ([PrCheckStatus]::Running)
        {
            $result = @{
                Symbol = "*"
                Color = "Yellow"
            }
        }
        ([PrCheckStatus]::Pending)
        {
            $result = @{
                Symbol = "-"
                Color = "Gray"
            }
        }
        ([PrCheckStatus]::Skipped)
        {
            $result = @{
                Symbol = "-"
                Color = "DarkGray"
            }
        }
        ([PrCheckStatus]::Cancelled)
        {
            $result = @{
                Symbol = "x"
                Color = "Gray"
            }
        }
        default
        {
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
function global:convert-azure-status-to-normalized
{
    param(
        [string] $azure_status
    )
    $result = $null

    switch($azure_status.ToLower())
    {
        "approved"   { $result = [PrCheckStatus]::Succeeded }
        "succeeded"  { $result = [PrCheckStatus]::Succeeded }
        "partiallysucceeded" { $result = [PrCheckStatus]::Succeeded }
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
function global:convert-github-bucket-to-normalized
{
    param(
        [string] $bucket
    )
    $result = $null

    switch($bucket.ToLower())
    {
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
function global:format-elapsed-time
{
    param(
        [string] $start_time,
        [string] $finish_time = $null
    )
    $result = ""

    if(-not $start_time)
    {
        # no start time provided
    }
    else
    {
        $start_parsed = Get-Date -Date $start_time -ErrorAction SilentlyContinue
        if(-not $start_parsed)
        {
            # parse error
        }
        else
        {
            $start = $start_parsed.ToUniversalTime()
            $duration = $null

            if($finish_time)
            {
                $finish_parsed = Get-Date -Date $finish_time -ErrorAction SilentlyContinue
                if($finish_parsed)
                {
                    $finish = $finish_parsed.ToUniversalTime()
                    $duration = $finish - $start
                }
                else
                {
                    # finish time parse error
                }
            }
            else
            {
                # No finish time, calculate from now
                $duration = (Get-Date).ToUniversalTime() - $start
            }

            if($duration -and $duration.TotalSeconds -ge 0)
            {
                if($duration.TotalHours -ge 1)
                {
                    $result = "{0}h{1}m" -f [int]$duration.TotalHours, $duration.Minutes
                }
                elseif($duration.TotalMinutes -ge 1)
                {
                    $result = "{0}m{1}s" -f [int]$duration.TotalMinutes, $duration.Seconds
                }
                else
                {
                    $result = "{0}s" -f [int]$duration.TotalSeconds
                }
            }
            else
            {
                # negative or null duration
            }
        }
    }

    return $result
}


#
# Truncate string to fit width
#
function global:truncate-string
{
    param(
        [string] $text,
        [int] $max_width
    )
    $result = $null

    if(-not $text)
    {
        $result = ""
    }
    elseif($text.Length -le $max_width)
    {
        $result = $text
    }
    else
    {
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
function global:show-pr-check-table
{
    param(
        [array] $checks
    )

    # Calculate actual content widths
    $max_name_width = ($checks | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
    $max_url_width = ($checks | ForEach-Object { if($_.Url) { $_.Url.Length } else { 0 } } | Measure-Object -Maximum).Maximum
    $elapsed_width = 12  # Fixed width for elapsed time column
    $prefix_width = 3    # Symbol + 2 spaces

    # Ensure minimum widths
    $max_name_width = [Math]::Max($max_name_width, 4)  # "NAME"
    $max_url_width = [Math]::Max($max_url_width, 3)    # "URL"

    # Get terminal width
    $terminal_width = 120  # Default fallback
    try
    {
        $terminal_width = $Host.UI.RawUI.WindowSize.Width
    }
    catch
    {
        # Use default if can't get window size
    }

    # Calculate available space: terminal - prefix - elapsed - spaces between columns
    $available_width = $terminal_width - $prefix_width - $elapsed_width - 2  # 2 spaces between name/elapsed and elapsed/url

    # Determine final column widths
    $name_width = $max_name_width
    $url_width = $max_url_width

    $total_needed = $name_width + $url_width
    if($total_needed -gt $available_width)
    {
        # Need to truncate - prioritize name over url
        $min_name_width = [Math]::Min($max_name_width, 50)
        $min_url_width = 20

        # First try to fit by truncating URL
        if($max_name_width + $min_url_width -le $available_width)
        {
            $name_width = $max_name_width
            $url_width = $available_width - $name_width
        }
        # Then truncate name if needed
        elseif($min_name_width + $min_url_width -le $available_width)
        {
            $url_width = $min_url_width
            $name_width = $available_width - $url_width
        }
        else
        {
            # Very narrow terminal - split proportionally
            $name_width = [Math]::Max($min_name_width, [int]($available_width * 0.6))
            $url_width = [Math]::Max($min_url_width, $available_width - $name_width)
        }
    }

    # Table header
    $header = "   {0,-$name_width} {1,-$elapsed_width} {2}" -f "NAME", "ELAPSED", "URL"
    Write-Host $header -ForegroundColor White

    # Display each check
    foreach($check in $checks)
    {
        $check_name = $check.Name
        # Mark optional (non-blocking) checks
        if($check.IsBlocking -eq $false)
        {
            $check_name = $check_name + " (optional)"
        }
        else
        {
            # required or unknown blocking status
        }
        $check_name = truncate-string -text $check_name -max_width $name_width
        $elapsed = format-elapsed-time -start_time $check.StartTime -finish_time $check.FinishTime
        $url = truncate-string -text $check.Url -max_width $url_width

        $display = get-status-display -status $check.Status
        $symbol = $display.Symbol
        $color = $display.Color

        # Use dimmer color for optional failed checks
        if($check.IsBlocking -eq $false -and $check.Status -eq [PrCheckStatus]::Failed)
        {
            $color = "DarkYellow"
        }
        else
        {
            # use default color
        }

        $line = "{0}  {1,-$name_width} {2,-$elapsed_width} {3}" -f $symbol, $check_name, $elapsed, $url
        Write-Host $line -ForegroundColor $color
    }
}


#
# Count checks by status
#
function global:get-check-status-counts
{
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
function global:Test-ChecksComplete
{
    param(
        [array] $checks
    )
    $result = $null

    if(-not $checks -or $checks.Count -eq 0)
    {
        $result = @{ Complete = $false; Success = $false; Message = "No checks found" }
    }
    else
    {
        # Filter out license/CLA checks and manual approval checks (e.g., Proof Of Presence)
        # — these don't indicate CI build status
        $ci_checks = $checks | Where-Object { $_.Name -notmatch "license|cla|proof.of.presence" }
        $filtered_count = $checks.Count - @($ci_checks).Count
        Write-Verbose "Test-ChecksComplete: $($checks.Count) total checks, $filtered_count filtered (license/cla/proof), $(@($ci_checks).Count) CI checks"

        if (-not $ci_checks -or $ci_checks.Count -eq 0)
        {
            # Only license/CLA checks present — CI hasn't started yet
            $result = @{ Complete = $false; Success = $false; Message = "Waiting for CI checks to appear" }
        }
        else
        {
            # Filter to blocking checks (if IsBlocking exists, use it; otherwise all are blocking)
            $blocking_checks = $ci_checks | Where-Object {
                $_.IsBlocking -eq $true -or $_.IsBlocking -eq $null
            }
            $non_blocking = @($ci_checks | Where-Object { $_.IsBlocking -eq $false })
            Write-Verbose "Test-ChecksComplete: $(@($blocking_checks).Count) blocking, $($non_blocking.Count) non-blocking"

        # Check if any BUILD check has failed — no need to wait for others.
        # Check all Build checks regardless of IsBlocking — a failed build is
        # always actionable, even if the policy is marked non-blocking.
        $failed_builds = $ci_checks | Where-Object {
            $_.Status -eq [PrCheckStatus]::Failed -and $_.Name -match "^Build"
        }
        $all_failed = @($ci_checks | Where-Object { $_.Status -eq [PrCheckStatus]::Failed })
        if ($all_failed.Count -gt 0)
        {
            $all_failed_names = ($all_failed | ForEach-Object { "$($_.Name) [IsBlocking=$($_.IsBlocking)]" }) -join ", "
            Write-Verbose "Test-ChecksComplete: All failed checks: $all_failed_names"
        }
        if($failed_builds.Count -gt 0)
        {
            $failed_names = ($failed_builds | ForEach-Object { $_.Name }) -join ", "
            $result = @{ Complete = $true; Success = $false; Message = "Failed: $failed_names" }
        }
        else
        {
            # Check if any blocking check is still in progress
            $in_progress = $blocking_checks | Where-Object {
                $_.Status -eq [PrCheckStatus]::Running -or $_.Status -eq [PrCheckStatus]::Pending
            }

            if($in_progress.Count -gt 0)
            {
                $in_progress_names = ($in_progress | ForEach-Object { $_.Name }) -join ", "
                $result = @{ Complete = $false; Success = $false; Message = "Waiting for: $in_progress_names" }
            }
            else
            {
                # All checks have reached terminal state with no failures
                $cancelled = $blocking_checks | Where-Object { $_.Status -eq [PrCheckStatus]::Cancelled }
                $succeeded = $blocking_checks | Where-Object { $_.Status -eq [PrCheckStatus]::Succeeded }

                if($cancelled.Count -gt 0 -and $succeeded.Count -eq 0)
                {
                    $result = @{ Complete = $true; Success = $false; Message = "Checks were cancelled" }
                }
                else
                {
                    $result = @{ Complete = $true; Success = $true; Message = "All checks passed" }
                }
            }
        }
        }
    }

    return $result
}


#
# Display summary status header
#
function global:show-status-summary
{
    param(
        [hashtable] $counts,
        [string] $pr_url = $null,
        [int] $poll_interval = 30
    )

    Write-Host "Refreshing checks status every $poll_interval seconds. Press Ctrl+C to quit." -ForegroundColor Gray
    if($pr_url)
    {
        Write-Host "PR: $pr_url" -ForegroundColor Cyan
    }
    else
    {
        # no PR URL
    }
    Write-Host ""

    # Summary status
    if($counts.Failed -gt 0)
    {
        Write-Host "Some checks were not successful" -ForegroundColor Red
    }
    elseif($counts.InProgress -gt 0)
    {
        Write-Host "Some checks are still pending" -ForegroundColor Yellow
    }
    else
    {
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
function global:watch-pr-status
{
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

    while($fn_result -eq $null)
    {
        # Check timeout
        if((Get-Date) -gt $timeout_time)
        {
            Write-Host "`nTimeout reached after $timeout minutes" -ForegroundColor Red
            Write-Verbose "watch-pr-status timeout: started=$start_time, now=$(Get-Date), timeout_at=$timeout_time"
            $fn_result = @{ Success = $false; Message = "Timeout" }
        }
        else
        {
            # Pre-fetch all data before clearing screen
            $fetch_interrupted = $false
            try
            {
                $display_data = & $FetchData
            }
            catch
            {
                # Ctrl+C during external command (az, gh) lands here
                $display_data = $null
                $fetch_interrupted = $true
            }

            if ($fetch_interrupted)
            {
                # Ctrl+C hit during fetch — show the cancellation prompt
                [Console]::TreatControlCAsInput = $false
                $cancelled = prompt-cancel-propagation
                [Console]::TreatControlCAsInput = $true
                if ($cancelled)
                {
                    $global:propagation_cancelled = $true
                    $fn_result = @{ Success = $false; Message = "Cancelled by user" }
                }
                else
                {
                    # user chose to resume, continue the loop
                }
            }
            elseif(-not $display_data)
            {
                Write-Host "Failed to get checks status, retrying..." -ForegroundColor Yellow
                $cancelled = wait-or-cancel -seconds $poll_interval
                if ($cancelled)
                {
                    $global:propagation_cancelled = $true
                    $fn_result = @{ Success = $false; Message = "Cancelled by user" }
                }
                else
                {
                    # continue loop with fn_result still null
                }
            }
            else
            {
                # Clear screen and show status
                Clear-Host
                & $ShowStatus $display_data

                # Run callback if provided
                if($OnIteration)
                {
                    Write-Host ""
                    & $OnIteration
                }
                else
                {
                    # no callback
                }

                # Check if complete
                $completion_result = & $TestComplete $display_data
                Write-Verbose "TestComplete: Complete=$($completion_result.Complete), Success=$($completion_result.Success), Message='$($completion_result.Message)'"
                if($completion_result.Complete)
                {
                    Write-Host ""
                    $fn_result = $completion_result
                }
                else
                {
                    $cancelled = wait-or-cancel -seconds $poll_interval
                    if ($cancelled)
                    {
                        $global:propagation_cancelled = $true
                        $fn_result = @{ Success = $false; Message = "Cancelled by user" }
                    }
                    else
                    {
                        # continue polling
                    }
                }
            }
        }
    }

    return $fn_result
}
