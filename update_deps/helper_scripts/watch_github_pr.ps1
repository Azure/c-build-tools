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

# Import common utilities
. "$PSScriptRoot\pr_watch_utils.ps1"


# Pre-fetch all data needed for display
function get-github-pr-display-data
{
    $result = $null

    # Get PR URL
    $pr_url = $null
    $pr_info = gh pr view --json url 2>&1
    if($LASTEXITCODE -eq 0)
    {
        $pr_data = $pr_info | ConvertFrom-Json
        $pr_url = $pr_data.url
    }
    else
    {
        # couldn't get PR URL
    }

    # Get PR checks status (include timing and link info)
    $checks_output = gh pr checks --json name,state,bucket,startedAt,completedAt,link 2>&1
    if($LASTEXITCODE -ne 0)
    {
        # error getting checks
    }
    else
    {
        $checks = $checks_output | ConvertFrom-Json
        if(-not $checks)
        {
            # no checks parsed
        }
        else
        {
            # Build normalized check items
            $normalized_checks = @()
            foreach($check in $checks)
            {
                $normalized_status = convert-github-bucket-to-normalized -bucket $check.bucket

                $normalized_checks += [PSCustomObject]@{
                    Name = $check.name
                    Status = $normalized_status
                    StartTime = $check.startedAt
                    FinishTime = $check.completedAt
                    Url = $check.link
                }
            }

            # Get counts using common utility
            $counts = get-check-status-counts -checks $normalized_checks

            $result = @{
                PrUrl = $pr_url
                Checks = $normalized_checks
                Counts = $counts
            }
        }
    }

    return $result
}


# Display PR status using pre-fetched data
function show-github-pr-status
{
    param(
        [hashtable] $displayData,
        [int] $poll_interval
    )

    $checks = $displayData.Checks
    $counts = $displayData.Counts

    if(-not $checks -or $checks.Count -eq 0)
    {
        Write-Host "Refreshing checks status every $poll_interval seconds. Press Ctrl+C to quit." -ForegroundColor Gray
        if($displayData.PrUrl)
        {
            Write-Host "PR: $($displayData.PrUrl)" -ForegroundColor Cyan
        }
        else
        {
            # no PR URL
        }
        Write-Host ""
        Write-Host "No checks found yet, waiting..." -ForegroundColor Yellow
    }
    else
    {
        # Use common display functions
        show-status-summary -counts $counts -pr_url $displayData.PrUrl -poll_interval $poll_interval
        show-pr-check-table -checks $checks
    }
}


# Watch GitHub PR checks until complete or timeout
function watch-github-pr-checks
{
    param(
        [int] $poll_interval = 30,
        [int] $timeout = 120,
        [scriptblock] $OnIteration = $null
    )
    $fn_result = $null

    # Define the fetch data callback - inline the data fetching logic
    $fetch_data = {
        $result = $null

        # Get PR URL
        $pr_url = $null
        $pr_info = gh pr view --json url 2>&1
        if($LASTEXITCODE -eq 0)
        {
            $pr_data = $pr_info | ConvertFrom-Json
            $pr_url = $pr_data.url
        }
        else
        {
            # couldn't get PR URL
        }

        # Get PR checks status (include timing and link info)
        $checks_output = gh pr checks --json name,state,bucket,startedAt,completedAt,link 2>&1
        if($LASTEXITCODE -ne 0)
        {
            # error getting checks
        }
        else
        {
            $checks = $checks_output | ConvertFrom-Json
            if(-not $checks)
            {
                # no checks parsed
            }
            else
            {
                # Get list of required check names
                $required_names = @{}
                $required_output = gh pr checks --required --json name 2>&1
                if($LASTEXITCODE -eq 0 -and $required_output)
                {
                    $required_checks = $required_output | ConvertFrom-Json
                    if($required_checks)
                    {
                        foreach($rc in $required_checks)
                        {
                            $required_names[$rc.name] = $true
                        }
                    }
                    else
                    {
                        # no required checks parsed
                    }
                }
                else
                {
                    # couldn't get required checks, treat all as blocking
                }

                # Build normalized check items
                $normalized_checks = @()
                foreach($check in $checks)
                {
                    $normalized_status = convert-github-bucket-to-normalized -bucket $check.bucket

                    # If we got required check info, use it; otherwise leave IsBlocking as $null (all blocking)
                    $is_blocking = $null
                    if($required_names.Count -gt 0)
                    {
                        $is_blocking = $required_names.ContainsKey($check.name)
                    }
                    else
                    {
                        # no required info available, default to blocking
                    }

                    $normalized_checks += [PSCustomObject]@{
                        Name = $check.name
                        Status = $normalized_status
                        StartTime = $check.startedAt
                        FinishTime = $check.completedAt
                        Url = $check.link
                        IsBlocking = $is_blocking
                    }
                }

                # Get counts using common utility
                $counts = get-check-status-counts -checks $normalized_checks

                $result = @{
                    PrUrl = $pr_url
                    Checks = $normalized_checks
                    Counts = $counts
                }
            }
        }

        return $result
    }

    # Define the show status callback - inline the display logic
    $show_status = {
        param($displayData)
        $checks = $displayData.Checks
        $counts = $displayData.Counts

        if(-not $checks -or $checks.Count -eq 0)
        {
            Write-Host "Refreshing checks status every $poll_interval seconds. Press Ctrl+C to quit." -ForegroundColor Gray
            if($displayData.PrUrl)
            {
                Write-Host "PR: $($displayData.PrUrl)" -ForegroundColor Cyan
            }
            else
            {
                # no PR URL
            }
            Write-Host ""
            Write-Host "No checks found yet, waiting..." -ForegroundColor Yellow
        }
        else
        {
            # Use common display functions
            show-status-summary -counts $counts -pr_url $displayData.PrUrl -poll_interval $poll_interval
            show-pr-check-table -checks $checks
        }
    }.GetNewClosure()

    # Define the test complete callback
    $test_complete = {
        param($displayData)
        Test-ChecksComplete -checks $displayData.Checks
    }

    # Use the generic watch loop
    $fn_result = watch-pr-status `
        -FetchData $fetch_data `
        -ShowStatus $show_status `
        -TestComplete $test_complete `
        -poll_interval $poll_interval `
        -timeout $timeout `
        -OnIteration $OnIteration

    return $fn_result
}
