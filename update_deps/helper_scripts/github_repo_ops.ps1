# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# GitHub repository operations for propagate_updates.ps1

# Source dependencies
. "$PSScriptRoot\status_tracking.ps1"
. "$PSScriptRoot\watch_github_pr.ps1"


# Find an active GitHub PR for a given branch. Returns the PR URL or $null.
function find-active-github-pr
{
    param(
        [string] $repo_name,
        [string] $branch_name
    )
    $result = $null

    Push-Location $repo_name
    $pr_check = gh pr list --head $branch_name --state open --json url --jq '.[0].url' 2>$null
    if ($LASTEXITCODE -eq 0 -and $pr_check)
    {
        $result = $pr_check.Trim()
    }
    else
    {
        # no active PR for this branch
    }
    Pop-Location

    return $result
}


# Get the status of a GitHub PR. Returns "MERGED", "CLOSED", or "OPEN".
function get-github-pr-status
{
    param(
        [string] $pr_url,
        [string] $repo_name
    )
    $result = "OPEN"

    Push-Location $repo_name
    $pr_check = gh pr view $pr_url --json state 2>&1
    if ($LASTEXITCODE -eq 0)
    {
        $pr_info = $pr_check | ConvertFrom-Json
        $result = $pr_info.state
    }
    else
    {
        # couldn't check PR status, assume open
    }
    Pop-Location

    return $result
}


# Monitor an existing GitHub PR until checks pass.
function monitor-github-pr
{
    param(
        [string] $repo_name
    )
    $autofix_attempts = 0

    Push-Location $repo_name

    while ($true)
    {
        $watch_result = watch-github-pr-checks -poll_interval $global:poll_interval -timeout 120 -OnIteration { [void](show-propagation-status) }
        if (-not $watch_result.Success)
        {
            # Try autofix if enabled
            if ($global:auto_fix -and -not $global:propagation_cancelled -and $watch_result.Message -match "^Failed:" -and $autofix_attempts -lt $global:MAX_AUTOFIX_ATTEMPTS)
            {
                $autofix_attempts++
                Write-Host "`n  AutoFix attempt $autofix_attempts of $global:MAX_AUTOFIX_ATTEMPTS" -ForegroundColor Magenta
                $branch_name = git rev-parse --abbrev-ref HEAD 2>$null
                $pr_url = gh pr view --json url --jq '.url' 2>$null
                $fix_result = invoke-copilot-autofix -repo_name $repo_name -branch_name $branch_name -pr_url $pr_url
                if ($fix_result)
                {
                    Write-Host "  AutoFix pushed a fix, restarting watch..." -ForegroundColor Magenta
                    # Loop continues — will re-enter watch
                }
                else
                {
                    Pop-Location
                    fail-with-status "PR checks failed for repo ${repo_name}: $($watch_result.Message). AutoFix could not resolve."
                }
            }
            else
            {
                if ($global:propagation_cancelled)
                {
                    # User cancelled — just break, don't close the PR
                    break
                }
                else
                {
                    Pop-Location
                    fail-with-status "PR checks failed for repo ${repo_name}: $($watch_result.Message)"
                }
            }
        }
        else
        {
            Write-Host "PR checks passed" -ForegroundColor Green

            # Wait for auto-merge to complete
            $merged = $false
            $pr_state = gh pr view --json state 2>&1
            if ($LASTEXITCODE -eq 0)
            {
                $state_data = $pr_state | ConvertFrom-Json
                if ($state_data.state -eq "MERGED") { $merged = $true }
            }
            else
            {
                # couldn't get PR state
            }

            if (-not $merged)
            {
                Write-Host "Waiting for auto-merge to complete..."
                $max_wait = 120
                $waited = 0
                while ($waited -lt $max_wait -and -not $merged)
                {
                    $cancelled = wait-or-cancel -seconds 2
                    if ($cancelled) { $global:propagation_cancelled = $true; break }
                    $waited += 2
                    $pr_state = gh pr view --json state 2>&1
                    if ($LASTEXITCODE -eq 0)
                    {
                        $state_data = $pr_state | ConvertFrom-Json
                        if ($state_data.state -eq "MERGED")
                        {
                            $merged = $true
                            Write-Host "PR auto-merged successfully" -ForegroundColor Green
                        }
                        else
                        {
                            # still waiting
                        }
                    }
                    else
                    {
                        # couldn't get PR state
                    }
                }

                if (-not $merged -and -not $global:propagation_cancelled)
                {
                    Write-Host "Auto-merge did not complete, attempting direct merge..." -ForegroundColor Yellow
                    $null = gh pr merge --squash --delete-branch 2>&1
                    if ($LASTEXITCODE -eq 0)
                    {
                        $merged = $true
                        Write-Host "PR merged successfully" -ForegroundColor Green
                    }
                    else
                    {
                        Pop-Location
                        fail-with-status "PR for repo $repo_name could not be merged. Check PR status."
                    }
                }
                else
                {
                    # merged or cancelled
                }
            }
            else
            {
                Write-Host "PR already merged" -ForegroundColor Green
            }

            break
        }
    }

    Pop-Location
}


# Close a GitHub PR, checking status first.
function close-pr-github
{
    param(
        [string] $pr_url,
        [string] $repo_name = ""
    )

    # If repo_name provided, use get-github-pr-status; otherwise query directly
    $pr_state = "OPEN"
    if ($repo_name)
    {
        $pr_state = get-github-pr-status -pr_url $pr_url -repo_name $repo_name
    }
    else
    {
        $state_output = gh pr view $pr_url --json state --jq '.state' 2>$null
        if ($LASTEXITCODE -eq 0 -and $state_output) { $pr_state = $state_output.Trim() }
    }

    if ($pr_state -eq "MERGED")
    {
        Write-Host "GitHub PR is already merged, skipping close" -ForegroundColor Green
    }
    elseif ($pr_state -eq "CLOSED")
    {
        Write-Host "GitHub PR is already closed, skipping" -ForegroundColor Gray
    }
    else
    {
        Write-Host "Closing GitHub PR: $pr_url" -ForegroundColor Yellow
        gh pr close $pr_url
        if ($LASTEXITCODE -eq 0)
        {
            Write-Host "GitHub PR closed successfully" -ForegroundColor Green
        }
        else
        {
            Write-Host "Warning: Failed to close GitHub PR: $pr_url" -ForegroundColor Yellow
        }
    }
}


# Reopen a closed GitHub PR.
function reopen-pr-github
{
    param(
        [string] $pr_url
    )

    Write-Host "Reopening GitHub PR: $pr_url" -ForegroundColor Cyan
    gh pr reopen $pr_url
    if ($LASTEXITCODE -eq 0)
    {
        Write-Host "GitHub PR reopened successfully" -ForegroundColor Green

        # Re-enable auto-merge (closing a PR cancels it)
        Write-Host "Re-enabling auto-merge..." -ForegroundColor Cyan
        $null = gh pr merge $pr_url --auto --squash --delete-branch 2>&1
        if ($LASTEXITCODE -eq 0)
        {
            Write-Host "Auto-merge re-enabled" -ForegroundColor Green
        }
        else
        {
            Write-Host "Warning: Could not re-enable auto-merge" -ForegroundColor Yellow
        }

        # Trigger pipeline AFTER enabling auto-merge
        Write-Host "Triggering pipeline..." -ForegroundColor Cyan
        $null = gh pr comment $pr_url --body "/AzurePipelines run" 2>&1
    }
    else
    {
        Write-Host "Warning: Failed to reopen GitHub PR: $pr_url" -ForegroundColor Yellow
    }
}


# update dependencies for Github repo
# Returns the PR URL for status tracking
function update-repo-github
{
    param(
        [string] $repo_name,
        [string] $new_branch_name,
        [hashtable] $description
    )
    $fn_result = $null

    Push-Location $repo_name
    Write-Host "`nCreating PR"
    $working_directory = (Get-Location).Path

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

    # Write body to temp file to avoid command line length limits
    $body_file = [System.IO.Path]::GetTempFileName()
    $pr_body | Set-Content -Path $body_file -Encoding UTF8

    try
    {
        $create_output = gh pr create --title $pr_title --body-file $body_file --head $new_branch_name 2>&1
    }
    finally
    {
        Remove-Item $body_file -ErrorAction SilentlyContinue
    }
    if ($LASTEXITCODE -ne 0)
    {
        Write-Host "PR creation returned error (may already exist), checking..." -ForegroundColor Yellow
    }
    else
    {
        Write-Host "PR created" -ForegroundColor Green
    }

    # Get PR URL
    $pr_info = gh pr view --json url 2>&1
    if($LASTEXITCODE -eq 0)
    {
        $pr_data = $pr_info | ConvertFrom-Json
        $fn_result = $pr_data.url
    }
    else
    {
        # couldn't get PR URL
    }

    # Update status with PR URL immediately so it shows even if later steps fail
    set-repo-status -repo_name $repo_name -status $script:STATUS_IN_PROGRESS -pr_url $fn_result

    # Show Windows notification with PR link
    if ($fn_result)
    {
        show-pr-notification -repo_name $repo_name -pr_url $fn_result
    }
    else
    {
        # no PR URL to notify about
    }

    # Enable auto-merge so GitHub merges once required checks pass
    Write-Host "Enabling auto-merge"
    $null = gh pr merge --auto --squash --delete-branch 2>&1
    if($LASTEXITCODE -ne 0)
    {
        Write-Host "Warning: Could not enable auto-merge, will merge manually" -ForegroundColor Yellow
    }
    else
    {
        Write-Host "Auto-merge enabled" -ForegroundColor Green
    }

    # Post pipeline trigger immediately - polling will detect when checks start
    Write-Host "Triggering pipeline..." -ForegroundColor Cyan
    $null = gh pr comment --body "/AzurePipelines run"

    # Poll until CI checks appear (not just CLA/license checks which are always present)
    Write-Host "Waiting for CI checks to start... (Press Ctrl+C to cancel)" -ForegroundColor Gray
    $max_wait = 180
    $waited = 0
    $checks_started = $false
    while ($waited -lt $max_wait -and -not $checks_started)
    {
        $cancelled = wait-or-cancel -seconds 5
        if ($cancelled) { $global:propagation_cancelled = $true; return $pr_url }
        $waited += 5
        $checks_output = gh pr checks --json name,state 2>&1
        if ($LASTEXITCODE -eq 0 -and $checks_output -ne "[]" -and $checks_output -ne "")
        {
            $checks = $checks_output | ConvertFrom-Json
            # Filter out license/CLA checks — wait for actual CI checks
            $ci_checks = @($checks | Where-Object { $_.name -notmatch "license|cla" })
            if ($ci_checks.Count -gt 0)
            {
                $checks_started = $true
                Write-Host "CI checks detected after ${waited}s ($($ci_checks.Count) check(s))" -ForegroundColor Green
            }
            else
            {
                # only CLA/license checks so far, keep waiting
            }
        }
        else
        {
            # checks not yet visible, keep polling
        }
    }
    if (-not $checks_started)
    {
        Write-Host "No checks detected after ${max_wait}s, proceeding to watch anyway" -ForegroundColor Yellow
    }
    else
    {
        # checks started
    }

    $autofix_attempts = 0
    $merged = $false

    while (-not $merged)
    {
        Write-Host "Waiting for build to complete"
        $watch_result = watch-github-pr-checks -poll_interval $global:poll_interval -timeout 120 -OnIteration { [void](show-propagation-status) }

        # Check if PR was auto-merged
        $pr_state = gh pr view --json state 2>&1
        if($LASTEXITCODE -eq 0)
        {
            $state_data = $pr_state | ConvertFrom-Json
            if($state_data.state -eq "MERGED")
            {
                $merged = $true
                Write-Host "PR auto-merged successfully" -ForegroundColor Green
            }
            else
            {
                # PR not merged yet
            }
        }
        else
        {
            # couldn't get PR state
        }

        if(-not $merged)
        {
            if(-not $watch_result.Success)
            {
                # Build failed — try autofix if enabled
                if ($global:auto_fix -and -not $global:propagation_cancelled -and $watch_result.Message -match "^Failed:" -and $autofix_attempts -lt $global:MAX_AUTOFIX_ATTEMPTS)
                {
                    $autofix_attempts++
                    Write-Host "`n  AutoFix attempt $autofix_attempts of $global:MAX_AUTOFIX_ATTEMPTS" -ForegroundColor Magenta
                    $branch_name = git rev-parse --abbrev-ref HEAD 2>$null
                    $current_pr_url = gh pr view --json url --jq '.url' 2>$null
                    $fix_result = invoke-copilot-autofix -repo_name $repo_name -branch_name $branch_name -pr_url $current_pr_url
                    if ($fix_result)
                    {
                        Write-Host "  AutoFix pushed a fix, restarting watch..." -ForegroundColor Magenta
                        # Loop continues — will re-enter watch
                    }
                    else
                    {
                        fail-with-status "PR checks failed for repo ${repo_name}: $($watch_result.Message). AutoFix could not resolve."
                    }
                }
                else
                {
                    if ($global:propagation_cancelled)
                    {
                        # User cancelled — just break, don't close the PR
                        break
                    }
                    else
                    {
                        fail-with-status "PR checks failed for repo ${repo_name}: $($watch_result.Message)"
                    }
                }
            }
            else
            {
                # Checks passed but auto-merge hasn't triggered yet, wait and retry
                Write-Host "Waiting for auto-merge to complete..."
                $max_wait = 120
                $waited = 0
                while($waited -lt $max_wait -and -not $merged)
                {
                    $cancelled = wait-or-cancel -seconds 2
                    if ($cancelled) { $global:propagation_cancelled = $true; break }
                    $waited += 2
                    $pr_state = gh pr view --json state 2>&1
                    if($LASTEXITCODE -eq 0)
                    {
                        $state_data = $pr_state | ConvertFrom-Json
                        if($state_data.state -eq "MERGED")
                        {
                            $merged = $true
                            Write-Host "PR auto-merged successfully" -ForegroundColor Green
                        }
                        else
                        {
                            # still waiting
                        }
                    }
                    else
                    {
                        # couldn't get PR state
                    }
                }

                if(-not $merged)
                {
                    # Auto-merge didn't fire — try merging directly
                    Write-Host "Auto-merge did not complete, attempting direct merge..." -ForegroundColor Yellow
                    $null = gh pr merge --squash --delete-branch 2>&1
                    if ($LASTEXITCODE -eq 0)
                    {
                        $merged = $true
                        Write-Host "PR merged successfully" -ForegroundColor Green
                    }
                    else
                    {
                        fail-with-status "PR for repo $repo_name could not be merged. Check PR status."
                    }
                }
                else
                {
                    # already logged success
                }
            }
        }
        else
        {
            # already merged
        }
    }

    # Wait for merge to settle
    Start-Sleep -Seconds 2
    Pop-Location

    return $fn_result
}
