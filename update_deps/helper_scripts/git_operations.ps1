# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Git operations functions for propagate_updates.ps1

# Read the names of repos excluded from propagation (ignores.json).
function get-repos-to-ignore
{
    $path_to_ignores = Join-Path $PSScriptRoot "..\ignores.json"
    return ((Get-Content -Path $path_to_ignores) | ConvertFrom-Json)
}

# create a global variable $ignore_pattern
# $ignore pattern is used in the shell command for 'git submodule foreach' to ignore repos
function create-ignore-pattern
{
    # get list of repos to ignore from ignores.json
    $repos_to_ignore = get-repos-to-ignore
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

# Extract the repository name from a URL or path.
# Example: https://github.com/Azure/c-build-tools.git -> c-build-tools
function get-name-from-url
{
    param(
        [string] $url
    )
    $last = ($url.TrimEnd('/', '\') -split '[/\\]')[-1]
    return ($last -replace '\.git$', '')
}

# Reset console colors after git output in interactive runs (git may leave ANSI color codes active).
function reset-console-color
{
    if (-not (test-pipeline-mode))
    {
        Write-Host "$([char]27)[0m" -NoNewline
    }
    else
    {
        # pipeline logs need no reset
    }
}

# Run git and return its exit code. Pipeline runs are time-bounded and captured, since nothing can
# answer a prompt there. Interactive runs stay attached to the console so progress is visible and
# credential or signing prompts can be answered; git itself aborts a stalled transfer.
function invoke-git-command
{
    param(
        [string[]] $git_args,
        [int] $timeout_sec = 600
    )
    if (test-pipeline-mode)
    {
        $run = Invoke-NativeWithTimeout -File git -Arguments $git_args -TimeoutSec $timeout_sec
        foreach ($text in @($run.StdOut, $run.StdErr))
        {
            if ($text -and $text.Trim())
            {
                Write-Host (Protect-Secret $text.TrimEnd())
            }
            else
            {
                # no output on this stream
            }
        }
        return $run.ExitCode
    }
    else
    {
        # A stalled transfer (under 1 byte/s for 60 seconds) is aborted, as in pipeline runs.
        & git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=60 @git_args | Out-Host
        return $LASTEXITCODE
    }
}

# --- Local git object cache (mirror + alternates) -----------------------------------------------
# Every parent repo re-clones its whole deps/ submodule set, so without a cache the same dependency
# (c-build-tools, c-pal, c-util, ...) is fetched once per parent. Instead each unique repository is
# mirrored once into a per-run cache; subsequent clones (top-level and submodule) reference that
# mirror via git alternates, so their objects come from local disk rather than the network. Full
# history stays present, so PR-description log reads and fixed-commit checkouts keep working.
$global:git_mirror_index = @{}

function get-mirror-cache-dir
{
    if ($global:work_dir) { $base = $global:work_dir } else { $base = (Get-Location).Path }
    $dir = Join-Path $base '_gitmirrors'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

# Run a networked git command (e.g. fetch), retrying on failure. Returns $true on success. Pipeline
# attempts have a wall-clock limit so a stalled transfer cannot block the run, and callers check the
# result because a failed fetch must never silently leave stale commits behind.
function invoke-git-with-retry
{
    param(
        [string[]] $git_args,
        [int] $max_attempts = 3,
        [int] $timeout_sec = 600
    )
    $result = $false
    for ($attempt = 1; $attempt -le $max_attempts; $attempt++)
    {
        $exit_code = invoke-git-command -git_args $git_args -timeout_sec $timeout_sec
        if ($exit_code -eq 0)
        {
            $result = $true
            break
        }
        else
        {
            Write-Log WARN ("git {0} failed with exit code {1} in {2} (attempt {3}/{4})" -f ($git_args -join ' '), $exit_code, (Get-Location).Path, $attempt, $max_attempts)
        }
        if ($attempt -lt $max_attempts)
        {
            Start-Sleep -Seconds 10
        }
        else
        {
            # out of attempts
        }
    }
    return $result
}

# Ensure a bare mirror of $repo_url exists in the cache. Returns the mirror path, or $null if the
# mirror could not be created (callers then fall back to a normal networked clone).
function ensure-git-mirror
{
    param(
        [string] $repo_url,
        [string] $repo_name
    )
    if (-not $repo_name) { $repo_name = get-name-from-url $repo_url }
    if ($global:git_mirror_index.ContainsKey($repo_name))
    {
        $existing = $global:git_mirror_index[$repo_name]
        if ($existing -and (Test-Path $existing)) { return $existing }
    }
    $mirror = Join-Path (get-mirror-cache-dir) "$repo_name.git"
    if (Test-Path $mirror)
    {
        $global:git_mirror_index[$repo_name] = $mirror
        return $mirror
    }
    for ($attempt = 1; $attempt -le 3; $attempt++)
    {
        if (Test-Path $mirror) { Remove-Item -Recurse -Force $mirror -ErrorAction SilentlyContinue }
        Write-Log INFO "Mirroring $repo_name into local git cache (attempt $attempt/3)"
        $exit_code = invoke-git-command -git_args @('clone', '--mirror', $repo_url, $mirror) -timeout_sec 600
        if ($exit_code -eq 0 -and (Test-Path $mirror))
        {
            $global:git_mirror_index[$repo_name] = $mirror
            return $mirror
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds 10 }
    }
    if (Test-Path $mirror) { Remove-Item -Recurse -Force $mirror -ErrorAction SilentlyContinue }
    Write-Log WARN "Could not mirror $repo_name; will clone it without the local cache"
    return $null
}

# Initialize and update all submodules, sharing objects from the local mirror cache. Replaces a
# plain "git submodule update --init" so each submodule references a one-time local mirror of its
# repository instead of fetching the same dependency again for every parent repo.
function update-submodules-with-cache
{
    if (-not (Test-Path ".gitmodules"))
    {
        return
    }
    # init resolves relative submodule URLs and copies them into .git/config
    git submodule init
    if ($LASTEXITCODE -ne 0)
    {
        fail-with-status "Could not initialize submodules in $((Get-Location).Path)."
    }
    $path_lines = git config --file .gitmodules --get-regexp '\.path$'
    if (-not $path_lines)
    {
        return
    }
    foreach ($line in $path_lines)
    {
        $key = ($line -split "\s+", 2)[0]
        $sub_name = $key -replace '^submodule\.', '' -replace '\.path$', ''
        $sub_path = ($line -split "\s+", 2)[1]
        $sub_url = (git config "submodule.$sub_name.url" 2>$null)

        $ref_args = @()
        if ($sub_url)
        {
            $mirror = ensure-git-mirror -repo_url $sub_url -repo_name (get-name-from-url $sub_url)
            if ($mirror) { $ref_args += @('--reference', $mirror) }
        }
        $update_args = @('submodule', 'update', '--init') + $ref_args + @('--', $sub_path)
        if (-not (invoke-git-with-retry -git_args $update_args -max_attempts 3 -timeout_sec 600))
        {
            Write-Host "  submodule update failed for $sub_path; retrying without local cache" -ForegroundColor Yellow
            if (-not (invoke-git-with-retry -git_args @('submodule', 'update', '--init', '--', $sub_path) -max_attempts 3 -timeout_sec 600))
            {
                fail-with-status "Could not initialize submodule $sub_path."
            }
        }
    }
}

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

# Check if a submodule's current commit is ahead of a target commit.
# Must be called from inside the submodule directory.
# Returns $true if current HEAD is strictly ahead of target_sha.
function test-submodule-is-ahead
{
    param(
        [string] $target_sha
    )
    $result = $false

    $current_sha = (git rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $current_sha)
    {
        $current_sha = $current_sha.Trim()
        if ($current_sha -ne $target_sha)
        {
            git merge-base --is-ancestor $target_sha $current_sha 2>$null
            if ($LASTEXITCODE -eq 0)
            {
                $result = $true
            }
            else
            {
                # target is not ancestor of current
            }
        }
        else
        {
            # same SHA
        }
    }
    else
    {
        # couldn't determine current SHA
    }

    return $result
}

# Check if resuming with a PR would regress any submodule compared to current master.
# Also detects if master already has all changes (PR is redundant).
# Returns a hashtable: { WouldRegress = $bool; AlreadyUpToDate = $bool }
function check-pr-would-regress
{
    param(
        [string] $repo_name
    )
    $would_regress = $false
    $all_up_to_date = $true

    Push-Location $repo_name

    # Fetch latest master
    [void](invoke-git-with-retry -git_args @('fetch', 'origin', 'master'))

    if (Test-Path ".gitmodules")
    {
        $submodule_lines = git config --file .gitmodules --get-regexp '\.path$'
        if ($submodule_lines)
        {
            foreach ($line in $submodule_lines)
            {
                $sub_path = ($line -split "\s+", 2)[1]
                $sub_repo_name = Split-Path $sub_path -Leaf

                if ($global:fixed_commits -and $global:fixed_commits.ContainsKey($sub_repo_name))
                {
                    $target_sha = $global:fixed_commits[$sub_repo_name]

                    # Get what master currently has for this submodule
                    $master_sub_sha = git ls-tree origin/master -- $sub_path 2>$null
                    if ($master_sub_sha -match '([0-9a-f]{40})')
                    {
                        $current_sha = $matches[1]

                        if ($current_sha -eq $target_sha)
                        {
                            # master already at the target - this submodule is up to date
                        }
                        else
                        {
                            # Check if current master is ahead of target
                            Push-Location $sub_path
                            [void](invoke-git-with-retry -git_args @('fetch', 'origin'))
                            $is_ahead = test-submodule-is-ahead -target_sha $target_sha
                            if ($is_ahead)
                            {
                                Write-Host "  REGRESSION: $sub_repo_name on master is at $($current_sha.Substring(0, 8)) which is AHEAD of fixed commit $($target_sha.Substring(0, 8))" -ForegroundColor Red
                                Write-Host "  Someone has already updated this repo with newer submodule versions." -ForegroundColor Red
                                $would_regress = $true
                            }
                            else
                            {
                                # target is newer than current - this submodule still needs updating
                                $all_up_to_date = $false
                            }
                            Pop-Location
                        }
                    }
                    else
                    {
                        # couldn't parse submodule SHA from master
                        $all_up_to_date = $false
                    }
                }
                else
                {
                    # no fixed commit for this submodule - can't determine if up to date
                }
            }
        }
        else
        {
            # no submodule lines
            $all_up_to_date = $false
        }
    }
    else
    {
        # no .gitmodules
        $all_up_to_date = $false
    }

    Pop-Location
    return @{ WouldRegress = $would_regress; AlreadyUpToDate = $all_up_to_date }
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
                        # A failed fetch is tolerated here when the target is already present locally
                        # (e.g. from the mirror); the checkout is verified below either way.
                        [void](invoke-git-with-retry -git_args @('fetch', 'origin'))

                        # Check if the submodule is already at or ahead of the target commit
                        $current_sha = (git rev-parse HEAD 2>$null)
                        if ($LASTEXITCODE -eq 0 -and $current_sha)
                        {
                            $current_sha = $current_sha.Trim()
                        }
                        else
                        {
                            $current_sha = $null
                        }

                        if ($current_sha -eq $target_sha)
                        {
                            Write-Host "  $sub_path already at fixed commit $($target_sha.Substring(0, 8))"
                        }
                        elseif ($current_sha)
                        {
                            $is_ahead = test-submodule-is-ahead -target_sha $target_sha
                            if ($is_ahead)
                            {
                                # Current commit is ahead of target - do NOT downgrade
                                Write-Host "  $sub_path is already at $($current_sha.Substring(0, 8)) which is ahead of fixed commit $($target_sha.Substring(0, 8)), keeping current" -ForegroundColor Yellow
                            }
                            else
                            {
                                # Target is not an ancestor of current - could be a different branch or target is newer
                                Write-Host "  Checking out $sub_path at fixed commit $($target_sha.Substring(0, 8))"
                                git checkout $target_sha
                                reset-console-color
                            }
                        }
                        else
                        {
                            # Couldn't determine current SHA - proceed with checkout
                            Write-Host "  Checking out $sub_path at fixed commit $($target_sha.Substring(0, 8))"
                            git checkout $target_sha
                            reset-console-color
                        }

                        # The submodule must now be at (or ahead of) its fixed commit. Anything else
                        # (e.g. the commit was never fetched) would propagate a stale dependency.
                        git merge-base --is-ancestor $target_sha HEAD 2>$null
                        if ($LASTEXITCODE -ne 0)
                        {
                            fail-with-status "Could not check out $sub_path at its fixed commit $target_sha."
                        }
                        else
                        {
                            # at or ahead of the fixed commit
                        }

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
                        reset-console-color
                        if (-not (invoke-git-with-retry -git_args @('pull') -timeout_sec 600))
                        {
                            fail-with-status "Could not update $sub_path to its latest master commit."
                        }
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

# Update c-build-tools YAML refs to match the current submodule SHA.
# After update-submodules-to-fixed-commits has checked out the new c-build-tools commit,
# this function updates inline ref: fields in build/*.yml files with "repository: c_build_tools"
# blocks. This prevents validate_c_build_tools_ref from failing on propagation PRs.
function update-c-build-tools-yaml-refs
{
    # Only repos with submodules have a .gitmodules file
    if (-not (Test-Path ".gitmodules"))
    {
        # no submodules, nothing to update
    }
    else
    {
        # Parse .gitmodules to find the c-build-tools submodule path
        $submodule_path = ""
        $current_path = ""
        $found_c_build_tools = $false

        foreach ($line in (Get-Content ".gitmodules"))
        {
            # Check for submodule section header
            if ($line -match '^\[submodule\s+"([^"]+)"\]')
            {
                $current_path = ""
                $found_c_build_tools = $false
            }
            # Extract the submodule path
            if ($line -match '^\s*path\s*=\s*(.+)$')
            {
                $current_path = $Matches[1].Trim()
            }
            # Check if this submodule's URL points to c-build-tools
            if ($line -match '^\s*url\s*=\s*.*c-build-tools')
            {
                $found_c_build_tools = $true
            }
            # If we found the c-build-tools URL and have its path, we're done
            if ($found_c_build_tools -and $current_path -ne "")
            {
                $submodule_path = $current_path
                break
            }
            else
            {
                # haven't found c-build-tools submodule yet, continue parsing
            }
        }

        if ($submodule_path -ne "")
        {
            # Get the c-build-tools submodule SHA from the working tree (not HEAD, since
            # update-submodules-to-fixed-commits has already checked out the new commit)
            $new_sha = ""
            if (Test-Path $submodule_path)
            {
                $new_sha = (git -C $submodule_path rev-parse HEAD 2>$null)
                if ($LASTEXITCODE -ne 0)
                {
                    $new_sha = ""
                }
                else
                {
                    $new_sha = $new_sha.Trim()
                }
            }
            else
            {
                # submodule path doesn't exist
            }

            if ($new_sha -eq "")
            {
                Write-Host "  Warning: Could not get c-build-tools submodule SHA" -ForegroundColor Yellow
            }
            else
            {
                Write-Host "  c-build-tools submodule SHA: $($new_sha.Substring(0, 12))..."

                # Find pipeline YAML files in build/ that reference c_build_tools
                $yml_files = Get-ChildItem -Path "build" -Filter "*.yml" -ErrorAction SilentlyContinue
                foreach ($file in $yml_files)
                {
                    # Skip files that don't reference c_build_tools
                    $content = Get-Content -Path $file.FullName -Raw -ErrorAction SilentlyContinue
                    if (-not $content -or $content -notmatch 'repository:\s*c_build_tools')
                    {
                        # file does not reference c_build_tools, skip
                    }
                    else
                    {
                        # Parse lines to find the ref: value inside the c_build_tools repository block
                        $lines = Get-Content -Path $file.FullName
                        $in_c_build_tools_block = $false
                        $ref_line_index = -1
                        $ref_value = ""

                        for ($i = 0; $i -lt $lines.Count; $i++)
                        {
                            $line = $lines[$i]

                            # Detect start of c_build_tools repository block
                            if ($line -match '^\s*-?\s*repository:\s*c_build_tools\s*$')
                            {
                                $in_c_build_tools_block = $true
                            }
                            elseif ($in_c_build_tools_block)
                            {
                                # Exit block on next repository definition or non-indented line
                                if ($line -match '^\s*-\s*repository:' -or ($line -match '^\S' -and $line -notmatch '^\s*$'))
                                {
                                    $in_c_build_tools_block = $false
                                }
                                elseif ($line -match '^\s*ref:\s*(.+)$')
                                {
                                    # Found the ref: line in the c_build_tools block
                                    $ref_value = $Matches[1].Trim()
                                    $ref_line_index = $i
                                    $in_c_build_tools_block = $false
                                }
                                else
                                {
                                    # other line inside the block (type, name, endpoint), skip
                                }
                            }
                            else
                            {
                                # not in c_build_tools block, skip line
                            }
                        }

                        # Update SHA refs that don't match the submodule
                        if ($ref_line_index -ne -1 -and
                            $ref_value -ne "refs/heads/master" -and
                            $ref_value -match '^[0-9a-f]{40}$' -and
                            $ref_value -ne $new_sha)
                        {
                            $lines[$ref_line_index] = $lines[$ref_line_index] -replace 'ref:\s*.+$', "ref: $new_sha"
                            $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                            [System.IO.File]::WriteAllLines($file.FullName, $lines, $utf8NoBom)
                            Write-Host "  Updated $($file.Name) ref: $($ref_value.Substring(0, 12))... -> $($new_sha.Substring(0, 12))..." -ForegroundColor Green
                        }
                        else
                        {
                            # ref already matches, is refs/heads/master, or not found
                        }
                    }
                }
            }
        }
        else
        {
            # no c-build-tools submodule found, nothing to update
        }
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
        if (-not (invoke-git-with-retry -git_args @('fetch', 'origin', 'master')))
        {
            # Without the merged master, repos up the chain would be updated to the stale pre-merge commit.
            fail-with-status "Could not fetch the merged master of $repo_name."
        }
        $new_sha = (git rev-parse origin/master 2>$null)
        if ($LASTEXITCODE -eq 0 -and $new_sha)
        {
            $global:fixed_commits[$repo_name] = $new_sha.Trim()
            Write-Host "  Updated fixed commit for $repo_name to $($new_sha.Trim().Substring(0, 8))"
        }
        else
        {
            fail-with-status "Could not resolve the merged master of $repo_name after fetching it."
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

                                        # Replace GitHub PR references like (#123) with full
                                        # URLs to prevent Azure DevOps from auto-linking them
                                        # as ADO work items
                                        if ($commit_subject -match '\(#(\d+)\)')
                                        {
                                            $sub_remote_url = (git config --get remote.origin.url 2>$null)
                                            if ($sub_remote_url -match 'github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$')
                                            {
                                                $gh_slug = $matches[1]
                                                $commit_subject = [regex]::Replace($commit_subject, '\(#(\d+)\)', { param($m) "(https://github.com/$gh_slug/pull/$($m.Groups[1].Value))" })
                                            }
                                            else
                                            {
                                                # not a GitHub repo, just strip the reference
                                                $commit_subject = $commit_subject -replace '\s*\(#\d+\)\s*', ' '
                                                $commit_subject = $commit_subject.Trim()
                                            }
                                        }
                                        else
                                        {
                                            # no PR reference to replace
                                        }

                                        # Filter out dep-update commits produced by this script.
                                        # Squash-merge subjects are the PR title, which is prefixed
                                        # with [no begging], so match the literal [autogenerated]
                                        # marker anywhere in the subject.
                                        if ($commit_subject -eq "Update dependencies" -or
                                            $commit_subject -like "Update deps:*" -or
                                            $commit_subject.Contains("[autogenerated]"))
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
                                    if ($upstream_change.SHA -and
                                        -not $seen_shas.ContainsKey($upstream_change.SHA))
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

# PR title prefix. [autogenerated] lets GitHub auto-approve policies recognize propagation PRs;
# bot-authored -Pipeline PRs also opt out of reviewer reminders with [no begging].
function get-propagation-title-prefix
{
    if (test-pipeline-mode)
    {
        return "[no begging] [autogenerated]"
    }
    else
    {
        return "[autogenerated]"
    }
}

# Build a formatted description from collected upstream changes.
# Returns a hashtable with CommitSubject, CommitBody, PrTitle, PrBody (every upstream commit) and
# PrSummaryBody (commit counts per repo, for platforms whose description limit PrBody exceeds).
function build-propagation-description
{
    param(
        [array] $changes
    )

    $title_prefix = get-propagation-title-prefix
    $result = @{
        CommitSubject = "Update dependencies"
        CommitBody = ""
        PrTitle = "$title_prefix update dependencies"
        PrBody = "Propagating dependency updates"
        PrSummaryBody = "Propagating dependency updates"
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

        # Build PR title - only include repo names, not commit subjects
        $pr_title = "$title_prefix update deps: " + ($repo_names -join ", ")
        if ($pr_title.Length -gt 120)
        {
            $pr_title = $pr_title.Substring(0, 117) + "..."
        }
        else
        {
            # short enough
        }
        $result.PrTitle = $pr_title

        # Detailed body: every upstream commit, grouped by repo.
        $detail_lines = @()
        $detail_lines += "## Dependency Updates"
        $detail_lines += ""
        foreach ($repo in $repo_names)
        {
            $detail_lines += "### $repo"
            foreach ($change in $grouped[$repo])
            {
                $detail_lines += "- ``$($change.SHA)`` $($change.Subject)"
            }
            $detail_lines += ""
        }

        # Concise body: commit counts per repo.
        $summary_lines = @()
        $summary_lines += "## Dependency Updates"
        $summary_lines += ""
        foreach ($repo in $repo_names)
        {
            $commit_count = @($grouped[$repo]).Count
            $commit_word = if ($commit_count -eq 1) { "commit" } else { "commits" }
            $summary_lines += "- **$repo**: $commit_count $commit_word"
        }
        $summary_lines += ""

        # Add links to PRs created by this propagation run
        $link_lines = @()
        if ($global:repo_status)
        {
            $pr_links = @()
            foreach ($r in $global:repo_order_list)
            {
                if ($global:repo_status.ContainsKey($r) -and $global:repo_status[$r].PrUrl)
                {
                    $pr_links += "- [$r]($($global:repo_status[$r].PrUrl))"
                }
                else
                {
                    # no PR for this repo
                }
            }
            if ($pr_links.Count -gt 0)
            {
                $link_lines += "## Related PRs"
                $link_lines += ""
                $link_lines += $pr_links
                $link_lines += ""
            }
            else
            {
                # no PR links to add
            }
        }
        else
        {
            # no repo status available
        }

        $result.PrBody = ($detail_lines + $link_lines) -join "`n"
        $result.PrSummaryBody = ($summary_lines + $link_lines) -join "`n"
    }

    return $result
}

# Pick the most detailed PR body that fits a platform's description limit, truncating the concise
# body only as a last resort.
function select-pr-body
{
    param(
        [hashtable] $description,
        [int] $max_length
    )
    $result = $null

    foreach ($candidate in @($description.PrBody, $description.PrSummaryBody))
    {
        if (-not $result -and $candidate -and $candidate.Length -le $max_length)
        {
            $result = $candidate
        }
        else
        {
            # already chosen, missing, or too long
        }
    }

    if (-not $result)
    {
        $suffix = "`n`n... (truncated)"
        $result = $description.PrSummaryBody.Substring(0, $max_length - $suffix.Length) + $suffix
    }
    else
    {
        # fits without truncation
    }

    return $result
}

# Clone a repo with retries so transient connection resets on large clones (e.g. the curl 56
# "Connection was reset" / "early EOF" seen on Azure-MessagingStore) do not abort the run.
# Removes any partial directory between attempts and fails the run if every attempt fails.
function clone-repo-with-retry
{
    param(
        [string] $repo_url,
        [string] $target_dir,
        [int]    $depth = 0,
        [int]    $max_attempts = 5
    )
    $clone_args = @()
    if ($depth -gt 0)
    {
        # Shallow discovery clone (only .gitmodules is needed); not worth mirroring.
        $clone_args += @('--depth', "$depth")
    }
    else
    {
        # Full clone: share objects from the local mirror cache so repeated clones of the same repo
        # (at top level and as a submodule of many parents) do not re-download it.
        $mirror = ensure-git-mirror -repo_url $repo_url -repo_name (get-name-from-url $repo_url)
        if ($mirror) { $clone_args += @('--reference-if-able', $mirror) }
    }
    $attempt = 1
    while ($attempt -le $max_attempts)
    {
        if (Test-Path $target_dir) { Remove-Item -Recurse -Force $target_dir -ErrorAction SilentlyContinue }
        Write-Host "Cloning $repo_url -> $target_dir (attempt $attempt/$max_attempts)..." -ForegroundColor Cyan
        $exit_code = invoke-git-command -git_args (@('clone') + $clone_args + @($repo_url, $target_dir)) -timeout_sec 600
        if ($exit_code -eq 0 -and (Test-Path (Join-Path $target_dir '.git')))
        {
            return
        }
        Write-Host "Clone failed (exit $exit_code) for $repo_url on attempt $attempt/$max_attempts." -ForegroundColor Yellow
        $attempt++
        if ($attempt -le $max_attempts) { Start-Sleep -Seconds 10 }
    }
    fail-with-status "Failed to clone $repo_url after $max_attempts attempts."
}

# Stage only the submodule paths and pipeline YAML directory this workflow intentionally updates.
function stage-propagation-changes
{
    if (Test-Path ".gitmodules")
    {
        $submodule_lines = git config --file .gitmodules --get-regexp '\.path$'
        foreach ($line in @($submodule_lines))
        {
            $sub_path = ($line -split "\s+", 2)[1]
            if ($sub_path)
            {
                git add -- $sub_path
                if ($LASTEXITCODE -ne 0)
                {
                    fail-with-status "Could not stage submodule path $sub_path."
                }
            }
        }
    }
    if (Test-Path "build")
    {
        git add -- build
        if ($LASTEXITCODE -ne 0)
        {
            fail-with-status "Could not stage updated pipeline files."
        }
    }
}


# update the submodules of the given repo and push changes
# returns a hashtable with HasChanges (a commit was pushed) and Description (propagation description)
function update-local-repo
{
    param (
        [string] $repo_name,
        [string] $new_branch_name
    )
    $result = $null

    if (-not (Test-Path -Path $repo_name))
    {
        fail-with-status "Repository directory '$repo_name' is missing (clone failed). Aborting before git operations corrupt the outer checkout."
    }
    Push-Location $repo_name
    # Command output goes to the console (Out-Host) so this function returns only its result.
    git checkout master | Out-Host
    reset-console-color
    # Unshallow if this is a shallow clone (e.g., from build_graph.ps1 --depth 1)
    $is_shallow = git rev-parse --is-shallow-repository 2>$null
    if ($is_shallow -eq "true")
    {
        Write-Host "  Unshallowing repository..."
        if (-not (invoke-git-with-retry -git_args @('fetch', '--unshallow')))
        {
            # Continuing would push the PR branch from a shallow clone, which is never exercised.
            fail-with-status "Could not unshallow $repo_name."
        }
        else
        {
            # full history available
        }
    }
    else
    {
        # full clone, no unshallowing needed
    }
    if (-not (invoke-git-with-retry -git_args @('pull')))
    {
        # A stale master would base the PR on outdated files, risking conflicts that block it forever.
        fail-with-status "Could not update master of $repo_name."
    }
    # Sometimes git fails to detect updates in submodules
    # Fix is to delete the submodule and reinitializes it
    if (Test-Path "deps\")
    {
        refresh-submodules | Out-Host
    }
    else
    {
        # no deps folder
    }
    update-submodules-with-cache | Out-Host
    # update all submodules to their fixed commits (or latest master as fallback)
    update-submodules-to-fixed-commits | Out-Host
    # Update c-build-tools YAML refs to match new submodule SHA
    update-c-build-tools-yaml-refs | Out-Host
    # create new branch
    git checkout -B $new_branch_name | Out-Host
    if ($LASTEXITCODE -ne 0)
    {
        fail-with-status "Could not create branch $new_branch_name in $repo_name."
    }
    reset-console-color
    # Stage only files this propagation intentionally changes.
    stage-propagation-changes | Out-Host

    # Collect upstream changes and build description
    $upstream_changes = collect-upstream-changes $repo_name

    # If no upstream changes were found but there are staged changes,
    # build a fallback description from the staged diff
    if ((-not $upstream_changes -or $upstream_changes.Count -eq 0))
    {
        $staged_files = git diff --cached --name-only
        if ($staged_files)
        {
            # Initialize as array so += works correctly
            $upstream_changes = @()

            # Identify what changed: submodule updates and/or file changes
            $changed_submodules = @()
            $changed_files = @()
            foreach ($f in $staged_files)
            {
                if ($f -match "^deps/")
                {
                    $sub_name = ($f -replace "^deps/", "").Split("/")[0]
                    if ($sub_name -notin $changed_submodules) { $changed_submodules += $sub_name }
                }
                else
                {
                    $changed_files += $f
                }
            }
            # Build fallback change entries
            foreach ($sub in $changed_submodules)
            {
                $upstream_changes += @{
                    Repo = $sub
                    SHA = ""
                    Subject = "updated to latest"
                }
            }
            foreach ($f in $changed_files)
            {
                $upstream_changes += @{
                    Repo = $repo_name
                    SHA = ""
                    Subject = "updated $f"
                }
            }
        }
        else
        {
            # no staged changes
        }
    }
    else
    {
        # upstream changes found
    }

    $description = build-propagation-description $upstream_changes

    # Store change descriptions for downstream repos to reference
    if (-not $global:repo_change_descriptions)
    {
        $global:repo_change_descriptions = @{}
    }
    $global:repo_change_descriptions[$repo_name] = @($upstream_changes)

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

    # Check if there are actually staged changes before committing
    $has_changes = $false
    $staged_diff = git diff --cached --name-only
    if (-not $staged_diff)
    {
        # nothing to commit
    }
    else
    {
        # The message goes through a file: quoted upstream subjects (e.g. Revert "...") are split
        # into separate arguments by Windows PowerShell's native argument passing.
        $message_file = [System.IO.Path]::GetTempFileName()
        try
        {
            [System.IO.File]::WriteAllText($message_file, $commit_message, (New-Object System.Text.UTF8Encoding $false))
            $commit_result = invoke-git-command -git_args @('commit', '-F', $message_file) -timeout_sec 300
        }
        finally
        {
            Remove-Item -Path $message_file -Force -ErrorAction SilentlyContinue
        }
        if ($commit_result -ne 0)
        {
            fail-with-status "Could not commit dependency updates for $repo_name (git exit code $commit_result)."
        }
        elseif (-not (invoke-git-with-retry -git_args @('push', '-f', 'origin', $new_branch_name) -timeout_sec 600))
        {
            fail-with-status "Could not push branch $new_branch_name for $repo_name."
        }
        else
        {
            $has_changes = $true
        }
    }
    Pop-Location

    $result = @{
        HasChanges = $has_changes
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
