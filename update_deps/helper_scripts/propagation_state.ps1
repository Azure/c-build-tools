# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Propagation state persistence functions for propagate_updates.ps1
# Handles saving, loading, and restoring propagation state for resume support.

$script:STATE_FILE_NAME = "propagation_state.json"

# Save propagation state to a JSON file in the work directory.
# Called after each repo completes so the run can be resumed.
function save-propagation-state
{
    param(
        [string] $branch_name,
        [string[]] $repo_order,
        $repo_urls,
        [string[]] $root_list,
        [Int32] $azure_work_item
    )

    # Build repo_statuses from the global tracking
    $statuses = @{}
    foreach ($repo in $repo_order)
    {
        if ($global:repo_status.ContainsKey($repo))
        {
            $statuses[$repo] = @{
                Status = $global:repo_status[$repo].Status
                Message = $global:repo_status[$repo].Message
                PrUrl = $global:repo_status[$repo].PrUrl
            }
        }
        else
        {
            # repo not tracked
        }
    }

    $state = @{
        branch_name = $branch_name
        repo_order = $repo_order
        repo_urls = $repo_urls
        fixed_commits = $global:fixed_commits
        repo_statuses = $statuses
        root_list = $root_list
        azure_work_item = $azure_work_item
    }

    $state_path = Join-Path $global:work_dir $script:STATE_FILE_NAME
    $state | ConvertTo-Json -Depth 4 | Set-Content -Path $state_path -Encoding UTF8
}

# Find the most recent propagation state file in the current directory.
# Scans new_deps_* directories for propagation_state.json, returns the newest.
function find-latest-state-file
{
    $result = $null

    $candidates = Get-ChildItem -Directory -Filter "new_deps_*" -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    foreach ($dir in $candidates)
    {
        $state_path = Join-Path $dir.FullName $script:STATE_FILE_NAME
        if (Test-Path $state_path)
        {
            $result = $state_path
            break
        }
        else
        {
            # no state file in this directory
        }
    }

    return $result
}

# Convert a PSObject (from ConvertFrom-Json) to a hashtable.
# ConvertFrom-Json returns PSObjects which don't support hashtable operations.
function convert-psobject-to-hashtable
{
    param(
        $InputObject
    )
    $result = @{}

    if ($InputObject)
    {
        $InputObject.PSObject.Properties | ForEach-Object {
            $result[$_.Name] = $_.Value
        }
    }
    else
    {
        # null input, return empty hashtable
    }

    return $result
}

# Load propagation state from a JSON file.
# Returns a hashtable with all saved state, or $null if loading fails.
function load-propagation-state
{
    param(
        [string] $state_path
    )
    $result = $null

    $json = Get-Content -Path $state_path -Raw -ErrorAction SilentlyContinue
    if (-not $json)
    {
        Write-Host "Failed to read state file: $state_path" -ForegroundColor Red
    }
    else
    {
        $data = $json | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $data)
        {
            Write-Host "Failed to parse state file: $state_path" -ForegroundColor Red
        }
        else
        {
            $fc = convert-psobject-to-hashtable $data.fixed_commits
            $urls = convert-psobject-to-hashtable $data.repo_urls

            # Convert repo_statuses — each value is also a PSObject with Status/Message/PrUrl
            $statuses = @{}
            if ($data.repo_statuses)
            {
                $data.repo_statuses.PSObject.Properties | ForEach-Object {
                    $status_obj = $_.Value
                    $statuses[$_.Name] = @{
                        Status = $status_obj.Status
                        Message = $status_obj.Message
                        PrUrl = $status_obj.PrUrl
                    }
                }
            }
            else
            {
                # no repo statuses in state
            }

            $result = @{
                branch_name = $data.branch_name
                repo_order = @($data.repo_order)
                repo_urls = $urls
                fixed_commits = $fc
                repo_statuses = $statuses
                root_list = @($data.root_list)
                azure_work_item = $data.azure_work_item
            }
        }
    }

    return $result
}

# Restore repo statuses from saved state (for resume).
# Repos that were updated or skipped keep their status.
# Repos that failed or were pending are reset to pending.
function restore-repo-status
{
    param(
        [string[]] $repos,
        [hashtable] $saved_statuses
    )
    $global:repo_order_list = $repos
    $global:repo_status = @{}
    $global:current_repo = ""
    foreach ($repo in $repos)
    {
        if ($saved_statuses.ContainsKey($repo))
        {
            $saved = $saved_statuses[$repo]
            if ($saved.Status -eq $script:STATUS_UPDATED -or $saved.Status -eq $script:STATUS_SKIPPED)
            {
                $global:repo_status[$repo] = @{
                    Status = $saved.Status
                    Message = $saved.Message
                    PrUrl = $saved.PrUrl
                }
            }
            else
            {
                # failed or pending — reset to pending for retry
                $global:repo_status[$repo] = @{
                    Status = $script:STATUS_PENDING
                    Message = ""
                    PrUrl = ""
                }
            }
        }
        else
        {
            # not in saved state — treat as pending
            $global:repo_status[$repo] = @{
                Status = $script:STATUS_PENDING
                Message = ""
                PrUrl = ""
            }
        }
    }
}

# Restore the original working directory.
# Called on both success and failure exit paths.
function restore-original-directory
{
    if ($global:original_dir)
    {
        Set-Location $global:original_dir
    }
    else
    {
        # no original_dir saved
    }
}
