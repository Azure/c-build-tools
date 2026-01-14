# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS

Propagates dependency updates for git repositories.

.DESCRIPTION

Given a root repo, this script builds the dependency graph and propagates updates from the
lowest level up to the root repo by making PRs to each repo in bottom-up level-order.

Authentication for Azure DevOps uses WAM (Web Account Manager) by default on Windows, which
provides SSO using your Windows login. If WAM is not available or fails, you can provide a
PAT token as a fallback. GitHub authentication is handled via 'gh auth login'.

.PARAMETER root_list

Comma-separated list of URLs of the repositories up to which updates must be propagated.

.PARAMETER azure_work_item

Work item id that is linked to PRs made to Azure repos.

.PARAMETER azure_token

(Optional) Personal Access Token for Azure DevOps authentication. If not provided, WAM
authentication will be used. PAT must have Code (Read & Write) and Work Items (Read) permissions.

.INPUTS

ignore.json: list of repositories that must be ignored for updates.
order.json: reads order in which repositories must be updated from order.json

.OUTPUTS

None.

.EXAMPLE

PS> .\propagate_updates.ps1 -azure_work_item 12345 -root_list root1, root2, ...

.EXAMPLE

PS> .\propagate_updates.ps1 -azure_token <your-pat-token> -azure_work_item 12345 -root_list root1, root2, ...

.EXAMPLE

PS> .\propagate_updates.ps1 -azure_work_item 12345 -useCachedRepoOrder -root_list root1, root2, ...
# Uses cached repo order if root_list matches the cached root_list
#>


param(
    [Parameter(Mandatory=$false)][string]$azure_token, # Personal Access Token for Azure DevOps (optional, WAM used if not provided)
    [Parameter(Mandatory=$true)][Int32]$azure_work_item, # Work item id to link to Azure PRs
    [switch]$useCachedRepoOrder, # use cached repo order if root_list matches
    [Parameter(Mandatory=$true)][string[]]$root_list # comma-separated list of URLs for repositories upto which updates must be propagated
)


# Source helper scripts
. "$PSScriptRoot\install_az_cli.ps1"
. "$PSScriptRoot\install_gh_cli.ps1"
. "$PSScriptRoot\repo_order_cache.ps1"
. "$PSScriptRoot\watch_azure_pr.ps1" -pr_id 0 -org "dummy" 2>$null
. "$PSScriptRoot\watch_github_pr.ps1" 2>$null


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
function Initialize-RepoStatus {
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
function Set-RepoStatus {
    param(
        [string] $repo_name,
        [string] $status,
        [string] $message = ""
    )
    if($global:repo_status.ContainsKey($repo_name)) {
        $global:repo_status[$repo_name].Status = $status
        $global:repo_status[$repo_name].Message = $message
    }
}

# Fail with status - marks current repo as failed, shows final status, and exits
function Fail-WithStatus {
    param(
        [string] $message
    )
    if($global:current_repo -and $global:repo_status.ContainsKey($global:current_repo)) {
        Set-RepoStatus -repo_name $global:current_repo -status $script:STATUS_FAILED -message $message
    }
    Show-PropagationStatus -Final
    Write-Error $message
    exit -1
}

# Display propagation status
function Show-PropagationStatus {
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
    }

    Write-Host ""
}

# create a global variable $ignore_pattern
# $ignore pattern is used in the shell command for 'git submodule foreach' to ignore repos
function create-ignore-pattern {
    $path_to_ignores = $PSScriptRoot + "\ignores.json"
    # get list of repos to ignore from ignores.json
    $repos_to_ignore = (Get-Content -Path $path_to_ignores) | ConvertFrom-Json
    $ignore_list = New-Object -TypeName "System.Collections.ArrayList"
    # prepend "deps/" to the name of each repo
    foreach($repo_to_ignore in $repos_to_ignore) {
        [void]$ignore_list.Add("deps/"+$repo_to_ignore)
    }
    # join repo names to get pattern of the form "deps/{repo1}|deps/repo{2}|..."
    $global:ignore_pattern = $ignore_list -join "|"
}

create-ignore-pattern

function refresh-submodules {
    $submodules = git submodule | Out-String
    Get-ChildItem "deps\" | ForEach-Object {
        # There can be folders in deps\ that are not listed in .gitmodules.
        # Only delete dep that is listed in .gitmodules
        if($submodules.Contains($_.Name)) {
            Remove-Item $_.FullName -Recurse -Force
        }
    }
}

# update the submodules of the given repo and push changes
# returns $true if the local repo was update
# returns $false if no changes were made
function update-local-repo {
    param (
        [string] $repo_name,
        [string] $new_branch_name
    )
    Push-Location $repo_name
    git checkout master
    git pull
    # Sometimes git fails to detect updates in submodules
    # Fix is to delete the submodule and reinitializes it
    if (Test-Path "deps\") {
        refresh-submodules
    }
    git submodule update --init
    # update all submodules except the ones mentioned in ignores.json
    git submodule foreach "case `$name in $ignore_pattern ) ;; *) git checkout master && git pull;; esac"
    # create new branch
    git checkout -B $new_branch_name
    # add updates and push to remote
    git add .
    $commit_output = git commit -m "Update dependencies" 2>&1
    $commit_result = $LASTEXITCODE
    # Only push if commit succeeded (there were changes)
    if($commit_result -eq 0) {
        git push -f origin $new_branch_name
    }
    Pop-Location
    # Return the commit output for caller to check
    return $commit_output
}

# update dependencies for Github repo
function update-repo-github {
    param(
        [string] $repo_name,
        [string] $new_branch_name
    )
    Push-Location $repo_name
    Write-Host "`nCreating PR"
    $working_directory = (Get-Location).Path
    gh pr create --title "[autogenerated] update dependencies" --body "Propagating dependency updates" --head $new_branch_name
    gh pr comment --body "/AzurePipelines run"
    Write-Host "Waiting for checks to start"
    Start-Sleep -Seconds 120

    Write-Host "Waiting for build to complete"
    $result = Watch-GitHubPRChecks -poll_interval 30 -timeout 120 -OnIteration { Show-PropagationStatus }
    if(-not $result.Success) {
        Fail-WithStatus "PR checks failed for repo ${repo_name}: $($result.Message)"
    }

    Write-Host "Merging PR"
    gh pr merge --squash --delete-branch
    if($LASTEXITCODE -ne 0) {
        Fail-WithStatus "Failed to merge PR for repo $repo_name"
    }
    # Wait for merge to complete
    Start-Sleep -Seconds 10
    Pop-Location
}


# get Azure DevOps organization and project from git remote URL
function get-azure-org-project {
    param(
        [string] $repo_name
    )
    Push-Location $repo_name
    $repo_url = git config --get remote.origin.url
    Pop-Location

    # Parse URL like https://msazure@dev.azure.com/msazure/One/_git/repo-name
    # or https://dev.azure.com/msazure/One/_git/repo-name
    if($repo_url -match "dev\.azure\.com/([^/]+)/([^/]+)/_git") {
        $org = $matches[1]
        $project = $matches[2]
        return @{
            Organization = "https://dev.azure.com/$org"
            Project = $project
        }
    }

    # Parse URL like https://msazure.visualstudio.com/DefaultCollection/One/_git/repo-name
    # or https://msazure.visualstudio.com/One/_git/repo-name
    if($repo_url -match "([^/]+)\.visualstudio\.com/(?:DefaultCollection/)?([^/]+)/_git") {
        $org = $matches[1]
        $project = $matches[2]
        return @{
            Organization = "https://dev.azure.com/$org"
            Project = $project
        }
    }

    Fail-WithStatus "Failed to parse Azure DevOps organization and project from remote URL: $repo_url"
}


# create PR to update dependencies for Azure repo using Azure CLI
function create-pr-azure {
    param(
        [string] $repo_name,
        [string] $new_branch_name
    )

    $azure_info = get-azure-org-project $repo_name
    $org = $azure_info.Organization
    $project = $azure_info.Project

    $pr_output = az repos pr create `
        --repository $repo_name `
        --source-branch $new_branch_name `
        --target-branch master `
        --title "[autogenerated] update dependencies" `
        --description "Propagating dependency updates" `
        --organization $org `
        --project $project `
        --output json

    if($LASTEXITCODE -ne 0) {
        Fail-WithStatus "Failed to create PR for repo $repo_name"
    }

    $pr_info = $pr_output | ConvertFrom-Json
    return $pr_info
}


# link work item to PR for Azure repo using Azure CLI
function link-work-item-to-pr-azure {
    param(
        [int] $pr_id,
        [string] $org,
        [string] $project
    )
    if(!$azure_work_item){
        Fail-WithStatus "Updating Azure repos requires providing a work item id. Provide work item id as: -azure_work_item [id]"
    }

    $output = az repos pr work-item add `
        --id $pr_id `
        --work-items $azure_work_item `
        --organization $org `
        --output json

    if($LASTEXITCODE -ne 0) {
        Fail-WithStatus "Failed to link work item to PR. Work item: $azure_work_item, PR ID: $pr_id"
    }
}


# approve PR for Azure repo using Azure CLI
function approve-pr-azure {
    param(
        [int] $pr_id,
        [string] $org
    )

    $output = az repos pr set-vote `
        --id $pr_id `
        --vote approve `
        --organization $org `
        --output json

    if($LASTEXITCODE -ne 0) {
        Fail-WithStatus "Failed to approve PR ID: $pr_id"
    }
}


# set PR for Azure repo to merge automatically once build completes using Azure CLI
function set-autocomplete-azure {
    param(
        [int] $pr_id,
        [string] $org
    )

    $output = az repos pr update `
        --id $pr_id `
        --auto-complete true `
        --squash true `
        --delete-source-branch true `
        --organization $org `
        --output json

    if($LASTEXITCODE -ne 0) {
        Fail-WithStatus "Failed to set autocomplete for PR ID: $pr_id"
    }
}


# wait until build completes for Azure repo using Azure CLI
function wait-until-complete-azure {
    param(
        [int] $pr_id,
        [string] $org,
        [string] $repo_name
    )

    Write-Host "`nWatching PR policies..."
    $success = Watch-AzurePRPolicies -pr_id $pr_id -org $org -poll_interval 30 -timeout 120 -ShowBuildDetails -OnIteration { Show-PropagationStatus }

    if(!$success) {
        # Check if PR completed despite policy failures (e.g., manually merged)
        $pr_output = az repos pr show --id $pr_id --organization $org --output json
        if($LASTEXITCODE -eq 0) {
            $pr_info = $pr_output | ConvertFrom-Json
            if($pr_info.status -eq "completed") {
                Write-Host "PR completed successfully" -ForegroundColor Green
                return
            }
        }
        Fail-WithStatus "PR $pr_id failed to complete. Check policy status above."
    }

    # Verify PR is completed
    $pr_output = az repos pr show --id $pr_id --organization $org --output json
    if($LASTEXITCODE -ne 0) {
        Fail-WithStatus "Failed to get PR status for ID: $pr_id"
    }

    $pr_info = $pr_output | ConvertFrom-Json
    if($pr_info.status -ne "completed") {
        # PR policies passed but PR not yet merged - wait a bit for autocomplete
        Write-Host "Waiting for PR to auto-complete..."
        $max_wait = 60
        $waited = 0
        while($waited -lt $max_wait) {
            Start-Sleep -Seconds 10
            $waited += 10
            $pr_output = az repos pr show --id $pr_id --organization $org --output json
            $pr_info = $pr_output | ConvertFrom-Json
            if($pr_info.status -eq "completed") {
                Write-Host "PR completed successfully" -ForegroundColor Green
                return
            }
        }
        Write-Host "Warning: PR policies passed but PR status is: $($pr_info.status)" -ForegroundColor Yellow
    } else {
        Write-Host "PR completed successfully" -ForegroundColor Green
    }
}


# update dependencies for Azure repo using Azure CLI
function update-repo-azure {
    param(
        [string] $repo_name,
        [string] $new_branch_name
    )

    $azure_info = get-azure-org-project $repo_name
    $org = $azure_info.Organization
    $project = $azure_info.Project

    Write-Host "`nCreating PR"
    $pr_info = create-pr-azure $repo_name $new_branch_name
    $pr_id = $pr_info.pullRequestId

    Write-Host "Linking work item to PR (PR ID: $pr_id)"
    link-work-item-to-pr-azure $pr_id $org $project

    Write-Host "Approving PR"
    approve-pr-azure $pr_id $org

    Write-Host "Enabling PR to autocomplete"
    set-autocomplete-azure $pr_id $org

    Write-Host "Waiting for build to complete"
    wait-until-complete-azure $pr_id $org $repo_name
}


# determine whether given repo is an azure repo or a github repo
function  get-repo-type {
    param (
        [string] $repo_name
    )
    Push-Location $repo_name
    $repo_url = git config --get remote.origin.url
    Pop-Location
    Write-Host $repo_url -NoNewline
    if($repo_url.Contains("github")){
        return "github"
    }elseif ($repo_url.Contains("azure") -or $repo_url.Contains("visualstudio.com")) {
        return "azure"
    }
    return "unknown"
}


# update dependencies for given repo
function update-repo {
    param(
        [string] $repo_name,
        [string] $new_branch_name
    )
    Write-Host "`n`nUpdating repo $repo_name"
    Set-RepoStatus -repo_name $repo_name -status $script:STATUS_IN_PROGRESS
    $global:current_repo = $repo_name

    # Ensure we're in the work directory
    Set-Location $global:work_dir

    [string]$git_output = (update-local-repo $repo_name $new_branch_name)
    if($git_output.Contains("nothing to commit")) {
        Write-Host "Nothing to commit, skipping repo $repo_name"
        Set-RepoStatus -repo_name $repo_name -status $script:STATUS_SKIPPED -message "No changes"
    } else {
        $repo_type = get-repo-type $repo_name
        if($repo_type -eq "github") {
            update-repo-github $repo_name $new_branch_name
            Set-RepoStatus -repo_name $repo_name -status $script:STATUS_UPDATED
        } elseif ($repo_type -eq "azure") {
            update-repo-azure $repo_name $new_branch_name
            Set-RepoStatus -repo_name $repo_name -status $script:STATUS_UPDATED
        } else {
            Fail-WithStatus "Unable to update repository $repo_name. Only Github and Azure repositories are supported."
        }
    }
    Write-Host "Done updating repo $repo_name"
}

# iterate over all repos and update them
function propagate-updates {
    # Save original directory to restore at exit
    Push-Location

    check-az-cli-exists -pat_token $azure_token
    check-gh-cli-exists

    # Generate branch name with timestamp
    $new_branch_name = "new_deps_" + (Get-Date -Format "yyyyMMddHHmmss")
    Write-Host "New branch name: $new_branch_name"

    # Create a new directory for this update session
    $global:work_dir = Join-Path (Get-Location).Path $new_branch_name
    New-Item -ItemType Directory -Path $global:work_dir -Force | Out-Null
    Set-Location $global:work_dir
    Write-Host "Working directory: $global:work_dir"

    # build dependency graph (or use cache)
    $cached_data = $null
    $repo_order = $null
    $repo_urls = $null

    if ($useCachedRepoOrder) {
        $cached_data = Get-CachedRepoOrder -root_list $root_list
    }

    if ($cached_data) {
        $repo_order = $cached_data.repo_order
        $repo_urls = $cached_data.repo_urls
        Write-Host "Using cached repo order"
        Set-Content -Path .\order.json -Value ($repo_order | ConvertTo-Json)
        # Clone repos that aren't already present using cached URLs
        Write-Host "Cloning repositories..."
        foreach ($repo_name in $repo_order) {
            if (-not (Test-Path -Path $repo_name)) {
                $repo_url = $repo_urls.$repo_name
                if ($repo_url) {
                    Write-Host "Cloning: $repo_name" -ForegroundColor Cyan
                    git clone $repo_url
                } else {
                    Write-Host "Warning: No URL cached for $repo_name, skipping" -ForegroundColor Yellow
                }
            }
        }
        Write-Host "Done cloning repositories"
    } else {
        Write-Host "Building dependency graph..."
        .$PSScriptRoot\build_graph.ps1 -root_list $root_list
        if($LASTEXITCODE -ne 0)
        {
            Pop-Location
            Write-Error("Could not build dependency graph for $root_list.")
            exit -1
        }
        Write-Host "Done building dependency graph"
        # build_graph.ps1 sets the cache, so read from it
        $cached_data = Get-CachedRepoOrder -root_list $root_list
        if (-not $cached_data) {
            Pop-Location
            Write-Error("Failed to get cached repo order after building graph.")
            exit -1
        }
        $repo_order = $cached_data.repo_order
        $repo_urls = $cached_data.repo_urls
    }

    # Initialize status tracking
    Initialize-RepoStatus -repos $repo_order

    Write-Host "Updating repositories in the following order: "
    for($i = 0; $i -lt $repo_order.Length; $i++){
        Write-Host "$($i+1). $($repo_order[$i])"
    }

    foreach ($repo in $repo_order) {
        update-repo $repo $new_branch_name
    }

    # Show final status
    Show-PropagationStatus -Final
    Write-Host "Done updating all repos!"

    # Restore original directory
    Pop-Location
}

propagate-updates
