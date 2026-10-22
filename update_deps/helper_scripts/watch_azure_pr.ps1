# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS

Watch Azure DevOps PR policy status until all policies pass or one fails.

.DESCRIPTION

Similar to 'gh pr checks --watch', this polls the policy status of an Azure DevOps PR (through the
REST helpers in azure_repo_ops.ps1) and displays updates in real-time until all blocking policies
are approved or one is rejected. Loaded by load_helpers.ps1; uses the common watch loop in
pr_watch_utils.ps1.

.EXAMPLE

PS> watch-azure-pr-policies -pr_id 14336583 -org "https://dev.azure.com/msazure" -ShowBuildDetails
#>


# Get policy status for Azure PR
function global:get-azure-pr-policies
{
    param(
        [int] $pr_id,
        [string] $org
    )
    $result = $null

    try
    {
        $pr = get-ado-pull-request -org_url $org -pr_id $pr_id
        $evaluations = @(get-azure-pr-policy-evaluations -org $org -pr $pr)
    }
    catch
    {
        $evaluations = @()
    }

    if ($evaluations.Count -eq 0)
    {
        # error or no policies
    }
    else
    {
        $project_id = $pr.repository.project.id
        $project_name = $pr.repository.project.name
        $pr_url = "$org/$project_name/_git/$($pr.repository.name)/pullrequest/$pr_id"

        $result = @(foreach ($evaluation in $evaluations)
        {
            $build_id = $evaluation.context.buildId
            [PSCustomObject]@{
                Policy = $evaluation.configuration.type.displayName
                Status = $evaluation.status
                BuildId = $build_id
                IsBlocking = $evaluation.configuration.isBlocking
                PrUrl = $pr_url
                ProjectId = if ($build_id) { $project_id } else { $null }
                ProjectName = $project_name
                BaseUrl = $org
            }
        })
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

    try
    {
        $timeline = get-ado-build-timeline -org $org -project $project_id -build_id $build_id
    }
    catch
    {
        # no access to the build (e.g. missing pipeline read permission)
        $timeline = $null
    }

    if (-not $timeline)
    {
        # error or no output
    }
    else
    {
        $jobs = $timeline.records | Where-Object { $_.type -eq "Job" }

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
    $policies = @(get-azure-pr-policies -pr_id $pr_id -org $org)
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

    $fetch_data = {
        get-policy-display-data -pr_id $pr_id -org $org -ShowBuildDetails:$ShowBuildDetails
    }.GetNewClosure()

    $show_status = {
        param($displayData)
        show-pr-watch-status -displayData $displayData -poll_interval $poll_interval -empty_message "No policies found"
    }.GetNewClosure()

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
