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
#>


param(
    [Parameter(Mandatory=$false)][string]$azure_token, # Personal Access Token for Azure DevOps (optional, WAM used if not provided)
    [Parameter(Mandatory=$true)][Int32]$azure_work_item, # Work item id to link to Azure PRs
    [Parameter(Mandatory=$true)][string[]]$root_list # comma-separated list of URLs for repositories upto which updates must be propagated
)


# Source helper scripts
. "$PSScriptRoot\install_az_cli.ps1"
. "$PSScriptRoot\install_gh_cli.ps1"
. "$PSScriptRoot\watch_azure_pr.ps1" -pr_id 0 -org "dummy" 2>$null


# sleep for $seconds seconds and play spinner animation
function spin {
    param(
        [int] $seconds
    )
    $steps = @('|','/','-','\')
    $interval_ms = 50
    $iterations = [int](($seconds * 1000) / $interval_ms)

    # Write initial spinner character
    Write-Host $steps[0] -NoNewline -ForegroundColor Yellow
    Start-Sleep -Milliseconds $interval_ms

    for($i = 1; $i -lt $iterations; $i++){
        # Backspace and write next spinner character
        Write-Host "`b$($steps[$i % $steps.Length])" -NoNewline -ForegroundColor Yellow
        Start-Sleep -Milliseconds $interval_ms
    }
    # Erase spinner: backspace, space to overwrite, backspace to position cursor
    Write-Host "`b `b" -NoNewLine
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
    git commit -m "Update dependencies"
    git push -f origin $new_branch_name
    Pop-Location
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
    gh pr checks --watch
    Write-Host "Merging PR"
    gh pr merge --squash --delete-branch
    if($LASTEXITCODE -ne 0) {
        Write-Error "Failed to merge PR for repo $repo_name"
        exit -1
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

    Write-Error "Failed to parse Azure DevOps organization and project from remote URL: $repo_url"
    exit -1
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
        Write-Error "Failed to create PR for repo $repo_name"
        exit -1
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
        Write-Error "Updating Azure repos requires providing a work item id. Provide work item id as: -azure_work_item [id]"
        exit -1
    }

    $output = az repos pr work-item add `
        --id $pr_id `
        --work-items $azure_work_item `
        --organization $org `
        --output json

    if($LASTEXITCODE -ne 0) {
        Write-Error "Failed to link work item to PR. Work item: $azure_work_item, PR ID: $pr_id"
        exit -1
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
        Write-Error "Failed to approve PR ID: $pr_id"
        exit -1
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
        Write-Error "Failed to set autocomplete for PR ID: $pr_id"
        exit -1
    }
}


# wait until build completes for Azure repo using Azure CLI
function wait-until-complete-azure {
    param(
        [int] $pr_id,
        [string] $org
    )

    Write-Host "`nWatching PR policies..."
    $success = Watch-AzurePRPolicies -pr_id $pr_id -org $org -poll_interval 30 -timeout 120 -ShowBuildDetails

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
        Write-Error "PR $pr_id failed to complete. Check policy status above."
        exit -1
    }

    # Verify PR is completed
    $pr_output = az repos pr show --id $pr_id --organization $org --output json
    if($LASTEXITCODE -ne 0) {
        Write-Error "Failed to get PR status for ID: $pr_id"
        exit -1
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
    wait-until-complete-azure $pr_id $org
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

    # Ensure we're in the work directory
    Set-Location $global:work_dir

    [string]$git_output = (update-local-repo $repo_name $new_branch_name)
    if($git_output.Contains("nothing to commit")) {
        Write-Host "Nothing to commit, skipping repo $repo_name"
    } else {
        $repo_type = get-repo-type $repo_name
        if($repo_type -eq "github") {
            update-repo-github $repo_name $new_branch_name
        } elseif ($repo_type -eq "azure") {
            update-repo-azure $repo_name  $new_branch_name
        } else {
            Write-Error "Unable to update repository $repo_name. Only Github and Azure repositories are supported."
            exit -1
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

    # build dependency graph
    Write-Host "Building dependency graph..."

    .$PSScriptRoot\build_graph.ps1 -root_list $root_list
    if($LASTEXITCODE -ne 0)
    {
        Pop-Location
        Write-Error("Could not build dependency graph for $root_list.")
        exit -1
    }

    Write-Host "Done building dependency graph"

    $repo_order = (Get-Content -Path order.json) | ConvertFrom-Json
    Write-Host "Updating repositories in the following order: "
    for($i = 0; $i -lt $repo_order.Length; $i++){
        Write-Host "$($i+1). $($repo_order[$i])"
    }

    foreach ($repo in $repo_order) {
        update-repo $repo $new_branch_name
    }
    Write-Host "Done updating all repos!"

    # Restore original directory
    Pop-Location
}

propagate-updates
