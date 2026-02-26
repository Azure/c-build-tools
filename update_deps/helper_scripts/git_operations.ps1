# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Git operations functions for propagate_updates.ps1

# create a global variable $ignore_pattern
# $ignore pattern is used in the shell command for 'git submodule foreach' to ignore repos
function create-ignore-pattern
{
    $path_to_ignores = Join-Path $PSScriptRoot "..\ignores.json"
    # get list of repos to ignore from ignores.json
    $repos_to_ignore = (Get-Content -Path $path_to_ignores) | ConvertFrom-Json
    $ignore_list = New-Object -TypeName "System.Collections.ArrayList"
    # prepend "deps/" to the name of each repo
    foreach($repo_to_ignore in $repos_to_ignore)
    {
        [void]$ignore_list.Add("deps/"+$repo_to_ignore)
    }
    # join repo names to get pattern of the form "deps/{repo1}|deps/repo{2}|..."
    $global:ignore_pattern = $ignore_list -join "|"
}

# Initialize the ignore pattern when script is sourced
create-ignore-pattern

# Snapshot the current master HEAD commit for all repos in the work directory.
# Called once before propagation starts to establish a baseline. Entries are
# updated after each repo's PR merges via update-fixed-commit.
function snapshot-repo-commits
{
    param(
        [string[]] $repo_order
    )
    $commits = @{}
    # Calculate max repo name length for aligned output
    $max_name_len = ($repo_order | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    foreach ($repo_name in $repo_order)
    {
        if (Test-Path $repo_name)
        {
            Push-Location $repo_name
            $sha = (git rev-parse master 2>$null)
            if ($LASTEXITCODE -eq 0 -and $sha)
            {
                $commits[$repo_name] = $sha.Trim()
                $subject = (git log -1 --format="%s" $sha.Trim() 2>$null)
                if ($subject)
                {
                    # Truncate long commit messages for display
                    if ($subject.Length -gt 50)
                    {
                        $subject = $subject.Substring(0, 47) + "..."
                    }
                    else
                    {
                        # short enough to display as-is
                    }
                    Write-Host ("  {0,-$max_name_len} : {1}  {2}" -f $repo_name, $commits[$repo_name].Substring(0, 8), $subject)
                }
                else
                {
                    Write-Host ("  {0,-$max_name_len} : {1}" -f $repo_name, $commits[$repo_name].Substring(0, 8))
                }
            }
            else
            {
                Write-Host "  Warning: Could not get master commit for $repo_name" -ForegroundColor Yellow
            }
            Pop-Location
        }
        else
        {
            # repo not cloned yet, skip
        }
    }
    return $commits
}

# Update each submodule to its fixed commit, or latest master if no fixed commit is available
function update-submodules-to-fixed-commits
{
    # Parse ignore pattern into a list for matching
    $ignore_paths = @()
    if ($global:ignore_pattern)
    {
        $ignore_paths = $global:ignore_pattern -split '\|'
    }

    # Get submodule paths from .gitmodules
    if (Test-Path ".gitmodules")
    {
        $submodule_lines = git config --file .gitmodules --get-regexp '\.path$'
        if ($submodule_lines)
        {
            foreach ($line in $submodule_lines)
            {
                $sub_path = ($line -split "\s+", 2)[1]

                # Check if this submodule should be ignored
                if ($sub_path -in $ignore_paths)
                {
                    # ignored submodule, skip
                }
                else
                {
                    # Derive repo name from submodule path (e.g., "deps/c-util" -> "c-util")
                    $sub_repo_name = Split-Path $sub_path -Leaf

                    Push-Location $sub_path
                    if ($global:fixed_commits -and $global:fixed_commits.ContainsKey($sub_repo_name))
                    {
                        $target_sha = $global:fixed_commits[$sub_repo_name]
                        Write-Host "  Checking out $sub_path at fixed commit $($target_sha.Substring(0, 8))"
                        git fetch origin
                        git checkout $target_sha
                        # Reset console color — git checkout may leave ANSI color codes active
                        Write-Host "`e[0m" -NoNewline

                        # Warn if remote master has moved ahead of the fixed commit
                        $remote_sha = (git rev-parse origin/master 2>$null)
                        if ($LASTEXITCODE -eq 0 -and $remote_sha -and $remote_sha.Trim() -ne $target_sha)
                        {
                            Write-Host "  WARNING: $sub_repo_name has newer commits on master ($($remote_sha.Trim().Substring(0, 8))) that will NOT be propagated" -ForegroundColor Yellow
                            if (-not $global:skipped_newer_commits)
                            {
                                $global:skipped_newer_commits = @{}
                            }
                            $global:skipped_newer_commits[$sub_repo_name] = @{
                                FixedCommit = $target_sha
                                RemoteCommit = $remote_sha.Trim()
                            }
                        }
                        else
                        {
                            # remote master matches fixed commit
                        }
                    }
                    else
                    {
                        Write-Host "  Updating $sub_path to latest master (no fixed commit)"
                        git checkout master
                        Write-Host "`e[0m" -NoNewline
                        git pull
                    }
                    Pop-Location
                }
            }
        }
        else
        {
            # no submodules found
        }
    }
    else
    {
        # no .gitmodules file
    }
}

# After a repo's PR is merged, fetch the new master HEAD and update fixed_commits
# so that downstream repos use the commit created by this propagation.
function update-fixed-commit
{
    param(
        [string] $repo_name
    )

    if ($global:fixed_commits)
    {
        Push-Location $repo_name
        git fetch origin master 2>$null
        $new_sha = (git rev-parse origin/master 2>$null)
        if ($LASTEXITCODE -eq 0 -and $new_sha)
        {
            $global:fixed_commits[$repo_name] = $new_sha.Trim()
            Write-Host "  Updated fixed commit for $repo_name to $($new_sha.Trim().Substring(0, 8))"
        }
        else
        {
            Write-Host "  Warning: Could not fetch new master commit for $repo_name" -ForegroundColor Yellow
        }
        Pop-Location
    }
    else
    {
        # no fixed commits table, nothing to update
    }
}

# Show a summary of repos that had newer commits on master that were not propagated
function show-skipped-commits-summary
{
    if ($global:skipped_newer_commits -and $global:skipped_newer_commits.Count -gt 0)
    {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Yellow
        Write-Host "  NEWER COMMITS NOT PROPAGATED" -ForegroundColor Yellow
        Write-Host "========================================" -ForegroundColor Yellow
        Write-Host "The following repos had newer commits on master" -ForegroundColor Yellow
        Write-Host "that were not included in this propagation run:" -ForegroundColor Yellow
        Write-Host ""
        foreach ($repo in $global:skipped_newer_commits.Keys)
        {
            $info = $global:skipped_newer_commits[$repo]
            Write-Host "  $repo" -ForegroundColor Yellow -NoNewline
            Write-Host "  used: $($info.FixedCommit.Substring(0, 8))  remote: $($info.RemoteCommit.Substring(0, 8))"
        }
        Write-Host ""
        Write-Host "Consider running propagation again to pick up these changes." -ForegroundColor Yellow
        Write-Host "========================================" -ForegroundColor Yellow
    }
    else
    {
        # all repos were up to date
    }
}

function refresh-submodules
{
    $submodules = git submodule | Out-String
    Get-ChildItem "deps\" | ForEach-Object {
        # There can be folders in deps\ that are not listed in .gitmodules.
        # Only delete dep that is listed in .gitmodules
        if($submodules.Contains($_.Name))
        {
            # Suppress progress bar from Remove-Item (renders as garbled text in non-interactive terminals)
            $oldProgress = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
            $ProgressPreference = $oldProgress
        }
        else
        {
            # not a submodule, leave it
        }
    }
}

# Collect meaningful upstream changes for a repo by examining submodule deltas.
# Filters out dep-update commits (produced by this script) and recursively
# includes real changes from upstream repos that were updated during this run.
# Returns an array of change objects: @{ Repo; SHA; Subject }
function collect-upstream-changes
{
    param(
        [string] $repo_name
    )
    $changes = @()
    $seen_shas = @{}

    # Must be called from inside the repo directory
    if (-not (Test-Path ".gitmodules"))
    {
        # no .gitmodules file, nothing to collect
    }
    else
    {
        # Parse ignore pattern into a list for matching
        $ignore_paths = @()
        if ($global:ignore_pattern)
        {
            $ignore_paths = $global:ignore_pattern -split '\|'
        }

        $submodule_lines = git config --file .gitmodules --get-regexp '\.path$'
        if (-not $submodule_lines)
        {
            # no submodules found
        }
        else
        {
            foreach ($line in $submodule_lines)
            {
                $sub_path = ($line -split "\s+", 2)[1]
                if ($sub_path -in $ignore_paths)
                {
                    # ignored submodule, skip
                }
                else
                {
                    $sub_repo_name = Split-Path $sub_path -Leaf

                    # Get the current (old) submodule SHA from the index
                    $old_sha = $null
                    $diff_output = git diff --cached --submodule=short -- $sub_path 2>$null
                    if ($diff_output)
                    {
                        # diff output looks like: "Submodule deps/foo oldsha..newsha:"
                        # or "-Subproject commit oldsha" / "+Subproject commit newsha"
                        foreach ($diff_line in $diff_output)
                        {
                            if ($diff_line -match "^-Subproject commit ([0-9a-f]+)")
                            {
                                $old_sha = $matches[1]
                            }
                        }
                    }
                    else
                    {
                        # no diff for this submodule, it wasn't changed
                    }

                    if (-not $old_sha)
                    {
                        # submodule wasn't changed, skip
                    }
                    else
                    {
                        $new_sha = $null
                        if ($global:fixed_commits -and $global:fixed_commits.ContainsKey($sub_repo_name))
                        {
                            $new_sha = $global:fixed_commits[$sub_repo_name]
                        }
                        else
                        {
                            # no fixed commit, skip
                        }

                        if ($new_sha -and $old_sha -ne $new_sha)
                        {
                            Push-Location $sub_path

                            # Get commit log between old and new
                            $log_lines = git log --oneline "$old_sha..$new_sha" 2>$null
                            if ($log_lines)
                            {
                                foreach ($log_line in $log_lines)
                                {
                                    if ($log_line -match "^([0-9a-f]+)\s+(.+)$")
                                    {
                                        $commit_sha = $matches[1]
                                        $commit_subject = $matches[2]

                                        # Filter out dep-update commits produced by this script
                                        if ($commit_subject -eq "Update dependencies" -or
                                            $commit_subject -like "Update deps:*" -or
                                            $commit_subject -like "`[autogenerated`]*")
                                        {
                                            # dep-update commit, skip
                                        }
                                        else
                                        {
                                            if (-not $seen_shas.ContainsKey($commit_sha))
                                            {
                                                $seen_shas[$commit_sha] = $true
                                                $changes += @{
                                                    Repo = $sub_repo_name
                                                    SHA = $commit_sha
                                                    Subject = $commit_subject
                                                }
                                            }
                                            else
                                            {
                                                # duplicate SHA, already included
                                            }
                                        }
                                    }
                                    else
                                    {
                                        # couldn't parse log line
                                    }
                                }
                            }
                            else
                            {
                                # no commits in range
                            }

                            Pop-Location

                            # Recursively include real changes from upstream repos that
                            # were updated during this propagation run
                            if ($global:repo_change_descriptions -and
                                $global:repo_change_descriptions.ContainsKey($sub_repo_name))
                            {
                                foreach ($upstream_change in $global:repo_change_descriptions[$sub_repo_name])
                                {
                                    if (-not $seen_shas.ContainsKey($upstream_change.SHA))
                                    {
                                        $seen_shas[$upstream_change.SHA] = $true
                                        $changes += $upstream_change
                                    }
                                    else
                                    {
                                        # duplicate SHA, already included
                                    }
                                }
                            }
                            else
                            {
                                # no recorded upstream changes for this submodule
                            }
                        }
                        else
                        {
                            # SHA unchanged or no new SHA
                        }
                    }
                }
            }
        }
    }

    return $changes
}

# Build a formatted description from collected upstream changes.
# Returns a hashtable with CommitSubject, CommitBody, PrTitle, PrBody.
function build-propagation-description
{
    param(
        [array] $changes
    )

    $result = @{
        CommitSubject = "Update dependencies"
        CommitBody = ""
        PrTitle = "[autogenerated] update dependencies"
        PrBody = "Propagating dependency updates"
    }

    if (-not $changes -or $changes.Count -eq 0)
    {
        # no changes, use default descriptions
    }
    else
    {
        # Group changes by repo
        $grouped = @{}
        foreach ($change in $changes)
        {
            $repo = $change.Repo
            if (-not $grouped.ContainsKey($repo))
            {
                $grouped[$repo] = @()
            }
            $grouped[$repo] += $change
        }

        # Build commit subject: short summary
        $repo_names = @($grouped.Keys | Sort-Object)
        $first_change = $changes[0]
        if ($repo_names.Count -eq 1)
        {
            $subject = "Update deps: $($first_change.Repo): $($first_change.Subject)"
        }
        else
        {
            $subject = "Update deps: $($repo_names -join ', ')"
        }
        # Truncate subject to 72 chars
        if ($subject.Length -gt 72)
        {
            $subject = $subject.Substring(0, 69) + "..."
        }
        else
        {
            # short enough
        }
        $result.CommitSubject = $subject

        # Build commit body: detailed list grouped by repo
        $body_lines = @()
        $body_lines += ""
        $body_lines += "Dependency updates:"
        $body_lines += ""
        foreach ($repo in $repo_names)
        {
            $body_lines += "${repo}:"
            foreach ($change in $grouped[$repo])
            {
                $body_lines += "- $($change.SHA) $($change.Subject)"
            }
            $body_lines += ""
        }
        $result.CommitBody = $body_lines -join "`n"

        # Build PR title — only include repo names, not commit subjects
        $pr_title = "[autogenerated] update deps: " + ($repo_names -join ", ")
        if ($pr_title.Length -gt 120)
        {
            $pr_title = $pr_title.Substring(0, 117) + "..."
        }
        else
        {
            # short enough
        }
        $result.PrTitle = $pr_title

        # Build PR body: same as commit body but with markdown formatting
        $pr_body_lines = @()
        $pr_body_lines += "## Dependency Updates"
        $pr_body_lines += ""
        foreach ($repo in $repo_names)
        {
            $pr_body_lines += "### $repo"
            foreach ($change in $grouped[$repo])
            {
                $pr_body_lines += "- ``$($change.SHA)`` $($change.Subject)"
            }
            $pr_body_lines += ""
        }
        $result.PrBody = $pr_body_lines -join "`n"
    }

    return $result
}

# update the submodules of the given repo and push changes
# returns a hashtable with GitOutput (commit output) and Description (propagation description)
function update-local-repo
{
    param (
        [string] $repo_name,
        [string] $new_branch_name
    )
    $result = $null

    Push-Location $repo_name
    git checkout master
    Write-Host "`e[0m" -NoNewline
    git pull
    # Sometimes git fails to detect updates in submodules
    # Fix is to delete the submodule and reinitializes it
    if (Test-Path "deps\")
    {
        refresh-submodules
    }
    else
    {
        # no deps folder
    }
    git submodule update --init
    # update all submodules to their fixed commits (or latest master as fallback)
    update-submodules-to-fixed-commits
    # create new branch
    git checkout -B $new_branch_name
    Write-Host "`e[0m" -NoNewline
    # add updates and push to remote
    git add .

    # Collect upstream changes and build description
    $upstream_changes = collect-upstream-changes $repo_name
    $description = build-propagation-description $upstream_changes

    # Store change descriptions for downstream repos to reference
    if (-not $global:repo_change_descriptions)
    {
        $global:repo_change_descriptions = @{}
    }
    $global:repo_change_descriptions[$repo_name] = $upstream_changes

    # Build commit message with subject and body
    $commit_message = $description.CommitSubject
    if ($description.CommitBody)
    {
        $commit_message = "$($description.CommitSubject)`n$($description.CommitBody)"
    }
    else
    {
        # no body, subject only
    }

    $git_output = git commit -m $commit_message 2>&1
    $commit_result = $LASTEXITCODE
    # Only push if commit succeeded (there were changes)
    if($commit_result -eq 0)
    {
        git push -f origin $new_branch_name
    }
    else
    {
        # nothing to push
    }
    Pop-Location

    $result = @{
        GitOutput = [string]$git_output
        Description = $description
    }

    return $result
}

# determine whether given repo is an azure repo or a github repo
# Exits on failure
function get-repo-type
{
    param (
        [string] $repo_name
    )
    $result = $null

    Push-Location $repo_name
    $repo_url = git config --get remote.origin.url
    Pop-Location
    Write-Host $repo_url -NoNewline
    if($repo_url.Contains("github"))
    {
        $result = "github"
    }
    elseif ($repo_url.Contains("azure") -or $repo_url.Contains("visualstudio.com"))
    {
        $result = "azure"
    }
    else
    {
        Write-Error "Unknown repo type for URL: $repo_url"
        exit -1
    }

    return $result
}
