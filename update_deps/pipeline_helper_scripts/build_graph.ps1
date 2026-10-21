# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS

Given a comma-separated list of repository URLs, discovers their submodule dependency graph and
computes a bottom-up order in which the repos can be updated.

.DESCRIPTION

Discovers the dependency graph live from each repo's .gitmodules via BFS, then orders the repos
so each one comes after everything it depends on. Dot-source this script; it sets $repo_edges
(each repo's direct dependencies within the graph), $repo_order (leaves first, by the length of
the longest dependency chain below each repo) and $repo_urls for the caller.

.PARAMETER root_list

Comma-separated list of URLs for repositories upto which updates must be propagated

.EXAMPLE

PS> . .\build_graph.ps1 -root_list 'https://msazure.visualstudio.com/DefaultCollection/One/_git/Azure-Messaging-GeoReplication','https://msazure.visualstudio.com/DefaultCollection/One/_git/Azure-Messaging-ElasticLog'
PS> $repo_order
azure-messaging-ai-context
c-build-tools
Azure-MessagingStore-AITools
macro-utils-c
c-logging
ctest
c-testrunnerswitcher
umock-c
c-pal
c-util
com-wrapper
clds
sf-c-util
Azure-Messaging-Metrics
zrpc
Azure-Messaging-GeoReplication
Azure-MessagingStore
Azure-Messaging-ElasticLog
#>

param(
    [Parameter(Mandatory=$true)][string[]] $root_list # comma-separated list of URLs for repositories upto which updates must be propagated
)


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


# get list of repos to ignore while building graph from ignores.json
$path_to_ignores = Join-Path $PSScriptRoot "..\ignores.json"
$repos_to_ignore = (Get-Content -Path $path_to_ignores) | ConvertFrom-Json

# Discover the dependency graph: BFS with a visited set, clone each repo once (shallow, only the
# .gitmodules file is needed) and collect dependency edges.
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

    # clone repo if not already present (shallow clone, only .gitmodules is needed)
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

# Phase 2: Order the repos so each one comes after everything it depends on (no I/O). A repo's
# height is the length of the longest dependency chain below it (leaves are 0); sorting by height,
# then name, lists repos roughly in the order they can start. The scheduler itself is greedy
# (update-repos-greedily): a repo starts as soon as its own dependencies are done. Fails the run
# on a dependency cycle, which could never be propagated.
function get-repo-update-order
{
    param(
        $repo_edges
    )
    $heights = New-Object -TypeName "System.Collections.Generic.Dictionary[string, int]"
    $unplaced = New-Object -TypeName "System.Collections.Generic.List[string]"
    foreach ($name in $repo_edges.Keys)
    {
        $unplaced.Add($name)
    }

    while ($unplaced.Count -gt 0)
    {
        $placed_any = $false
        foreach ($name in @($unplaced))
        {
            $deps = @($repo_edges[$name])
            if (@($deps | Where-Object { -not $heights.ContainsKey($_) }).Count -eq 0)
            {
                $height = 0
                foreach ($dep in $deps)
                {
                    $height = [Math]::Max($height, $heights[$dep] + 1)
                }
                $heights[$name] = $height
                [void]$unplaced.Remove($name)
                $placed_any = $true
            }
            else
            {
                # a dependency is not placed yet
            }
        }
        if (-not $placed_any)
        {
            fail-with-status "Dependency cycle among: $($unplaced -join ', ')"
        }
        else
        {
            # progress made
        }
    }

    $heights_list = [Linq.Enumerable]::ToList($heights)
    $heights_list.Sort({
        $height_cmp = $args[0].Value.CompareTo($args[1].Value)
        if ($height_cmp -ne 0) { return $height_cmp }
        return [string]::Compare($args[0].Key, $args[1].Key, [System.StringComparison]::OrdinalIgnoreCase)
    })
    $result = New-Object -TypeName "System.Collections.ArrayList"
    $heights_list.ForEach({ [void]$result.Add($args[0].Key) })
    return ,$result
}

$repo_order = get-repo-update-order -repo_edges $repo_edges
