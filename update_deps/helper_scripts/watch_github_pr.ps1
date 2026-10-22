# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS

Watch GitHub PR check status until all checks pass or one fails.

.DESCRIPTION

Similar to 'gh pr checks --watch', but allows custom callbacks during polling
to display additional status information (e.g., propagation status).
Loaded by load_helpers.ps1; uses the common watch loop in pr_watch_utils.ps1.

.EXAMPLE

PS> watch-github-pr-checks -pr_url https://github.com/Azure/c-pal/pull/123 -poll_interval 30 -timeout 120
#>


# Pre-fetch all data needed for display. Global so the watch loop's closures can call it.
function global:get-github-pr-display-data
{
    param(
        [string] $pr_url
    )
    $result = $null

    # Get PR checks status (include timing and link info)
    $checks = (get-github-pr-checks -pr_url $pr_url -fields 'name,state,bucket,startedAt,completedAt,link').Checks
    if (-not $checks)
    {
        # no checks reported yet, or they could not be read
    }
    else
    {
        # Build normalized check items
        $normalized_checks = @()
        foreach($check in $checks)
        {
            $normalized_checks += [PSCustomObject]@{
                Name = $check.name
                Status = (convert-github-bucket-to-normalized -bucket $check.bucket)
                StartTime = $check.startedAt
                FinishTime = $check.completedAt
                Url = $check.link
            }
        }

        $result = @{
            PrUrl = $pr_url
            Checks = $normalized_checks
            Counts = (get-check-status-counts -checks $normalized_checks)
        }
    }

    return $result
}


# Watch GitHub PR checks until complete or timeout
function watch-github-pr-checks
{
    param(
        [string] $pr_url,
        [int] $poll_interval = 30,
        [int] $timeout = 120,
        [scriptblock] $OnIteration = $null
    )

    $fetch_data = {
        get-github-pr-display-data -pr_url $pr_url
    }.GetNewClosure()

    $show_status = {
        param($displayData)
        show-pr-watch-status -displayData $displayData -poll_interval $poll_interval -empty_message "No checks found yet, waiting..."
    }.GetNewClosure()

    $test_complete = {
        param($displayData)
        Test-ChecksComplete -checks $displayData.Checks
    }

    # Use the generic watch loop
    return (watch-pr-status `
        -FetchData $fetch_data `
        -ShowStatus $show_status `
        -TestComplete $test_complete `
        -poll_interval $poll_interval `
        -timeout $timeout `
        -OnIteration $OnIteration)
}
