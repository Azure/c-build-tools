# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
#
# Pipeline-only dependency propagation. Azure DevOps PR operations use the REST API directly with the
# build account token; GitHub operations use the gh CLI.

<#
.SYNOPSIS
Propagates dependency updates up to the given root repositories.

.DESCRIPTION
Builds the dependency graph from the roots. Then, bottom-up, it updates each repo's submodules to
the snapshotted commits and, where anything changed, opens a PR. A repo starts as soon as every
repo it depends on has been propagated (its PR merged, or it had no changes), and all open PRs are
polled together, so independent dependency chains proceed in parallel instead of waiting for each
other. Azure PRs are created/approved/auto-completed via the Azure DevOps REST API; GitHub PRs via
the gh CLI.

.PARAMETER root_list
Comma-separated repository URLs up to which updates must be propagated.

.PARAMETER azure_work_item
Work item id linked to every Azure DevOps PR (satisfies the linked-work-items policy).

.PARAMETER poll_interval
Seconds between PR status polls while waiting for a PR to merge.

.PARAMETER NoCloseFailedPr
Leave a failed PR open instead of abandoning it.

.EXAMPLE
PS> .\propagate_updates.ps1 -azure_work_item 12345 -root_list https://.../_git/RepoA,https://.../_git/RepoB
#>
param(
    [Parameter(Mandatory = $false)][Int32] $azure_work_item,
    [Parameter(Mandatory = $false)][Int32] $poll_interval = 15,
    [switch] $NoCloseFailedPr,
    [Parameter(Mandatory = $false)][string[]] $root_list
)

# Source helper scripts (logging first so Write-Log is available everywhere).
$helper_scripts = "$PSScriptRoot\helper_scripts"
. "$helper_scripts\logging.ps1"
. "$helper_scripts\preflight.ps1"
. "$helper_scripts\check_powershell_version.ps1"
. "$helper_scripts\install_gh_cli.ps1"
. "$helper_scripts\status_tracking.ps1"
. "$helper_scripts\git_operations.ps1"
. "$helper_scripts\azure_repo_ops.ps1"
. "$helper_scripts\github_repo_ops.ps1"
. "$helper_scripts\update_repo.ps1"


function propagate-updates
{
    $global:original_dir = (Get-Location).Path
    $global:close_failed_pr = -not $NoCloseFailedPr.IsPresent
    $global:poll_interval = $poll_interval

    Write-Log STEP "Dependency propagation starting"
    Write-Log INFO ("roots: {0}" -f ($root_list -join ', '))
    Write-Log INFO ("work item: {0}; poll interval: {1}s; close failed PR: {2}" -f $azure_work_item, $poll_interval, $global:close_failed_pr)

    check-powershell-version
    ensure-gh-cli

    # Self-test: validate the GitHub token and Azure DevOps build-account access before any work.
    Invoke-Preflight -root_list $root_list

    # Authenticate git pushes to github.com with the gh token. Without this, the branch push for any
    # GitHub repo fails with "could not read Username for 'https://github.com'". gh is confirmed
    # working by preflight; setup-git writes a credential helper into the isolated global git config.
    Write-Log INFO "Configuring git GitHub credential helper (gh auth setup-git)"
    $setup_git = gh auth setup-git 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        Write-Log WARN "gh auth setup-git returned non-zero; GitHub pushes may fail: $($setup_git | Out-String)"
    }

    if (-not $azure_work_item)
    {
        fail-with-status "azure_work_item is required. Provide: -azure_work_item [id]"
    }
    if (-not $root_list)
    {
        fail-with-status "root_list is required. Provide: -root_list repo1,repo2,..."
    }

    $new_branch_name = "new_deps_" + (Get-Date -Format "yyyyMMddHHmmss")
    Write-Log INFO "Propagation branch name: $new_branch_name"

    $global:work_dir = Join-Path (Get-Location).Path $new_branch_name
    New-Item -ItemType Directory -Path $global:work_dir -Force | Out-Null
    Set-Location $global:work_dir
    Write-Log INFO "Work directory: $global:work_dir"

    $repo_order = $null
    $repo_urls = $null
    $repo_edges = $null

    Write-Log STEP "Building dependency graph"
    . "$helper_scripts\build_graph.ps1" -root_list $root_list
    if (-not $repo_order -or $repo_order.Count -eq 0)
    {
        fail-with-status "Could not build dependency graph for $($root_list -join ', ')."
    }
    Write-Log INFO "Dependency graph built ($($repo_order.Count) repos)"

    # Now that the graph is known, validate GitHub write access (SSO + push) to the discovered
    # github.com repos before opening any PRs, so a non-authorized token fails fast.
    Test-GitHubRepoAccess -repo_urls @($repo_urls.Values)

    Write-Log STEP "Ensuring all repositories are cloned"
    Set-Location $global:work_dir
    foreach ($repo_name in $repo_order)
    {
        if (-not (Test-Path -Path $repo_name))
        {
            if ($repo_urls.ContainsKey($repo_name))
            {
                clone-repo-with-retry -repo_url $repo_urls[$repo_name] -target_dir $repo_name
            }
            else
            {
                Write-Log WARN "No URL for $repo_name; skipping clone"
            }
        }
    }

    initialize-repo-status -repos $repo_order

    # Snapshot master HEAD commits for all repos before starting. After each repo's PR merges,
    # update-fixed-commit advances its entry so downstream repos pick up the propagated commit.
    Write-Log STEP "Snapshotting master commits for all repos"
    Set-Location $global:work_dir
    $global:fixed_commits = snapshot-repo-commits -repo_order $repo_order
    Write-Log INFO "Fixed commits captured for $($global:fixed_commits.Count) repos"

    Write-Log INFO "Dependencies (a repo's PR opens as soon as all of these are propagated):"
    foreach ($repo_name in $repo_order)
    {
        $deps = @($repo_edges[$repo_name])
        Write-Log INFO ("  {0} <- {1}" -f $repo_name, $(if ($deps.Count -gt 0) { $deps -join ', ' } else { '(none)' }))
    }

    update-repos-greedily -repo_order $repo_order -repo_edges $repo_edges -new_branch_name $new_branch_name

    $success = show-propagation-status -Final
    show-skipped-commits-summary
    restore-original-directory

    if ($success)
    {
        Write-Log STEP "Dependency propagation completed successfully"
    }
    else
    {
        # Do not exit green when repos are still pending or failed.
        fail-with-status "Dependency propagation finished with failures or pending repos."
    }
}

propagate-updates
