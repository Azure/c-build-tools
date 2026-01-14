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


# Get policy status for Azure PR
function get-azure-pr-policies {
    param(
        [int] $pr_id,
        [string] $org
    )

    $policy_output = az repos pr policy list `
        --id $pr_id `
        --organization $org `
        --query "[].{Policy:configuration.type.displayName, Status:status, BuildId:context.buildId, ProjectId:configuration.settings.scope[0].repositoryId, IsBlocking:configuration.isBlocking}" `
        --output json 2>$null

    if($LASTEXITCODE -ne 0 -or !$policy_output) {
        return $null
    }

    # Get the project info from the PR for build timeline lookups and URLs
    $pr_info = az repos pr show --id $pr_id --org $org --query "{ProjectId:repository.project.id, ProjectName:repository.project.name, OrgUrl:repository.project.url, RepoName:repository.name}" -o json 2>$null
    $project_id = $null
    $project_name = $null
    $base_url = $null
    $repo_name = $null
    if($pr_info) {
        $pr_data = $pr_info | ConvertFrom-Json
        $project_id = $pr_data.ProjectId
        $project_name = $pr_data.ProjectName
        $repo_name = $pr_data.RepoName
        # Extract base URL from project URL (e.g., https://msazure.visualstudio.com/_apis/projects/... -> https://msazure.visualstudio.com)
        if($pr_data.OrgUrl -match '^(https://[^/]+)') {
            $base_url = $matches[1]
        }
    }

    $policies = $policy_output | ConvertFrom-Json

    # Build PR URL
    $pr_url = $null
    if($base_url -and $project_name -and $repo_name) {
        $pr_url = "$base_url/$project_name/_git/$repo_name/pullrequest/$pr_id"
    }

    # Attach project info to policies with builds
    foreach($policy in $policies) {
        # Always attach PR URL for reference
        $policy | Add-Member -NotePropertyName "PrUrl" -NotePropertyValue $pr_url -Force
        if($policy.BuildId -and $project_id) {
            $policy | Add-Member -NotePropertyName "ProjectId" -NotePropertyValue $project_id -Force
            $policy | Add-Member -NotePropertyName "ProjectName" -NotePropertyValue $project_name -Force
            $policy | Add-Member -NotePropertyName "BaseUrl" -NotePropertyValue $base_url -Force
        }
    }

    return $policies
}


# Get build job details from timeline
function get-build-job-details {
    param(
        [int] $build_id,
        [string] $project_id,
        [string] $org
    )

    $timeline = az devops invoke `
        --area build `
        --resource timeline `
        --route-parameters project=$project_id buildId=$build_id `
        --org $org `
        --api-version 7.1 `
        -o json 2>$null

    if($LASTEXITCODE -ne 0 -or !$timeline) {
        return $null
    }

    $records = ($timeline | ConvertFrom-Json).records
    $jobs = $records | Where-Object { $_.type -eq "Job" }

    return $jobs | ForEach-Object {
        [PSCustomObject]@{
            Name = $_.name
            State = $_.state
            Result = $_.result
            StartTime = $_.startTime
            FinishTime = $_.finishTime
        }
    }
}


# Pre-fetch all data needed for display (policies + build jobs)
function get-policy-display-data {
    param(
        [int] $pr_id,
        [string] $org,
        [switch] $ShowBuildDetails
    )

    # Fetch policies
    $policies = get-azure-pr-policies -pr_id $pr_id -org $org
    if(!$policies) {
        return $null
    }

    # Pre-fetch build job details for all builds (running, queued, or completed)
    $build_jobs = @{}
    $build_access_denied = @{}
    if($ShowBuildDetails) {
        foreach($policy in $policies) {
            if($policy.BuildId -and $policy.ProjectId) {
                $jobs = get-build-job-details -build_id $policy.BuildId -project_id $policy.ProjectId -org $org
                if($jobs) {
                    $build_jobs[$policy.BuildId] = $jobs
                } elseif($policy.BuildId) {
                    # Mark that we couldn't access this build's details
                    $build_access_denied[$policy.BuildId] = $true
                }
            }
        }
    }

    # Get PR URL from first policy (all have the same PR URL)
    $pr_url = $null
    if($policies -and $policies.Count -gt 0 -and $policies[0].PrUrl) {
        $pr_url = $policies[0].PrUrl
    }

    return @{
        Policies = $policies
        BuildJobs = $build_jobs
        BuildAccessDenied = $build_access_denied
        Timestamp = Get-Date -Format 'HH:mm:ss'
        PrUrl = $pr_url
    }
}


# Display policy status with colors and symbols (uses pre-fetched data)
function show-policy-status {
    param(
        [hashtable] $displayData,
        [switch] $ClearScreen,
        [int] $pr_id,
        [int] $poll_interval,
        [switch] $ShowBuildDetails
    )

    $policies = $displayData.Policies
    $build_jobs = $displayData.BuildJobs
    $build_access_denied = $displayData.BuildAccessDenied
    $timestamp = $displayData.Timestamp
    $pr_url = $displayData.PrUrl

    if($ClearScreen -and $Host.UI.RawUI.WindowSize) {
        Clear-Host
    }

    # Header like gh pr checks --watch
    Write-Host "Refreshing checks status every $poll_interval seconds. Press Ctrl+C to quit." -ForegroundColor Gray
    if($pr_url) {
        Write-Host "PR: $pr_url" -ForegroundColor Cyan
    }
    Write-Host ""

    if(!$policies -or $policies.Count -eq 0) {
        Write-Host "No policies found" -ForegroundColor Gray
        return
    }

    # Build flat list of all checks (policies + jobs)
    $all_checks = @()

    foreach($policy in $policies) {
        $policy_name = $policy.Policy
        $policy_status = $policy.Status
        $build_id = $policy.BuildId

        # Check if we have job details for this build
        $has_jobs = $ShowBuildDetails -and $build_id -and $build_jobs.ContainsKey($build_id)
        $access_denied = $ShowBuildDetails -and $build_id -and $build_access_denied -and $build_access_denied.ContainsKey($build_id)

        if($has_jobs) {
            # Add job details instead of the policy
            foreach($job in $build_jobs[$build_id]) {
                $job_status = if($job.Result) { $job.Result } else { $job.State }
                # Normalize status names
                $normalized_status = switch($job_status) {
                    "succeeded" { "approved" }
                    "failed" { "rejected" }
                    "inProgress" { "running" }
                    "pending" { "queued" }
                    "canceled" { "cancelled" }
                    default { $job_status }
                }
                $all_checks += [PSCustomObject]@{
                    Name = "$policy_name ($($job.Name))"
                    Status = $normalized_status
                    StartTime = $job.StartTime
                    FinishTime = $job.FinishTime
                    IsJob = $true
                    BuildId = $build_id
                }
            }
        } elseif($access_denied) {
            # Show policy with indication that we couldn't get job details
            $all_checks += [PSCustomObject]@{
                Name = "$policy_name (job details require pipeline read permission)"
                Status = $policy_status
                StartTime = $null
                FinishTime = $null
                IsJob = $false
                BuildId = $build_id
            }
        } else {
            # Just show the policy itself
            $all_checks += [PSCustomObject]@{
                Name = $policy_name
                Status = $policy_status
                StartTime = $null
                FinishTime = $null
                IsJob = $false
                BuildId = $build_id
            }
        }
    }

    # Count statuses
    $approved_count = ($all_checks | Where-Object { $_.Status -eq "approved" }).Count
    $rejected_count = ($all_checks | Where-Object { $_.Status -eq "rejected" }).Count
    $running_count = ($all_checks | Where-Object { $_.Status -eq "running" }).Count
    $queued_count = ($all_checks | Where-Object { $_.Status -eq "queued" }).Count
    $cancelled_count = ($all_checks | Where-Object { $_.Status -eq "cancelled" }).Count
    $pending_count = $running_count + $queued_count

    # Summary status
    if($rejected_count -gt 0) {
        Write-Host "Some checks were not successful" -ForegroundColor Red
    } elseif($pending_count -gt 0) {
        Write-Host "Some checks are still pending" -ForegroundColor Yellow
    } else {
        Write-Host "All checks were successful" -ForegroundColor Green
    }

    # Stats line
    Write-Host "$cancelled_count cancelled, $rejected_count failing, $approved_count successful, 0 skipped, and $pending_count pending checks`n" -ForegroundColor Gray

    # Column widths (matching gh pr checks output)
    $name_width = 70
    $elapsed_width = 10
    $url_width = 80

    # Table header (like gh)
    $header = "   {0,-$name_width} {1,-$elapsed_width} {2}" -f "NAME", "ELAPSED", "URL"
    Write-Host $header -ForegroundColor White

    # Display each check
    foreach($check in $all_checks) {
        $check_name = $check.Name
        $check_status = $check.Status

        # Truncate long names
        if($check_name.Length -gt $name_width) {
            $check_name = $check_name.Substring(0, $name_width - 3) + "..."
        }

        # Calculate elapsed/duration time
        $elapsed = ""
        if($check.StartTime) {
            try {
                # Azure CLI outputs times that are actually UTC but without timezone indicator
                # Parse as local then treat as UTC by using SpecifyKind
                $startParsed = [DateTime]::Parse($check.StartTime)
                $start = [DateTime]::SpecifyKind($startParsed, [DateTimeKind]::Utc)
                # For completed jobs, show duration (finish - start)
                # For running jobs, show elapsed (now - start)
                if($check.FinishTime) {
                    $finishParsed = [DateTime]::Parse($check.FinishTime)
                    $finish = [DateTime]::SpecifyKind($finishParsed, [DateTimeKind]::Utc)
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

        # Build URL for the check
        $url = ""
        if($check.BuildId) {
            # Find the policy that has this BuildId to get its project info
            $policy_with_project = $policies | Where-Object { $_.BuildId -eq $check.BuildId -and $_.ProjectName } | Select-Object -First 1
            if($policy_with_project) {
                $base_url = $policy_with_project.BaseUrl
                $project_name = $policy_with_project.ProjectName
                $url = "$base_url/$project_name/_build/results?buildId=$($check.BuildId)"
                # Truncate URL if too long
                if($url.Length -gt $url_width) {
                    $url = $url.Substring(0, $url_width - 3) + "..."
                }
            }
        }

        # Choose symbol and color based on status
        switch($check_status) {
            "approved" {
                $symbol = [char]0x2713  # checkmark
                $color = "Green"
            }
            "rejected" {
                $symbol = [char]0x2717  # X mark
                $color = "Red"
            }
            "running" {
                $symbol = "*"
                $color = "Yellow"
            }
            "queued" {
                $symbol = "-"
                $color = "Gray"
            }
            "cancelled" {
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


# Check if all blocking policies are complete (approved or rejected)
function Test-PoliciesComplete {
    param(
        [array] $policies
    )

    if(!$policies -or $policies.Count -eq 0) {
        return @{ Complete = $false; Success = $false; Message = "No policies found" }
    }

    $blocking_policies = $policies | Where-Object { $_.IsBlocking -eq $true }

    # Check if any blocking policy is still running or queued
    $in_progress = $blocking_policies | Where-Object { $_.Status -eq "running" -or $_.Status -eq "queued" }

    if($in_progress.Count -gt 0) {
        # Still waiting for some policies to complete
        $in_progress_names = ($in_progress | ForEach-Object { "$($_.Policy) ($($_.Status))" }) -join ", "
        return @{ Complete = $false; Success = $false; Message = "Waiting for: $in_progress_names" }
    }

    # All policies have reached terminal state - check if any are rejected
    $rejected = $blocking_policies | Where-Object { $_.Status -eq "rejected" }
    if($rejected) {
        $rejected_names = ($rejected | ForEach-Object { $_.Policy }) -join ", "
        return @{ Complete = $true; Success = $false; Message = "Rejected policies: $rejected_names" }
    }

    # All blocking policies are approved
    return @{ Complete = $true; Success = $true; Message = "All blocking policies approved" }
}


# Watch PR policies until complete or timeout
function watch-azure-pr-policies {
    param(
        [int] $pr_id,
        [string] $org,
        [int] $poll_interval = 30,
        [int] $timeout = 120,
        [switch] $ShowBuildDetails,
        [scriptblock] $OnIteration = $null  # Optional callback to run each iteration
    )

    $start_time = Get-Date
    $timeout_time = $start_time.AddMinutes($timeout)
    $iteration = 0

    Write-Host "Watching PR $pr_id policies..." -ForegroundColor Cyan
    Write-Host "Poll interval: ${poll_interval}s, Timeout: ${timeout}m`n"

    while($true) {
        $iteration++

        # Check timeout
        if((Get-Date) -gt $timeout_time) {
            Write-Host "`nTimeout reached after $timeout minutes" -ForegroundColor Red
            return $false
        }

        # Pre-fetch all data before clearing screen (avoids blank screen during API calls)
        $displayData = get-policy-display-data -pr_id $pr_id -org $org -ShowBuildDetails:$ShowBuildDetails

        if(!$displayData) {
            Write-Host "Failed to get policy status, retrying..." -ForegroundColor Yellow
            Start-Sleep -Seconds $poll_interval
            continue
        }

        # Display status (clear screen and immediately show pre-fetched data)
        show-policy-status -displayData $displayData -ClearScreen -pr_id $pr_id -poll_interval $poll_interval -ShowBuildDetails:$ShowBuildDetails

        # Run callback if provided (e.g., show propagation status)
        if($OnIteration) {
            & $OnIteration
        }

        # Check if complete
        $result = Test-PoliciesComplete -policies $displayData.Policies

        Write-Host ""
        if($result.Complete) {
            if($result.Success) {
                return $true
            } else {
                return $false
            }
        }

        # Wait before next poll
        Start-Sleep -Seconds $poll_interval
    }
}


# Simple one-time display of policy status (for use by other scripts)
function show-azure-pr-policy-status {
    param(
        [int] $pr_id,
        [string] $org,
        [switch] $ShowBuildDetails
    )

    $displayData = get-policy-display-data -pr_id $pr_id -org $org -ShowBuildDetails:$ShowBuildDetails
    if($displayData) {
        show-policy-status -displayData $displayData -pr_id $pr_id -poll_interval 30 -ShowBuildDetails:$ShowBuildDetails
    }
}


# If running directly (not dot-sourced), watch the PR
if($MyInvocation.InvocationName -ne '.') {
    $success = watch-azure-pr-policies -pr_id $pr_id -org $org -poll_interval $poll_interval -timeout $timeout -ShowBuildDetails
    if($success) {
        exit 0
    } else {
        exit 1
    }
}
