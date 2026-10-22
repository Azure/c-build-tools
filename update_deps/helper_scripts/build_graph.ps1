# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS

Discovers the submodule dependency graph of the root repositories and the order in which they
must be updated.

.DESCRIPTION

build-dependency-graph returns @{ repo_order; repo_urls; repo_edges }:
  - repo_order lists every repo after everything it depends on (bottom-up level order: the deepest
    dependencies first, then alphabetically within a level). A dependency cycle fails the run.
  - repo_urls maps each repo name to its clone URL.
  - repo_edges maps each repo to its direct dependencies within the graph.

Interactive runs reuse known_graph.json when the roots' submodules still match it. Otherwise the graph
is discovered live (BFS over shallow clones), saved to known_graph.json, and a c-build-tools PR with
the update is opened. -Pipeline runs pass -NoKnownGraph: the graph is always discovered live and
known_graph.json is never read or written.

.EXAMPLE

PS> $graph = build-dependency-graph -root_list 'https://msazure.visualstudio.com/DefaultCollection/One/_git/Azure-Messaging-GeoReplication', 'https://msazure.visualstudio.com/DefaultCollection/One/_git/Azure-Messaging-ElasticLog'
PS> $graph.repo_order
c-build-tools
macro-utils-c
c-logging
ctest
c-testrunnerswitcher
umock-c
c-pal
c-util
com-wrapper
sf-c-util
clds
zrpc
Azure-Messaging-Metrics
Azure-MessagingStore
Azure-Messaging-GeoReplication
Azure-Messaging-ElasticLog
#>


# get list of submodule URLs from a given repo URL (the repo must be cloned in the current directory)
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

    return ,$result
}


# Fetch the latest known_graph.json from c-build-tools master and check that the roots' submodules
# still match it. Returns the known graph, or $null if it is unavailable or stale.
function get-validated-known-graph
{
    param(
        [string[]] $root_list,
        $repos_to_ignore
    )
    $path_to_known_graph = Join-Path $PSScriptRoot "..\known_graph.json"

    # Always fetch the latest version from the c-build-tools repo to avoid stale local copies.
    Write-Host "Fetching latest known_graph.json from c-build-tools..." -ForegroundColor Gray
    try
    {
        $raw_url = "https://raw.githubusercontent.com/Azure/c-build-tools/master/update_deps/known_graph.json"
        $known_graph = Invoke-RestMethod -Uri $raw_url -TimeoutSec 60 -ErrorAction Stop
        # Save locally so the auto-update PR can diff against it
        $known_graph | ConvertTo-Json -Depth 3 | Set-Content -Path $path_to_known_graph -Encoding UTF8
        Write-Host "Using known_graph.json from remote (master)" -ForegroundColor Green
    }
    catch
    {
        Write-Host "Could not fetch remote known_graph.json: $_" -ForegroundColor Yellow
        Write-Host "Will discover dependency graph from scratch" -ForegroundColor Yellow
        return $null
    }

    foreach ($root in $root_list)
    {
        $name = get-name-from-url -url $root
        if (-not $known_graph.edges.PSObject.Properties[$name])
        {
            Write-Host "Root '$name' not in known graph, will discover from scratch" -ForegroundColor Yellow
            return $null
        }
        else
        {
            # root is known
        }
    }

    # Validate edges: clone only the root repos (shallow) and check their .gitmodules
    Write-Host "Validating known graph against root repos..." -ForegroundColor Cyan
    foreach ($root in $root_list)
    {
        $repo_name = get-name-from-url -url $root
        if (-not (Test-Path -Path $repo_name))
        {
            Write-Host "Cloning: $repo_name" -ForegroundColor Cyan
            clone-repo-with-retry -repo_url $root -target_dir $repo_name -depth 1
            Write-Host ""
        }
        else
        {
            # already cloned
        }
        $actual_children = @()
        foreach ($sub in (get-submodules $root))
        {
            $sub_name = get-name-from-url -url $sub
            if ($sub_name -in $repos_to_ignore) { continue }
            $actual_children += $sub_name
        }
        $actual_sorted = $actual_children | Sort-Object
        $known_sorted = @($known_graph.edges.$repo_name) | Sort-Object
        if (($actual_sorted -join ",") -ne ($known_sorted -join ","))
        {
            Write-Host "Edge mismatch for '$repo_name': known graph is stale, will recompute" -ForegroundColor Yellow
            return $null
        }
        else
        {
            # edges match for this root
        }
    }

    Write-Host "Known graph validated, using hardcoded dependency order" -ForegroundColor Green
    return $known_graph
}


# Build repo edges and URLs from the known graph, keeping only repos reachable from the roots.
function get-graph-from-known-graph
{
    param(
        [string[]] $root_list,
        $known_graph
    )
    $repo_edges = New-Object -TypeName "System.Collections.Generic.Dictionary[string, System.Collections.ArrayList]"
    $repo_urls = New-Object -TypeName "System.Collections.Generic.Dictionary[string, string]"

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

    return @{ repo_edges = $repo_edges; repo_urls = $repo_urls }
}


# Discover the dependency graph live: BFS with a visited set, cloning each repo once (shallow, only
# the .gitmodules file is needed) and collecting dependency edges.
function discover-dependency-graph
{
    param(
        [string[]] $root_list,
        $repos_to_ignore
    )
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
            clone-repo-with-retry -repo_url $repo_url -target_dir $repo_name -depth 1
            Write-Host ""
        }
        else
        {
            # already cloned
        }

        # get submodules and record edges
        $children = New-Object -TypeName "System.Collections.ArrayList"
        foreach ($submodule in (get-submodules $repo_url))
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

    return @{ repo_edges = $repo_edges; repo_urls = $repo_urls }
}


# Order the repos so each one comes after everything it depends on (no I/O). A repo's level is the
# longest path to it from a root (roots are level 0); repos are listed by descending level, then
# alphabetically. A level can only reach the number of repos through a dependency cycle, which
# could never be propagated, so that fails the run.
function get-repo-update-order
{
    param(
        [string[]] $root_list,
        $repo_edges
    )
    $all_names = New-Object -TypeName "System.Collections.Generic.HashSet[string]"
    foreach ($name in $repo_edges.Keys)
    {
        [void]$all_names.Add($name)
        foreach ($child in $repo_edges[$name])
        {
            [void]$all_names.Add($child)
        }
    }

    $repo_levels = New-Object -TypeName "System.Collections.Generic.Dictionary[string, int]"
    $level_queue = New-Object -TypeName "System.Collections.Queue"

    # seed roots at level 0
    foreach ($root in $root_list)
    {
        $name = get-name-from-url -url $root
        [void]$all_names.Add($name)
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
                    if (($repo_level + 1) -ge $all_names.Count)
                    {
                        fail-with-status "Dependency cycle detected: $child_name depends on itself through its submodules."
                    }
                    else
                    {
                        $repo_levels[$child_name] = $repo_level + 1
                        $level_queue.Enqueue($child_name)
                    }
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

    # convert dictionary to list of (repo_name, level)
    $repo_levels_list = [Linq.Enumerable]::ToList($repo_levels)
    # sort list by descending order of level, then alphabetically for same-level repos
    $repo_levels_list.Sort({
        $level_cmp = $args[1].Value.CompareTo($args[0].Value)
        if ($level_cmp -ne 0) { return $level_cmp }
        return [string]::Compare($args[0].Key, $args[1].Key, [System.StringComparison]::OrdinalIgnoreCase)
    })
    # create list to hold repos in order to be updated
    $repo_order = New-Object -TypeName "System.Collections.ArrayList"
    $repo_levels_list.ForEach({ [void]$repo_order.Add($args[0].Key) })
    return ,$repo_order
}


# Save a newly discovered graph as known_graph.json (edges sorted by update order) and open a
# c-build-tools PR with it. Best effort: failures only warn.
function save-known-graph
{
    param(
        $repo_order,
        $repo_edges,
        $repo_urls
    )
    $path_to_known_graph = Join-Path $PSScriptRoot "..\known_graph.json"

    # Build index from repo name to position in update order for sorting edges
    $order_index = @{}
    for ($i = 0; $i -lt $repo_order.Count; $i++)
    {
        $order_index[$repo_order[$i]] = $i
    }

    # Build edges in reverse update order (roots first, leaves last) with sorted edge lists
    $ordered_edges = [ordered]@{}
    $reverse_order = @($repo_order)
    [Array]::Reverse($reverse_order)
    foreach ($name in $reverse_order)
    {
        if ($repo_edges.ContainsKey($name))
        {
            $sorted_edges = @($repo_edges[$name]) | Sort-Object { $order_index[$_] }
            $ordered_edges[$name] = @($sorted_edges)
        }
        else
        {
            $ordered_edges[$name] = @()
        }
    }

    # Build urls in update order (leaves first) with .git suffix stripped
    $ordered_urls = [ordered]@{}
    foreach ($name in $repo_order)
    {
        if ($repo_urls.ContainsKey($name))
        {
            $url = $repo_urls[$name] -replace '\.git$', ''
            $ordered_urls[$name] = $url
        }
        else
        {
            # no url for this repo
        }
    }

    $new_graph = [ordered]@{
        _comment = "Known dependency graph for update propagation. If any repo's actual edges differ from this, the graph is rebuilt from scratch. Edge lists are in update order (leaves first)."
        edges = $ordered_edges
        urls = $ordered_urls
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
        $saved_location = (Get-Location).Path
        try
        {
            $update_dir = Join-Path $saved_location "known_graph_update"
            if (Test-Path $update_dir) { Remove-Item -Recurse -Force $update_dir }
            New-Item -ItemType Directory -Path $update_dir -Force | Out-Null

            Set-Location $update_dir
            Write-Host "Cloning c-build-tools to create known_graph.json PR..." -ForegroundColor Cyan
            if ((invoke-git-command -git_args @('clone', '--depth', '1', $cbt_url)) -ne 0)
            {
                throw "git clone of $cbt_url failed"
            }
            Set-Location "c-build-tools"

            # Copy the updated known_graph.json into the fresh clone
            Copy-Item $path_to_known_graph -Destination "update_deps\known_graph.json" -Force

            $has_changes = git diff --name-only
            if ($has_changes)
            {
                $branch_name = "update-known-graph-$(Get-Date -Format 'yyyyMMddHHmmss')"
                git checkout -b $branch_name
                git add "update_deps\known_graph.json"
                git commit -m "[autogenerated] update known_graph.json with discovered dependency graph"
                if ((invoke-git-command -git_args @('push', '-u', 'origin', $branch_name)) -ne 0)
                {
                    throw "git push of $branch_name failed"
                }
                $create = Invoke-NativeWithTimeout -File gh -Arguments @('pr', 'create', '--title', '[autogenerated] update known_graph.json', '--body', 'Dependency graph edges changed. This PR updates known_graph.json with the newly discovered graph.', '--base', 'master')
                if ($create.ExitCode -eq 0)
                {
                    Write-Host "PR created to update known_graph.json in c-build-tools" -ForegroundColor Green
                }
                else
                {
                    Write-Host "Warning: Failed to create PR for known_graph.json update: $($create.StdErr)" -ForegroundColor Yellow
                }
            }
            else
            {
                Write-Host "No changes to known_graph.json detected" -ForegroundColor Gray
            }
        }
        catch
        {
            Write-Host "Warning: Could not create PR for known_graph.json: $_" -ForegroundColor Yellow
        }
        finally
        {
            Set-Location $saved_location
        }
    }
    else
    {
        Write-Host "Warning: c-build-tools URL not found, cannot create PR" -ForegroundColor Yellow
    }
}


# Discover the dependency graph of the root repositories and the order in which to update them.
# Returns @{ repo_order; repo_urls; repo_edges }.
function build-dependency-graph
{
    param(
        [string[]] $root_list,
        [switch] $ForceBuildGraph, # ignore known_graph.json and rediscover (then save and PR it)
        [switch] $NoKnownGraph # never read or write known_graph.json (-Pipeline)
    )
    $repos_to_ignore = get-repos-to-ignore

    $known_graph = $null
    if ($NoKnownGraph)
    {
        # always discover the graph live
    }
    elseif ($ForceBuildGraph)
    {
        Write-Host "Force rebuild requested, skipping known graph" -ForegroundColor Yellow
    }
    else
    {
        $known_graph = get-validated-known-graph -root_list $root_list -repos_to_ignore $repos_to_ignore
    }

    if ($known_graph)
    {
        $graph = get-graph-from-known-graph -root_list $root_list -known_graph $known_graph
    }
    else
    {
        $graph = discover-dependency-graph -root_list $root_list -repos_to_ignore $repos_to_ignore
    }

    $repo_order = get-repo-update-order -root_list $root_list -repo_edges $graph.repo_edges

    if (-not $known_graph -and -not $NoKnownGraph)
    {
        save-known-graph -repo_order $repo_order -repo_edges $graph.repo_edges -repo_urls $graph.repo_urls | Out-Host
    }
    else
    {
        # known graph used, or known_graph.json disabled
    }

    return @{
        repo_order = $repo_order
        repo_urls = $graph.repo_urls
        repo_edges = $graph.repo_edges
    }
}
