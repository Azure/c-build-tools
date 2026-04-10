# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Per-repo update orchestration for propagate_updates.ps1.
# Resolves existing PRs (resume), runs local updates (fresh), and monitors PR completion.
# Dependencies: dot-sourced by propagate_updates.ps1 which loads all helper scripts.


# Resolve an existing PR URL for a repo — from saved state or by querying the remote.
# Always checks the remote first for an active PR on the branch (the latest one),
# then falls back to the saved PrUrl if no active PR exists.
# Returns the PR URL or $null.
function resolve-existing-pr
{
    param(
        [string] $repo_name,
        [string] $new_branch_name
    )
    $result = $null

    # Always check remote first — there may be a newer PR than what's saved
    Write-Host "  Checking for active PR on branch $new_branch_name..." -ForegroundColor Gray
    $repo_type = get-repo-type $repo_name
    if ($repo_type -eq "azure")
    {
        $result = find-active-azure-pr -repo_name $repo_name -branch_name $new_branch_name
    }
    elseif ($repo_type -eq "github")
    {
        $result = find-active-github-pr -repo_name $repo_name -branch_name $new_branch_name
    }
    else
    {
        # unknown repo type
    }

    if ($result)
    {
        Write-Host "Found active PR on branch: $result" -ForegroundColor Cyan
    }
    else
    {
        # No active PR on remote — check saved PrUrl (may be closed/abandoned)
        if ($global:repo_status.ContainsKey($repo_name) -and $global:repo_status[$repo_name].PrUrl)
        {
            $result = $global:repo_status[$repo_name].PrUrl
            Write-Host "Found saved PR from previous run: $result" -ForegroundColor Cyan
        }
        else
        {
            # no existing PR found
        }
    }

    return $result
}


# Get the disposition of a PR: "merged", "abandoned", or "active".
function get-pr-disposition
{
    param(
        [string] $pr_url,
        [string] $repo_name,
        [string] $repo_type
    )
    $result = "active"

    if ($repo_type -eq "azure")
    {
        $status = get-azure-pr-status -pr_url $pr_url -repo_name $repo_name
        if ($status -eq "completed")
        {
            $result = "merged"
        }
        elseif ($status -eq "abandoned")
        {
            $result = "abandoned"
        }
        else
        {
            $result = "active"
        }
    }
    elseif ($repo_type -eq "github")
    {
        $status = get-github-pr-status -pr_url $pr_url -repo_name $repo_name
        if ($status -eq "MERGED")
        {
            $result = "merged"
        }
        elseif ($status -eq "CLOSED")
        {
            $result = "abandoned"
        }
        else
        {
            $result = "active"
        }
    }
    else
    {
        # unknown repo type
    }

    return $result
}


# Check if a PR's checks have already failed (complete + unsuccessful).
# Returns a hashtable with AlreadyFailed ($true/$false) and Message.
# Used on resume to skip straight to autofix instead of re-watching.
function test-pr-checks-already-failed
{
    param(
        [string] $pr_url,
        [string] $repo_name,
        [string] $repo_type
    )
    $result = @{ AlreadyFailed = $false; Message = "" }

    if ($repo_type -eq "github")
    {
        Push-Location $repo_name
        $checks_output = gh pr checks $pr_url --json name,state,bucket 2>$null
        if ($LASTEXITCODE -eq 0 -and $checks_output -and $checks_output -ne "[]")
        {
            $checks = $checks_output | ConvertFrom-Json
            # Normalize to the format Test-ChecksComplete expects
            $normalized = @()
            foreach ($check in $checks)
            {
                $normalized += [PSCustomObject]@{
                    Name = $check.name
                    Status = (convert-github-bucket-to-normalized -bucket $check.bucket)
                    IsBlocking = $null
                }
            }
            $completion = Test-ChecksComplete -checks $normalized
            if ($completion.Complete -and -not $completion.Success)
            {
                $result.AlreadyFailed = $true
                $result.Message = $completion.Message
            }
            else
            {
                # checks not complete or already passed
            }
        }
        else
        {
            # no checks data
        }
        Pop-Location
    }
    elseif ($repo_type -eq "azure")
    {
        if ($pr_url -match "/pullrequest/(\d+)")
        {
            $pr_id = [int]$matches[1]
            $azure_info = get-azure-org-project $repo_name
            $display_data = get-policy-display-data -pr_id $pr_id -org $azure_info.Organization
            if ($display_data -and $display_data.Checks)
            {
                $completion = Test-ChecksComplete -checks $display_data.Checks
                if ($completion.Complete -and -not $completion.Success)
                {
                    $result.AlreadyFailed = $true
                    $result.Message = $completion.Message
                }
                else
                {
                    # checks not complete or already passed
                }
            }
            else
            {
                # no policy data
            }
        }
        else
        {
            # couldn't parse PR ID
        }
    }
    else
    {
        # unknown repo type
    }

    return $result
}


# Monitor an existing PR until completion.
function monitor-pr
{
    param(
        [string] $pr_url,
        [string] $repo_name,
        [string] $repo_type
    )

    if ($repo_type -eq "github")
    {
        monitor-github-pr -repo_name $repo_name
    }
    elseif ($repo_type -eq "azure")
    {
        monitor-azure-pr -pr_url $pr_url -repo_name $repo_name
    }
    else
    {
        fail-with-status "Unable to update repository $repo_name. Only Github and Azure repositories are supported."
    }
}


# Update dependencies for a given repo.
# Handles resume (existing PR) and fresh run (create new PR) paths.
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

    # --- Resolve existing PR (resume only) ---
    # On fresh runs the branch is new, so no PR can exist.
    # On resume, check for an existing PR to avoid duplicate pushes/PRs.
    $existing_pr_url = $null
    $repo_type = get-repo-type $repo_name

    if ($global:is_resume)
    {
        $existing_pr_url = resolve-existing-pr -repo_name $repo_name -new_branch_name $new_branch_name
    }
    else
    {
        # fresh run — skip PR lookup
    }

    if ($existing_pr_url)
    {
        # Check PR disposition: merged, abandoned, or active
        $disposition = get-pr-disposition -pr_url $existing_pr_url -repo_name $repo_name -repo_type $repo_type

        if ($disposition -eq "merged")
        {
            Write-Host "PR already merged, skipping repo" -ForegroundColor Green
            set-repo-status -repo_name $repo_name -status $script:STATUS_UPDATED -pr_url $existing_pr_url
            update-fixed-commit $repo_name
        }
        elseif ($disposition -eq "abandoned")
        {
            if ($global:auto_fix)
            {
                # Reopen the PR so autofix can fix it
                Write-Host "Previous PR was abandoned — reopening for autofix..." -ForegroundColor Magenta
                if ($repo_type -eq "github")
                {
                    reopen-pr-github -pr_url $existing_pr_url
                }
                elseif ($repo_type -eq "azure")
                {
                    reopen-pr-azure -pr_url $existing_pr_url -repo_name $repo_name
                }
                else
                {
                    fail-with-status "Unable to reopen PR for $repo_name. Unknown repo type."
                }

                # Now treat as active — run autofix + monitor
                Write-Host "Running AutoFix on reopened PR..." -ForegroundColor Magenta
                $logs = get-failed-build-logs -repo_name $repo_name -pr_url $existing_pr_url
                Push-Location $repo_name
                $branch_name = git rev-parse --abbrev-ref HEAD 2>$null
                $fix_result = invoke-copilot-autofix -repo_name $repo_name -branch_name $branch_name -pr_url $existing_pr_url -build_logs $logs
                Pop-Location
                if (-not $fix_result)
                {
                    fail-with-status "AutoFix could not resolve build failure for $repo_name."
                }
                else
                {
                    Write-Host "  AutoFix pushed a fix, monitoring PR..." -ForegroundColor Magenta
                }

                set-repo-status -repo_name $repo_name -status $script:STATUS_IN_PROGRESS -pr_url $existing_pr_url
                monitor-pr -pr_url $existing_pr_url -repo_name $repo_name -repo_type $repo_type
                set-repo-status -repo_name $repo_name -status $script:STATUS_UPDATED -pr_url $existing_pr_url
                update-fixed-commit $repo_name
            }
            else
            {
                # No autofix — fall through to fresh update to check if changes are still needed.
                Write-Host "Previous PR was abandoned: $existing_pr_url" -ForegroundColor Yellow
                Write-Host "Checking if changes are still needed..." -ForegroundColor Yellow
                $existing_pr_url = $null
            }
        }
        else
        {
            # PR is still active — check for regression or redundancy
            $pr_check = check-pr-would-regress -repo_name $repo_name
            if ($pr_check.WouldRegress)
            {
                fail-with-status "PR for $repo_name would regress submodules. Someone has already updated this repo with newer versions. Abandon the PR and start a new propagation."
            }
            elseif ($pr_check.AlreadyUpToDate)
            {
                Write-Host "Master already has all the submodule versions this PR would set. Closing PR and skipping." -ForegroundColor Green
                close-pr -repo_name $repo_name -pr_url $existing_pr_url
                set-repo-status -repo_name $repo_name -status $script:STATUS_SKIPPED -message "Already up to date"
                update-fixed-commit $repo_name
            }
            else
            {
                # PR still has changes to contribute

            # If autofix is enabled, check if the PR's checks have already failed.
            # If so, run autofix immediately instead of re-watching a known-bad build.
            if ($global:auto_fix)
            {
                $check_status = test-pr-checks-already-failed -pr_url $existing_pr_url -repo_name $repo_name -repo_type $repo_type
                if ($check_status.AlreadyFailed)
                {
                    Write-Host "PR checks already failed: $($check_status.Message)" -ForegroundColor Yellow
                    Write-Host "Running AutoFix before re-watching..." -ForegroundColor Magenta
                    $logs = get-failed-build-logs -repo_name $repo_name -pr_url $existing_pr_url
                    Push-Location $repo_name
                    $branch_name = git rev-parse --abbrev-ref HEAD 2>$null
                    $fix_result = invoke-copilot-autofix -repo_name $repo_name -branch_name $branch_name -pr_url $existing_pr_url -build_logs $logs
                    Pop-Location
                    if (-not $fix_result)
                    {
                        fail-with-status "PR checks failed for repo ${repo_name}: $($check_status.Message). AutoFix could not resolve."
                    }
                    else
                    {
                        Write-Host "  AutoFix pushed a fix, monitoring PR..." -ForegroundColor Magenta
                    }
                }
                else
                {
                    # checks not failed yet, proceed to normal monitoring
                }
            }
            else
            {
                # autofix not enabled
            }

            Write-Host "Monitoring existing PR..."
            # Re-enable auto-merge in case it was lost (e.g., PR was closed and reopened)
            if ($repo_type -eq "github")
            {
                Push-Location $repo_name
                $null = gh pr merge $existing_pr_url --auto --squash --delete-branch 2>&1
                # Trigger pipeline AFTER enabling auto-merge to avoid
                # "PR was updated after run command" rejection
                Write-Host "Triggering pipeline..." -ForegroundColor Cyan
                $null = gh pr comment $existing_pr_url --body "/AzurePipelines run" 2>&1
                Pop-Location
            }
            elseif ($repo_type -eq "azure" -and $existing_pr_url -match "/pullrequest/(\d+)")
            {
                $pr_id = [int]$matches[1]
                $azure_info = get-azure-org-project $repo_name
                set-autocomplete-azure $pr_id $azure_info.Organization
            }
            else
            {
                # unknown repo type
            }
            set-repo-status -repo_name $repo_name -status $script:STATUS_IN_PROGRESS -pr_url $existing_pr_url
            monitor-pr -pr_url $existing_pr_url -repo_name $repo_name -repo_type $repo_type
            set-repo-status -repo_name $repo_name -status $script:STATUS_UPDATED -pr_url $existing_pr_url
            update-fixed-commit $repo_name
            }
        }
    }

    # Fresh update path: no existing PR, or previous PR was abandoned
    if (-not $existing_pr_url -and
        $global:repo_status[$repo_name].Status -ne $script:STATUS_UPDATED -and
        $global:repo_status[$repo_name].Status -ne $script:STATUS_SKIPPED)
    {
        # No existing PR — do the full update-local-repo + create PR flow
        $update_result = (update-local-repo $repo_name $new_branch_name)
        [string]$git_output = $update_result.GitOutput
        $description = $update_result.Description
        if($git_output.Contains("nothing to commit"))
        {
            Write-Host "Nothing to commit, skipping repo $repo_name"
            set-repo-status -repo_name $repo_name -status $script:STATUS_SKIPPED -message "No changes"
        }
        else
        {
            if ($repo_type -eq "github")
            {
                $pr_url = update-repo-github $repo_name $new_branch_name $description
                set-repo-status -repo_name $repo_name -status $script:STATUS_UPDATED -pr_url $pr_url
                update-fixed-commit $repo_name
            }
            elseif ($repo_type -eq "azure")
            {
                $pr_url = update-repo-azure $repo_name $new_branch_name $description
                set-repo-status -repo_name $repo_name -status $script:STATUS_UPDATED -pr_url $pr_url
                update-fixed-commit $repo_name
            }
            else
            {
                fail-with-status "Unable to update repository $repo_name. Only Github and Azure repositories are supported."
            }
        }
    }
    Write-Host "Done updating repo $repo_name"
}
