# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS

Watch GitHub PR check status until all checks pass or one fails.

.DESCRIPTION

Similar to 'gh pr checks --watch', but allows custom callbacks during polling
to display additional status information (e.g., propagation status).

.PARAMETER poll_interval

How often to poll for updates in seconds. Default is 30.

.PARAMETER timeout

Maximum time to wait in minutes. Default is 120 (2 hours).

.PARAMETER OnIteration

Optional script block to run after each status display.

.EXAMPLE

PS> Watch-GitHubPRChecks -poll_interval 30 -timeout 120
#>

param(
    [int]$poll_interval = 30,
    [int]$timeout = 120
)


# Watch GitHub PR checks until complete or timeout
function watch-github-pr-checks {
    param(
        [int] $poll_interval = 30,
        [int] $timeout = 120,
        [scriptblock] $OnIteration = $null
    )

    $start_time = Get-Date
    $timeout_time = $start_time.AddMinutes($timeout)

    Write-Host "Watching PR checks..." -ForegroundColor Cyan
    Write-Host "Poll interval: ${poll_interval}s, Timeout: ${timeout}m`n"

    while($true) {
        # Check timeout
        if((Get-Date) -gt $timeout_time) {
            Write-Host "`nTimeout reached after $timeout minutes" -ForegroundColor Red
            return @{ Success = $false; Message = "Timeout" }
        }

        # Pre-fetch all data before clearing screen (avoids blank screen during API calls)
        $displayData = get-github-pr-display-data
        if(-not $displayData) {
            Write-Host "Failed to get checks status, retrying..." -ForegroundColor Yellow
            Start-Sleep -Seconds $poll_interval
            continue
        }

        # Clear screen and immediately show pre-fetched data
        Clear-Host
        show-github-pr-status -displayData $displayData -poll_interval $poll_interval

        # Run callback if provided
        if($OnIteration) {
            Write-Host ""
            & $OnIteration
        }

        # Check if complete
        if($displayData.PendingCount -eq 0) {
            Write-Host ""
            if($displayData.FailCount -gt 0) {
                return @{ Success = $false; Message = "One or more checks failed" }
            } elseif($displayData.CancelCount -gt 0 -and $displayData.PassCount -eq 0) {
                return @{ Success = $false; Message = "Checks were cancelled" }
            } else {
                return @{ Success = $true; Message = "All checks passed" }
            }
        }

        Start-Sleep -Seconds $poll_interval
    }
}


# Pre-fetch all data needed for display
function get-github-pr-display-data {
    # Get PR URL
    $pr_url = $null
    $pr_info = gh pr view --json url 2>&1
    if($LASTEXITCODE -eq 0) {
        $pr_data = $pr_info | ConvertFrom-Json
        $pr_url = $pr_data.url
    }

    # Get PR checks status (include timing and link info)
    $checks_output = gh pr checks --json name,state,bucket,startedAt,completedAt,link 2>&1
    if($LASTEXITCODE -ne 0) {
        return $null
    }

    $checks = $checks_output | ConvertFrom-Json
    if(-not $checks) {
        return $null
    }

    # Count statuses using bucket field
    $pass_count = ($checks | Where-Object { $_.bucket -eq "pass" }).Count
    $fail_count = ($checks | Where-Object { $_.bucket -eq "fail" }).Count
    $pending_count = ($checks | Where-Object { $_.bucket -eq "pending" }).Count
    $skipping_count = ($checks | Where-Object { $_.bucket -eq "skipping" }).Count
    $cancel_count = ($checks | Where-Object { $_.bucket -eq "cancel" }).Count

    return @{
        PrUrl = $pr_url
        Checks = $checks
        PassCount = $pass_count
        FailCount = $fail_count
        PendingCount = $pending_count
        SkippingCount = $skipping_count
        CancelCount = $cancel_count
    }
}


# Display PR status using pre-fetched data
function show-github-pr-status {
    param(
        [hashtable] $displayData,
        [int] $poll_interval
    )

    Write-Host "Refreshing checks status every $poll_interval seconds. Press Ctrl+C to quit." -ForegroundColor Gray
    if($displayData.PrUrl) {
        Write-Host "PR: $($displayData.PrUrl)" -ForegroundColor Cyan
    }
    Write-Host ""

    $checks = $displayData.Checks
    if(-not $checks -or $checks.Count -eq 0) {
        Write-Host "No checks found yet, waiting..." -ForegroundColor Yellow
        return
    }

    # Summary status
    if($displayData.FailCount -gt 0) {
        Write-Host "Some checks were not successful" -ForegroundColor Red
    } elseif($displayData.PendingCount -gt 0) {
        Write-Host "Some checks are still pending" -ForegroundColor Yellow
    } else {
        Write-Host "All checks were successful" -ForegroundColor Green
    }

    # Stats line
    Write-Host "$($displayData.CancelCount) cancelled, $($displayData.FailCount) failing, $($displayData.PassCount) successful, $($displayData.SkippingCount) skipped, and $($displayData.PendingCount) pending checks`n" -ForegroundColor Gray

    # Column widths
    $name_width = 70
    $elapsed_width = 12

    # Table header
    $header = "   {0,-$name_width} {1,-$elapsed_width} {2}" -f "NAME", "ELAPSED", "URL"
    Write-Host $header -ForegroundColor White

    # Display each check
    foreach($check in $checks) {
        $check_name = $check.name

        # Truncate long names
        if($check_name.Length -gt $name_width) {
            $check_name = $check_name.Substring(0, $name_width - 3) + "..."
        }

        # Calculate elapsed/duration time
        $elapsed = ""
        if($check.startedAt) {
            try {
                $start = [DateTime]::Parse($check.startedAt).ToUniversalTime()
                if($check.completedAt) {
                    $finish = [DateTime]::Parse($check.completedAt).ToUniversalTime()
                    $duration = $finish - $start
                } else {
                    $duration = (Get-Date).ToUniversalTime() - $start
                }
                if($duration.TotalSeconds -ge 0) {
                    if($duration.TotalHours -ge 1) {
                        $elapsed = "{0}h{1}m" -f [int]$duration.TotalHours, $duration.Minutes
                    } elseif($duration.TotalMinutes -ge 1) {
                        $elapsed = "{0}m{1}s" -f [int]$duration.TotalMinutes, $duration.Seconds
                    } else {
                        $elapsed = "{0}s" -f [int]$duration.TotalSeconds
                    }
                }
            } catch {}
        }

        # Get URL
        $url = if($check.link) { $check.link } else { "" }

        # Choose symbol and color based on bucket
        switch($check.bucket) {
            "pass" {
                $symbol = [char]0x2713  # checkmark
                $color = "Green"
            }
            "fail" {
                $symbol = [char]0x2717  # X mark
                $color = "Red"
            }
            "pending" {
                $symbol = "*"
                $color = "Yellow"
            }
            "skipping" {
                $symbol = "-"
                $color = "Gray"
            }
            "cancel" {
                $symbol = "x"
                $color = "Gray"
            }
            default {
                $symbol = "?"
                $color = "Gray"
            }
        }

        $line = "{0}  {1,-$name_width} {2,-$elapsed_width} {3}" -f $symbol, $check_name, $elapsed, $url
        Write-Host $line -ForegroundColor $color
    }
}
