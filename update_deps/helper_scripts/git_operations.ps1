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
            Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
        else
        {
            # not a submodule, leave it
        }
    }
}

# update the submodules of the given repo and push changes
# returns commit output for caller to check
function update-local-repo
{
    param (
        [string] $repo_name,
        [string] $new_branch_name
    )
    $result = $null

    Push-Location $repo_name
    git checkout master
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
    # add updates and push to remote
    git add .
    $result = git commit -m "Update dependencies" 2>&1
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
