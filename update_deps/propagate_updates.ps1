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
$helper_scripts = "$PSScriptRoot\helper_scripts"
. "$helper_scripts\install_az_cli.ps1"
. "$helper_scripts\install_gh_cli.ps1"
. "$helper_scripts\repo_order_cache.ps1"
. "$helper_scripts\status_tracking.ps1"
. "$helper_scripts\git_operations.ps1"
. "$helper_scripts\watch_azure_pr.ps1"
. "$helper_scripts\watch_github_pr.ps1"
. "$helper_scripts\azure_repo_ops.ps1"
. "$helper_scripts\github_repo_ops.ps1"
. "$helper_scripts\success_animation.ps1"


# update dependencies for given repo
function update-repo
{
    param(
        [string] $repo_name,
        [string] $new_branch_name
    )
    Write-Host "`n`nUpdating repo $repo_name"
    set-repo-status -repo_name $repo_name -status $script:STATUS_IN_PROGRESS
    $global:current_repo = $repo_name

    # Ensure we're in the work directory
    Set-Location $global:work_dir

    [string]$git_output = (update-local-repo $repo_name $new_branch_name)
    if($git_output.Contains("nothing to commit"))
    {
        Write-Host "Nothing to commit, skipping repo $repo_name"
        set-repo-status -repo_name $repo_name -status $script:STATUS_SKIPPED -message "No changes"
    }
    else
    {
        $repo_type = get-repo-type $repo_name
        $pr_url = $null
        if($repo_type -eq "github")
        {
            $pr_url = update-repo-github $repo_name $new_branch_name
            set-repo-status -repo_name $repo_name -status $script:STATUS_UPDATED -pr_url $pr_url
        }
        elseif ($repo_type -eq "azure")
        {
            $pr_url = update-repo-azure $repo_name $new_branch_name
            set-repo-status -repo_name $repo_name -status $script:STATUS_UPDATED -pr_url $pr_url
        }
        else
        {
            fail-with-status "Unable to update repository $repo_name. Only Github and Azure repositories are supported."
        }
    }
    Write-Host "Done updating repo $repo_name"
}

# iterate over all repos and update them
function propagate-updates
{
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

    if ($useCachedRepoOrder)
    {
        $cached_data = get-cached-repo-order -root_list $root_list
    }
    else
    {
        # will build fresh
    }

    if ($cached_data)
    {
        $repo_order = $cached_data.repo_order
        $repo_urls = $cached_data.repo_urls
        Write-Host "Using cached repo order"
        Set-Content -Path .\order.json -Value ($repo_order | ConvertTo-Json)
        # Clone repos that aren't already present using cached URLs
        Write-Host "Cloning repositories..."
        foreach ($repo_name in $repo_order)
        {
            if (-not (Test-Path -Path $repo_name))
            {
                $repo_url = $repo_urls.$repo_name
                if ($repo_url)
                {
                    Write-Host "Cloning: $repo_name" -ForegroundColor Cyan
                    git clone $repo_url
                }
                else
                {
                    Write-Host "Warning: No URL cached for $repo_name, skipping" -ForegroundColor Yellow
                }
            }
            else
            {
                # already present
            }
        }
        Write-Host "Done cloning repositories"
    }
    else
    {
        Write-Host "Building dependency graph..."
        .$helper_scripts\build_graph.ps1 -root_list $root_list
        if($LASTEXITCODE -ne 0)
        {
            Pop-Location
            fail-with-status "Could not build dependency graph for $root_list."
        }
        else
        {
            # graph built successfully
        }
        Write-Host "Done building dependency graph"
        # build_graph.ps1 sets the cache, so read from it
        $cached_data = get-cached-repo-order -root_list $root_list
        if (-not $cached_data)
        {
            Pop-Location
            fail-with-status "Failed to get cached repo order after building graph."
        }
        else
        {
            # cache retrieved
        }
        $repo_order = $cached_data.repo_order
        $repo_urls = $cached_data.repo_urls
    }

    # Initialize status tracking
    initialize-repo-status -repos $repo_order

    Write-Host "Updating repositories in the following order: "
    for($i = 0; $i -lt $repo_order.Length; $i++)
    {
        Write-Host "$($i+1). $($repo_order[$i])"
    }

    foreach ($repo in $repo_order)
    {
        update-repo $repo $new_branch_name
    }

    # Show final status and check if all succeeded
    $success = show-propagation-status -Final
    if ($success)
    {
        play-success-animation
    }
    else
    {
        Write-Host "Done updating repos (with some failures)" -ForegroundColor Yellow
    }

    # Restore original directory
    Pop-Location
}

propagate-updates
