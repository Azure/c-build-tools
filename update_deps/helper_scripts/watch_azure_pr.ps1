# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS

Watch Azure DevOps PR policy status until all policies pass or one fails.

.DESCRIPTION

Similar to 'gh pr checks --watch', this script polls the policy status of an Azure DevOps PR
and displays updates in real-time until all blocking policies are approved or one is rejected.

.PARAMETER pr_id

The ID of the pull request to watch.

.PARAMETER org

The Azure DevOps organization URL (e.g., https://dev.azure.com/msazure).

.PARAMETER poll_interval

How often to poll for updates in seconds. Default is 30.

.PARAMETER timeout

Maximum time to wait in minutes. Default is 120 (2 hours).

.EXAMPLE

PS> .\watch_azure_pr.ps1 -pr_id 14336583 -org "https://dev.azure.com/msazure"
#>

param(
    [int]$pr_id = 0,
    [string]$org = "",
    [int]$poll_interval = 30,
    [int]$timeout = 120
)

# Import common utilities
. "$PSScriptRoot\pr_watch_utils.ps1"


# Get policy status for Azure PR
function global:get-azure-pr-policies
{
    param(
        [int] $pr_id,
        [string] $org
    )
    $result = $null

    $policy_output = az repos pr policy list `
        --id $pr_id `
        --organization $org `
        --query "[].{Policy:configuration.type.displayName, Status:status, BuildId:context.buildId, ProjectId:configuration.settings.scope[0].repositoryId, IsBlocking:configuration.isBlocking}" `
        --output json 2>$null

    if($LASTEXITCODE -ne 0 -or !$policy_output)
    {
        # error or no output
    }
    else
    {
        # Get the project info from the PR for build timeline lookups and URLs
        $pr_info = az repos pr show --id $pr_id --org $org --query "{ProjectId:repository.project.id, ProjectName:repository.project.name, OrgUrl:repository.project.url, RepoName:repository.name}" -o json 2>$null
        $project_id = $null
        $project_name = $null
        $base_url = $null
        $repo_name = $null
        if($pr_info)
        {
            $pr_data = $pr_info | ConvertFrom-Json
            $project_id = $pr_data.ProjectId
            $project_name = $pr_data.ProjectName
            $repo_name = $pr_data.RepoName
            # Extract base URL from project URL (e.g., https://msazure.visualstudio.com/_apis/projects/... -> https://msazure.visualstudio.com)
            if($pr_data.OrgUrl -match '^(https://[^/]+)')
            {
                $base_url = $matches[1]
            }
            else
            {
                # no match
            }
        }
        else
        {
            # no pr_info
        }

        $policies = $policy_output | ConvertFrom-Json

        # Build PR URL
        $pr_url = $null
        if($base_url -and $project_name -and $repo_name)
        {
            $pr_url = "$base_url/$project_name/_git/$repo_name/pullrequest/$pr_id"
        }
        else
        {
            # can't build PR URL
        }

        # Attach project info to policies with builds
        foreach($policy in $policies)
        {
            # Always attach PR URL for reference
            $policy | Add-Member -NotePropertyName "PrUrl" -NotePropertyValue $pr_url -Force
            if($policy.BuildId -and $project_id)
            {
                $policy | Add-Member -NotePropertyName "ProjectId" -NotePropertyValue $project_id -Force
                $policy | Add-Member -NotePropertyName "ProjectName" -NotePropertyValue $project_name -Force
                $policy | Add-Member -NotePropertyName "BaseUrl" -NotePropertyValue $base_url -Force
            }
            else
            {
                # no build info to attach
            }
        }

        $result = $policies
    }

    return $result
}


# Get build job details from timeline
function global:get-build-job-details
{
    param(
        [int] $build_id,
        [string] $project_id,
        [string] $org
    )
    $result = $null

    $timeline = az devops invoke `
        --area build `
        --resource timeline `
        --route-parameters project=$project_id buildId=$build_id `
        --org $org `
        --api-version 7.1 `
        -o json 2>$null

    if($LASTEXITCODE -ne 0 -or !$timeline)
    {
        # error or no output
    }
    else
    {
        $records = ($timeline | ConvertFrom-Json).records
        $jobs = $records | Where-Object { $_.type -eq "Job" }

        $result = $jobs | ForEach-Object {
            [PSCustomObject]@{
                Name = $_.name
                State = $_.state
                Result = $_.result
                StartTime = $_.startTime
                FinishTime = $_.finishTime
            }
        }
    }

    return $result
}


# Pre-fetch all data needed for display (policies + build jobs) and normalize
function global:get-policy-display-data
{
    param(
        [int] $pr_id,
        [string] $org,
        [switch] $ShowBuildDetails
    )
    $result = $null

    # Fetch policies
    $policies = get-azure-pr-policies -pr_id $pr_id -org $org
    if(-not $policies)
    {
        # no policies
    }
    else
    {
        # Pre-fetch build job details for all builds (running, queued, or completed)
        $build_jobs = @{}
        $build_access_denied = @{}
        if($ShowBuildDetails)
        {
            foreach($policy in $policies)
            {
                if($policy.BuildId -and $policy.ProjectId)
                {
                    $jobs = get-build-job-details -build_id $policy.BuildId -project_id $policy.ProjectId -org $org
                    if($jobs)
                    {
                        $build_jobs[$policy.BuildId] = $jobs
                    }
                    elseif($policy.BuildId)
                    {
                        $build_access_denied[$policy.BuildId] = $true
                    }
                    else
                    {
                        # no build id
                    }
                }
                else
                {
                    # no build or project id
                }
            }
        }
        else
        {
            # not showing build details
        }

        # Get PR URL from first policy (all have the same PR URL)
        $pr_url = $null
        if($policies -and $policies.Count -gt 0 -and $policies[0].PrUrl)
        {
            $pr_url = $policies[0].PrUrl
        }
        else
        {
            # no PR URL available
        }

        # Build normalized check items
        $normalized_checks = @()
        foreach($policy in $policies)
        {
            $policy_name = $policy.Policy
            $policy_status = $policy.Status
            $build_id = $policy.BuildId

            # Check if we have job details for this build
            $has_jobs = $ShowBuildDetails -and $build_id -and $build_jobs.ContainsKey($build_id)
            $access_denied = $ShowBuildDetails -and $build_id -and $build_access_denied -and $build_access_denied.ContainsKey($build_id)

            # Build URL for the check
            $check_url = ""
            if($build_id -and $policy.ProjectName)
            {
                $check_url = "$($policy.BaseUrl)/$($policy.ProjectName)/_build/results?buildId=$build_id"
            }
            else
            {
                # no build id or project info
            }

            if($has_jobs)
            {
                foreach($job in $build_jobs[$build_id])
                {
                    if($job.Result)
                    {
                        $job_status = $job.Result
                    }
                    else
                    {
                        $job_status = $job.State
                    }
                    $normalized_checks += [PSCustomObject]@{
                        Name = "$policy_name ($($job.Name))"
                        Status = (convert-azure-status-to-normalized -azure_status $job_status)
                        StartTime = $job.StartTime
                        FinishTime = $job.FinishTime
                        Url = $check_url
                        IsBlocking = $policy.IsBlocking
                    }
                }
            }
            elseif($access_denied)
            {
                $normalized_checks += [PSCustomObject]@{
                    Name = "$policy_name (job details require pipeline read permission)"
                    Status = (convert-azure-status-to-normalized -azure_status $policy_status)
                    StartTime = $null
                    FinishTime = $null
                    Url = $check_url
                    IsBlocking = $policy.IsBlocking
                }
            }
            else
            {
                $normalized_checks += [PSCustomObject]@{
                    Name = $policy_name
                    Status = (convert-azure-status-to-normalized -azure_status $policy_status)
                    StartTime = $null
                    FinishTime = $null
                    Url = $check_url
                    IsBlocking = $policy.IsBlocking
                }
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

    return $result
}


# Display policy status with colors and symbols (uses pre-fetched data)
function show-policy-status
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
        Write-Host "No policies found" -ForegroundColor Gray
    }
    else
    {
        show-status-summary -counts $counts -pr_url $displayData.PrUrl -poll_interval $poll_interval
        show-pr-check-table -checks $checks
    }
}


# Watch PR policies until complete or timeout
function watch-azure-pr-policies
{
    param(
        [int] $pr_id,
        [string] $org,
        [int] $poll_interval = 30,
        [int] $timeout = 120,
        [switch] $ShowBuildDetails,
        [scriptblock] $OnIteration = $null  # Optional callback to run each iteration
    )
    $fn_result = $null

    # Define the fetch data callback - inline the data fetching logic
    $fetch_data = {
        get-policy-display-data -pr_id $pr_id -org $org -ShowBuildDetails:$ShowBuildDetails
    }.GetNewClosure()

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
            Write-Host "No policies found" -ForegroundColor Gray
        }
        else
        {
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
    $watch_result = watch-pr-status `
        -FetchData $fetch_data `
        -ShowStatus $show_status `
        -TestComplete $test_complete `
        -poll_interval $poll_interval `
        -timeout $timeout `
        -OnIteration $OnIteration

    if($watch_result.Success)
    {
        $fn_result = $true
    }
    else
    {
        $fn_result = $false
    }

    return $fn_result
}


# Simple one-time display of policy status (for use by other scripts)
function show-azure-pr-policy-status
{
    param(
        [int] $pr_id,
        [string] $org,
        [switch] $ShowBuildDetails
    )

    $displayData = get-policy-display-data -pr_id $pr_id -org $org -ShowBuildDetails:$ShowBuildDetails
    if($displayData)
    {
        show-policy-status -displayData $displayData -poll_interval 30
    }
    else
    {
        # no display data
    }
}


# If running directly (not dot-sourced), watch the PR
if($MyInvocation.InvocationName -ne '.')
{
    $success = watch-azure-pr-policies -pr_id $pr_id -org $org -poll_interval $poll_interval -timeout $timeout -ShowBuildDetails
    if($success)
    {
        exit 0
    }
    else
    {
        exit 1
    }
}
