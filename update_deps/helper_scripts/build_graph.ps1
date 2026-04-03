# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS

Given a comma-separeted list of URLs to repositories, prints the order in which its submodules should be updated to file order.json

.DESCRIPTION

Performs bottom-up level-order traversal of the dependency graph and prints the order to file order.json

.PARAMETER root_list

Comma-separated list of URLs for repositories upto which updates must be propagated

.INPUTS

None.

.OUTPUTS

Prints order in which repositories must be updated to file order.json

.EXAMPLE

PS> .\build_graph.ps1 -root_list 'https://msazure.visualstudio.com/DefaultCollection/One/_git/Azure-Messaging-GeoReplication', 'https://msazure.visualstudio.com/DefaultCollection/One/_git/Azure-Messaging-ElasticLog'
PS> Get-Content -Path order.json
[
    "c-build-tools",
    "macro-utils-c",
    "c-logging",
    "ctest",
    "c-testrunnerswitcher",
    "umock-c",
    "c-pal",
    "c-util",
    "com-wrapper",
    "sf-c-util",
    "clds",
    "zrpc",
    "Azure-Messaging-Metrics",
    "Azure-MessagingStore",
    "Azure-Messaging-GeoReplication",
    "Azure-Messaging-ElasticLog"
]
#>

param(
    [Parameter(Mandatory=$true)][string[]] $root_list, # comma-separated list of URLs for repositories upto which updates must be propagated
    [switch]$ForceBuildGraph # force graph rebuild even if known graph matches
)

# Source cache helper
. "$PSScriptRoot\repo_order_cache.ps1"


# parse repo URL to extract repo name
# Expected URL format: */<repo_name>[.*]
# Example: https://github.com/Azure/c-build-tools or https://github.com/Azure/c-build-tools.git
# Exits on failure
function get-name-from-url
{
    param (
        [string] $url
    )
    $result = $null

    if (!$url.Contains("http"))
    {
        Write-Error "Invalid URL: $url"
        exit -1
    }
    else
    {
        $split_by_slash = $url.Split('/')
        $split_by_dot = $split_by_slash[-1].Split('.') # $split_by_slash[-1] contains [repo_name].git
        $result = $split_by_dot[0] # $split_by_dot[0] contains [repo_name]
    }

    return $result
}


# get list of submodule URLs from a given repo URL
function get-submodules
{
    param (
        [string] $url
    )
    $name = get-name-from-url $url
    # get raw submodule data, needs to be parsed
    $submodule_data = git config -f $name\.gitmodules --get-regexp url
    # create list for submodule URLs
    $result = New-Object -TypeName "System.Collections.ArrayList"
    # return empty list if no submodules
    if (!$submodule_data)
    {
        # result is already empty list
    }
    else
    {
        # create uri object for base URL
        $base_uri = [System.Uri]::new($url + "/")
        # git config returns an array of strings when there are multiple results
        # each line is in format: "submodule.deps/name.url <url>"
        if ($submodule_data -is [array])
        {
            $lines = $submodule_data
        }
        else
        {
            $lines = @($submodule_data)
        }
        foreach ($line in $lines)
        {
            # split each line by whitespace to extract URL (second part)
            $parts = $line -split '\s+', 2
            if ($parts.Length -ge 2)
            {
                $submodule_uri = $parts[1]
                # convert relative URLs to absolute
                if (-not $submodule_uri.StartsWith("http"))
                {
                    $submodule_uri = [System.Uri]::new($base_uri, $submodule_uri).AbsoluteUri
                }
                else
                {
                    # already absolute, use as-is
                }
                # append URL to list
                [void]$result.Add($submodule_uri)
            }
            else
            {
                # malformed line, skip
            }
        }
    }

    return $result
}


# Known graph: pre-computed dependency edges and URLs.
# If the actual edges from .gitmodules match the known graph, skip the full BFS discovery.
$path_to_known_graph = Join-Path $PSScriptRoot "..\known_graph.json"
$known_graph = $null
$use_known_graph = $false
$save_new_graph = $false

if (Test-Path $path_to_known_graph)
{
    $known_graph = (Get-Content -Path $path_to_known_graph -Raw) | ConvertFrom-Json
}
else
{
    Write-Host "No known_graph.json found, will discover from scratch" -ForegroundColor Yellow
}

# get list of repos to ignore while building graph from ignores.json
$path_to_ignores = Join-Path $PSScriptRoot "..\ignores.json"
$repos_to_ignore = (Get-Content -Path $path_to_ignores) | ConvertFrom-Json

# Check if the known graph covers all requested roots and validate edges
if ($ForceBuildGraph)
{
    Write-Host "Force rebuild requested, skipping known graph" -ForegroundColor Yellow
}
elseif ($known_graph)
{
    $root_names = $root_list | ForEach-Object { get-name-from-url -url $_ }
    $all_roots_known = $true
    foreach ($name in $root_names)
    {
        if (-not $known_graph.edges.PSObject.Properties[$name])
        {
            Write-Host "Root '$name' not in known graph, will discover from scratch" -ForegroundColor Yellow
            $all_roots_known = $false
            break
        }
        else
        {
            # root is known
        }
    }

    if ($all_roots_known)
    {
        # Validate edges: clone only the root repos (shallow) and check their .gitmodules
        Write-Host "Validating known graph against root repos..." -ForegroundColor Cyan
        $edges_match = $true
        foreach ($root in $root_list)
        {
            $repo_name = get-name-from-url -url $root
            # clone if not already present
            if (-not (Test-Path -Path $repo_name))
            {
                Write-Host "Cloning: $repo_name" -ForegroundColor Cyan
                git clone --depth 1 $root
                Write-Host ""
            }
            else
            {
                # already cloned
            }
            # get actual submodules
            $submodules = get-submodules $root
            $actual_children = @()
            foreach ($sub in $submodules)
            {
                $sub_name = get-name-from-url -url $sub
                if ($sub_name -in $repos_to_ignore) { continue }
                $actual_children += $sub_name
            }
            # compare with known edges
            $known_children = @($known_graph.edges.$repo_name)
            $actual_sorted = $actual_children | Sort-Object
            $known_sorted = $known_children | Sort-Object
            if (($actual_sorted -join ",") -ne ($known_sorted -join ","))
            {
                Write-Host "Edge mismatch for '$repo_name': known graph is stale, will recompute" -ForegroundColor Yellow
                $edges_match = $false
                break
            }
            else
            {
                # edges match for this root
            }
        }

        if ($edges_match)
        {
            Write-Host "Known graph validated, using hardcoded dependency order" -ForegroundColor Green
            $use_known_graph = $true
        }
        else
        {
            # fall through to full discovery
        }
    }
    else
    {
        # fall through to full discovery
    }
}
else
{
    # no known graph, fall through to full discovery
}

if ($use_known_graph)
{
    # Build repo_edges and repo_urls from known graph, filtering to only repos reachable from roots
    $repo_edges = New-Object -TypeName "System.Collections.Generic.Dictionary[string, System.Collections.ArrayList]"
    $repo_urls = New-Object -TypeName "System.Collections.Generic.Dictionary[string, string]"

    # BFS to find all reachable repos from roots using known edges
    $reachable = New-Object -TypeName "System.Collections.Generic.HashSet[string]"
    $bfs_queue = New-Object -TypeName "System.Collections.Queue"
    foreach ($root in $root_list)
    {
        $name = get-name-from-url -url $root
        $bfs_queue.Enqueue($name)
        # prefer root_list URL over known graph URL
        $repo_urls[$name] = $root
    }
    while ($bfs_queue.Count -ne 0)
    {
        $name = $bfs_queue.Dequeue()
        if ($reachable.Contains($name)) { continue }
        [void]$reachable.Add($name)

        if (-not $repo_urls.ContainsKey($name) -and $known_graph.urls.PSObject.Properties[$name])
        {
            $repo_urls[$name] = $known_graph.urls.$name
        }
        else
        {
            # already have URL
        }

        $children = New-Object -TypeName "System.Collections.ArrayList"
        if ($known_graph.edges.PSObject.Properties[$name])
        {
            foreach ($child in $known_graph.edges.$name)
            {
                [void]$children.Add($child)
                $bfs_queue.Enqueue($child)
            }
        }
        else
        {
            # leaf node
        }
        $repo_edges[$name] = $children
    }
}
else
{
    # Full discovery: BFS with visited set, clone each repo once and collect dependency edges
    $repo_edges = New-Object -TypeName "System.Collections.Generic.Dictionary[string, System.Collections.ArrayList]"
    $repo_urls = New-Object -TypeName "System.Collections.Generic.Dictionary[string, string]"
    $visited = New-Object -TypeName "System.Collections.Generic.HashSet[string]"
    $queue = New-Object -TypeName "System.Collections.Queue"

    foreach ($root in $root_list)
    {
        $queue.Enqueue($root)
    }

    while ($queue.Count -ne 0)
    {
        $repo_url = $queue.Dequeue()
        $repo_name = get-name-from-url -url $repo_url

        # skip if already discovered
        if ($visited.Contains($repo_name))
        {
            continue
        }
        else
        {
            # first time seeing this repo
        }
        [void]$visited.Add($repo_name)

        # store repo URL
        if (-not $repo_urls.ContainsKey($repo_name))
        {
            $repo_urls[$repo_name] = $repo_url
        }
        else
        {
            # already stored
        }

        Write-Progress -Activity "Building dependency graph" -Status "Discovering: $repo_name" -CurrentOperation "Repos discovered: $($visited.Count) | Queue: $($queue.Count)"

        # clone repo if not already present (shallow clone - only .gitmodules is needed)
        if (-not (Test-Path -Path $repo_name))
        {
            # Hide progress bar during clone to avoid output conflicts
            Write-Progress -Activity "Building dependency graph" -Completed
            Write-Host "Cloning: $repo_name" -ForegroundColor Cyan
            git clone --depth 1 $repo_url
            Write-Host ""
        }
        else
        {
            # already cloned
        }

        # get submodules and record edges
        $submodules = get-submodules $repo_url
        $children = New-Object -TypeName "System.Collections.ArrayList"
        foreach ($submodule in $submodules)
        {
            $sub_name = get-name-from-url -url $submodule
            # ignore submodule if it is in $repos_to_ignore
            if ($sub_name -in $repos_to_ignore)
            {
                continue
            }
            else
            {
                # process this submodule
            }
            [void]$children.Add($sub_name)
            # store URL for this submodule
            if (-not $repo_urls.ContainsKey($sub_name))
            {
                $repo_urls[$sub_name] = $submodule
            }
            else
            {
                # already stored
            }
            # enqueue for discovery if not yet visited
            if (-not $visited.Contains($sub_name))
            {
                $queue.Enqueue($submodule)
            }
            else
            {
                # already discovered
            }
        }
        $repo_edges[$repo_name] = $children
    }

    # Clear progress bar
    Write-Progress -Activity "Building dependency graph" -Completed

    # Save discovered graph as new known_graph.json for future runs
    # (deferred until after Phase 2 so edges can be sorted by update order)
    $save_new_graph = $true
}

# Phase 2: Compute levels (longest path from roots) using cached edges - no I/O
# dictionary to store mapping from repo name to level in dependency graph
# root repo is level 0 and leaf repo is maximum level
$repo_levels = New-Object -TypeName "System.Collections.Generic.Dictionary[string, int]"
$level_queue = New-Object -TypeName "System.Collections.Queue"

# seed roots at level 0
foreach ($root in $root_list)
{
    $name = get-name-from-url -url $root
    $repo_levels[$name] = 0
    $level_queue.Enqueue($name)
}

while ($level_queue.Count -ne 0)
{
    $repo_name = $level_queue.Dequeue()
    $repo_level = $repo_levels[$repo_name]

    if ($repo_edges.ContainsKey($repo_name))
    {
        foreach ($child_name in $repo_edges[$repo_name])
        {
            # $current_level is the longest path from root to child seen so far
            $current_level = 0
            [void]$repo_levels.TryGetValue($child_name, [ref]$current_level)
            # update level if path via current repo is longer
            if (($repo_level + 1) -gt $current_level)
            {
                $repo_levels[$child_name] = $repo_level + 1
                $level_queue.Enqueue($child_name)
            }
            else
            {
                # existing level is sufficient
            }
        }
    }
    else
    {
        # leaf repo, no children
    }
}

# clear progress bar
Write-Progress -Activity "Building dependency graph" -Completed
# convert dictionary to list of (repo_name, level)
$repo_levels_list = [Linq.Enumerable]::ToList($repo_levels)
# sort list by descending order of level
$repo_levels_list.Sort({$args[1].Value.CompareTo($args[0].Value)})
# create list to hold repos in order to be updated
$repo_order = New-Object -TypeName "System.Collections.ArrayList"
# collect repo names in repo_order
$repo_levels_list.ForEach({$repo_order.Add($args[0].Key)})
# Cache the results
set-cached-repo-order -root_list $root_list -repo_order $repo_order -repo_urls $repo_urls

# Save discovered graph as new known_graph.json (with edges sorted by update order)
if ($save_new_graph)
{
    $new_graph = @{
        _comment = "Known dependency graph for update propagation. If any repo's actual edges differ from this, the graph is rebuilt from scratch. Edge lists are in update order (leaves first)."
        edges = @{}
        urls = @{}
    }
    # Build index from repo name to position in update order for sorting
    $order_index = @{}
    for ($i = 0; $i -lt $repo_order.Count; $i++)
    {
        $order_index[$repo_order[$i]] = $i
    }
    foreach ($entry in $repo_edges.GetEnumerator())
    {
        # Sort this repo's edges by their position in the update order
        $sorted_edges = @($entry.Value) | Sort-Object { $order_index[$_] }
        $new_graph.edges[$entry.Key] = @($sorted_edges)
    }
    foreach ($entry in $repo_urls.GetEnumerator())
    {
        $new_graph.urls[$entry.Key] = $entry.Value
    }
    $new_graph_json = $new_graph | ConvertTo-Json -Depth 3
    $new_graph_json | Set-Content -Path $path_to_known_graph -Encoding UTF8
    Write-Host "Updated known_graph.json with discovered graph ($($repo_edges.Count) repos, edges sorted by update order)" -ForegroundColor Yellow

    # Create a PR to c-build-tools with the updated known_graph.json
    # Clone into a separate folder to avoid touching the user's c-build-tools checkout
    $cbt_url = $null
    if ($repo_urls.ContainsKey("c-build-tools"))
    {
        $cbt_url = $repo_urls["c-build-tools"]
    }
    else
    {
        # c-build-tools not in the graph
    }

    if ($cbt_url)
    {
        try
        {
            $update_dir = Join-Path $PWD "known_graph_update"
            if (Test-Path $update_dir) { Remove-Item -Recurse -Force $update_dir }
            New-Item -ItemType Directory -Path $update_dir -Force | Out-Null

            Push-Location $update_dir
            Write-Host "Cloning c-build-tools to create known_graph.json PR..." -ForegroundColor Cyan
            git clone --depth 1 $cbt_url
            Push-Location "c-build-tools"

            # Copy the updated known_graph.json into the fresh clone
            Copy-Item $path_to_known_graph -Destination "update_deps\known_graph.json" -Force

            $has_changes = git diff --name-only
            if ($has_changes)
            {
                $branch_name = "update-known-graph-$(Get-Date -Format 'yyyyMMddHHmmss')"
                git checkout -b $branch_name
                git add "update_deps\known_graph.json"
                git commit -m "[autogenerated] update known_graph.json with discovered dependency graph"
                git push -u origin $branch_name
                $null = gh pr create --title "[autogenerated] update known_graph.json" --body "Dependency graph edges changed. This PR updates known_graph.json with the newly discovered graph." --base master
                if ($LASTEXITCODE -eq 0)
                {
                    Write-Host "PR created to update known_graph.json in c-build-tools" -ForegroundColor Green
                }
                else
                {
                    Write-Host "Warning: Failed to create PR for known_graph.json update" -ForegroundColor Yellow
                }
            }
            else
            {
                Write-Host "No changes to known_graph.json detected" -ForegroundColor Gray
            }

            Pop-Location # c-build-tools
            Pop-Location # known_graph_update
        }
        catch
        {
            Write-Host "Warning: Could not create PR for known_graph.json: $_" -ForegroundColor Yellow
            # Restore location in case of error
            while ((Get-Location).Path -ne $PWD) { Pop-Location -ErrorAction SilentlyContinue; break }
        }
    }
    else
    {
        Write-Host "Warning: c-build-tools URL not found, cannot create PR" -ForegroundColor Yellow
    }
}
else
{
    # known graph was used, no update needed
}

Exit 0
