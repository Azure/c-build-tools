# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Azure DevOps repository operations for propagate_updates.ps1
# Uses global: $azure_work_item

# Source dependencies
. "$PSScriptRoot\status_tracking.ps1"
. "$PSScriptRoot\watch_azure_pr.ps1"

# get Azure DevOps organization and project from git remote URL
function get-azure-org-project
{
    param(
        [string] $repo_name
    )
    $result = $null

    Push-Location $repo_name
    $repo_url = git config --get remote.origin.url
    Pop-Location

    # Parse URL like https://msazure@dev.azure.com/msazure/One/_git/repo-name
    # or https://dev.azure.com/msazure/One/_git/repo-name
    if($repo_url -match "dev\.azure\.com/([^/]+)/([^/]+)/_git")
    {
        $org = $matches[1]
        $project = $matches[2]
        $result = @{
            Organization = "https://dev.azure.com/$org"
            Project = $project
        }
    }
    # Parse URL like https://msazure.visualstudio.com/DefaultCollection/One/_git/repo-name
    # or https://msazure.visualstudio.com/One/_git/repo-name
    elseif($repo_url -match "([^/]+)\.visualstudio\.com/(?:DefaultCollection/)?([^/]+)/_git")
    {
        $org = $matches[1]
        $project = $matches[2]
        $result = @{
            Organization = "https://dev.azure.com/$org"
            Project = $project
        }
    }
    else
    {
        fail-with-status "Failed to parse Azure DevOps organization and project from remote URL: $repo_url"
    }

    return $result
}


# Find an active Azure PR for a given branch. Returns the PR URL or $null.
function find-active-azure-pr
{
    param(
        [string] $repo_name,
        [string] $branch_name
    )
    $result = $null

    $azure_info = get-azure-org-project $repo_name
    $org = $azure_info.Organization
    $project = $azure_info.Project
    $pr_list_output = az repos pr list `
        --repository $repo_name `
        --source-branch $branch_name `
        --target-branch master `
        --status active `
        --organization $org `
        --project $project `
        --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and $pr_list_output)
    {
        $prs = @($pr_list_output | ConvertFrom-Json)
        if ($prs.Count -gt 0)
        {
            $pr_id = $prs[0].pullRequestId
            # az repos pr list doesn't populate repository.webUrl,
            # so construct the URL from org/project/repo
            $result = "$org/$project/_git/$repo_name/pullrequest/$pr_id"
        }
        else
        {
            # no active PRs for this branch
        }
    }
    else
    {
        # couldn't query PRs
    }

    return $result
}


# Get the status of an Azure PR. Returns "completed", "abandoned", or "active".
function get-azure-pr-status
{
    param(
        [string] $pr_url,
        [string] $repo_name
    )
    $result = "active"

    if ($pr_url -match "/pullrequest/(\d+)")
    {
        $pr_id = [int]$matches[1]
        $azure_info = get-azure-org-project $repo_name
        $pr_check = az repos pr show --id $pr_id --organization $azure_info.Organization --output json 2>&1
        if ($LASTEXITCODE -eq 0)
        {
            $pr_info = $pr_check | ConvertFrom-Json
            $result = $pr_info.status
        }
        else
        {
            # couldn't check PR status, assume active
        }
    }
    else
    {
        # couldn't parse PR ID from URL
    }

    return $result
}


# Monitor an existing Azure PR until completion.
function monitor-azure-pr
{
    param(
        [string] $pr_url,
        [string] $repo_name
    )

    if ($pr_url -match "/pullrequest/(\d+)")
    {
        $pr_id = [int]$matches[1]
        $azure_info = get-azure-org-project $repo_name
        wait-until-complete-azure $pr_id $azure_info.Organization $repo_name
    }
    else
    {
        fail-with-status "Could not parse PR ID from URL: $pr_url"
    }
}


# Close/abandon an Azure PR, checking status first.
function close-pr-azure
{
    param(
        [string] $pr_url,
        [string] $repo_name
    )

    $status = get-azure-pr-status -pr_url $pr_url -repo_name $repo_name
    if ($status -eq "completed")
    {
        Write-Host "Azure PR is already completed (merged), skipping abandon" -ForegroundColor Green
    }
    elseif ($status -eq "abandoned")
    {
        Write-Host "Azure PR is already abandoned, skipping" -ForegroundColor Gray
    }
    else
    {
        Write-Host "Abandoning Azure PR: $pr_url" -ForegroundColor Yellow
        if ($pr_url -match "/pullrequest/(\d+)")
        {
            $pr_id = $matches[1]
            $azure_info = get-azure-org-project $repo_name
            az repos pr update --id $pr_id --status abandoned --organization $azure_info.Organization --output json | Out-Null
            if ($LASTEXITCODE -eq 0)
            {
                Write-Host "Azure PR abandoned successfully" -ForegroundColor Green
            }
            else
            {
                Write-Host "Warning: Failed to abandon Azure PR ID: $pr_id" -ForegroundColor Yellow
            }
        }
        else
        {
            Write-Host "Warning: Could not parse PR ID from URL: $pr_url" -ForegroundColor Yellow
        }
    }
}


# create PR to update dependencies for Azure repo using Azure CLI
function create-pr-azure
{
    param(
        [string] $repo_name,
        [string] $new_branch_name,
        [hashtable] $description
    )
    $result = $null

    Write-Host "`nCreating PR"

    $azure_info = get-azure-org-project $repo_name
    $org = $azure_info.Organization
    $project = $azure_info.Project

    $pr_title = "[autogenerated] update dependencies"
    $pr_body = "Propagating dependency updates"
    if ($description)
    {
        $pr_title = $description.PrTitle
        $pr_body = $description.PrBody
    }
    else
    {
        # no description, use defaults
    }

    # Truncate body to avoid Windows command line length limits (~8000 chars)
    $max_body_len = 4000
    if ($pr_body.Length -gt $max_body_len)
    {
        $pr_body = $pr_body.Substring(0, $max_body_len) + "`n`n... (truncated)"
    }
    else
    {
        # body fits within limits
    }

    $pr_output = az repos pr create `
        --repository $repo_name `
        --source-branch $new_branch_name `
        --target-branch master `
        --title $pr_title `
        --description $pr_body `
        --organization $org `
        --project $project `
        --output json

    if($LASTEXITCODE -ne 0)
    {
        # Existing PRs are already detected by update-repo before reaching here.
        # If creation still fails, it's an unexpected error — fail immediately.
        fail-with-status "Failed to create PR for repo $repo_name"
    }
    else
    {
        Write-Host "PR created successfully" -ForegroundColor Green
        $result = $pr_output | ConvertFrom-Json
    }

    return $result
}


# link work item to PR for Azure repo using Azure CLI
function link-work-item-to-pr-azure
{
    param(
        [int] $pr_id,
        [string] $org,
        [string] $project
    )

    Write-Host "Linking work item to PR (PR ID: $pr_id)"

    if(!$azure_work_item)
    {
        fail-with-status "Updating Azure repos requires providing a work item id. Provide work item id as: -azure_work_item [id]"
    }
    else
    {
        $output = az repos pr work-item add `
            --id $pr_id `
            --work-items $azure_work_item `
            --organization $org `
            --output json

        if($LASTEXITCODE -ne 0)
        {
            fail-with-status "Failed to link work item to PR. Work item: $azure_work_item, PR ID: $pr_id"
        }
        else
        {
            Write-Host "Work item linked successfully" -ForegroundColor Green
        }
    }
}


# approve PR for Azure repo using Azure CLI
function approve-pr-azure
{
    param(
        [int] $pr_id,
        [string] $org
    )

    Write-Host "Approving PR"

    $output = az repos pr set-vote `
        --id $pr_id `
        --vote approve `
        --organization $org `
        --output json

    if($LASTEXITCODE -ne 0)
    {
        fail-with-status "Failed to approve PR ID: $pr_id"
    }
    else
    {
        Write-Host "PR approved successfully" -ForegroundColor Green
    }
}


# set PR for Azure repo to merge automatically once build completes using Azure CLI
function set-autocomplete-azure
{
    param(
        [int] $pr_id,
        [string] $org
    )

    Write-Host "Enabling PR to autocomplete"

    $output = az repos pr update `
        --id $pr_id `
        --auto-complete true `
        --squash true `
        --delete-source-branch true `
        --organization $org `
        --output json

    if($LASTEXITCODE -ne 0)
    {
        fail-with-status "Failed to set autocomplete for PR ID: $pr_id"
    }
    else
    {
        Write-Host "Autocomplete enabled successfully" -ForegroundColor Green
    }
}


# Fetch PR status with retries to handle transient API failures
function get-pr-status-with-retry
{
    param(
        [int] $pr_id,
        [string] $org,
        [int] $max_retries = 3,
        [int] $retry_delay = 5
    )
    $result = $null

    for ($attempt = 1; $attempt -le $max_retries; $attempt++)
    {
        $pr_output = az repos pr show --id $pr_id --organization $org --output json 2>$null
        if ($LASTEXITCODE -eq 0 -and $pr_output)
        {
            $result = $pr_output | ConvertFrom-Json
            break
        }
        else
        {
            if ($attempt -lt $max_retries)
            {
                Write-Host "  Retrying PR status check ($attempt/$max_retries)..." -ForegroundColor Yellow
                Start-Sleep -Seconds $retry_delay
            }
            else
            {
                # all retries exhausted
            }
        }
    }

    return $result
}

# wait until build completes for Azure repo using Azure CLI
function wait-until-complete-azure
{
    param(
        [int] $pr_id,
        [string] $org,
        [string] $repo_name
    )
    $done = $false

    Write-Host "Waiting for build to complete"
    Write-Host "`nWatching PR policies..."
    $success = watch-azure-pr-policies -pr_id $pr_id -org $org -poll_interval $global:poll_interval -timeout 120 -ShowBuildDetails -OnIteration { [void](show-propagation-status) }

    if(!$success)
    {
        # Policy watch reported failure — but this could be a non-blocking/optional
        # policy. Autocomplete will still merge the PR if all required policies pass.
        # Wait for autocomplete before giving up.
        $pr_info = get-pr-status-with-retry -pr_id $pr_id -org $org
        if($pr_info -and $pr_info.status -eq "completed")
        {
            Write-Host "PR completed successfully" -ForegroundColor Green
            $done = $true
        }
        else
        {
            Write-Host "Waiting for PR to auto-complete despite policy status..." -ForegroundColor Yellow
            $max_wait = 120
            $waited = 0
            while($waited -lt $max_wait -and !$done)
            {
                $cancelled = wait-or-cancel -seconds 5
                if ($cancelled) { $global:propagation_cancelled = $true; break }
                $waited += 5
                $pr_check = get-pr-status-with-retry -pr_id $pr_id -org $org -max_retries 1
                if($pr_check -and $pr_check.status -eq "completed")
                {
                    Write-Host "PR completed successfully" -ForegroundColor Green
                    $done = $true
                }
                else
                {
                    # keep waiting
                }
            }
        }
        if(!$done -and -not $global:propagation_cancelled)
        {
            fail-with-status "PR $pr_id failed to complete. Check policy status above."
        }
        else
        {
            # already done or cancelled
        }
    }
    else
    {
        # Verify PR is completed
        $pr_info = get-pr-status-with-retry -pr_id $pr_id -org $org
        if(-not $pr_info)
        {
            fail-with-status "Failed to get PR status for ID: $pr_id after retries"
        }
        else
        {
            if($pr_info.status -ne "completed")
            {
                # PR policies passed but PR not yet merged - wait a bit for autocomplete
                Write-Host "Waiting for PR to auto-complete..."
                $max_wait = 60
                $waited = 0
                while($waited -lt $max_wait -and !$done)
                {
                    $cancelled = wait-or-cancel -seconds 2
                    if ($cancelled) { $global:propagation_cancelled = $true; break }
                    $waited += 2
                    $pr_check = get-pr-status-with-retry -pr_id $pr_id -org $org -max_retries 1
                    if($pr_check -and $pr_check.status -eq "completed")
                    {
                        Write-Host "PR completed successfully" -ForegroundColor Green
                        $done = $true
                    }
                    else
                    {
                        # keep waiting
                    }
                }
                if(!$done)
                {
                    Write-Host "Warning: PR policies passed but PR status is: $($pr_info.status)" -ForegroundColor Yellow
                }
                else
                {
                    # already logged success
                }
            }
            else
            {
                Write-Host "PR completed successfully" -ForegroundColor Green
            }
        }
    }
}


# update dependencies for Azure repo using Azure CLI
# Returns the PR URL for status tracking
function update-repo-azure
{
    param(
        [string] $repo_name,
        [string] $new_branch_name,
        [hashtable] $description
    )
    $result = $null

    $azure_info = get-azure-org-project $repo_name
    $org = $azure_info.Organization
    $project = $azure_info.Project

    $pr_info = create-pr-azure $repo_name $new_branch_name $description
    $pr_id = $pr_info.pullRequestId

    # Build PR URL from the response
    if($pr_info.repository -and $pr_info.repository.webUrl)
    {
        $result = "$($pr_info.repository.webUrl)/pullrequest/$pr_id"
    }
    else
    {
        # fallback - no URL available
    }

    # Update status with PR URL immediately so it shows even if later steps fail
    set-repo-status -repo_name $repo_name -status $script:STATUS_IN_PROGRESS -pr_url $result

    # Show Windows notification with PR link
    if ($result)
    {
        show-pr-notification -repo_name $repo_name -pr_url $result
    }
    else
    {
        # no PR URL to notify about
    }

    link-work-item-to-pr-azure $pr_id $org $project

    approve-pr-azure $pr_id $org

    set-autocomplete-azure $pr_id $org

    wait-until-complete-azure $pr_id $org $repo_name

    return $result
}
