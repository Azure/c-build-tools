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
    [Parameter(Mandatory=$true)][string[]] $root_list # comma-separated list of URLs for repositories upto which updates must be propagated
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


# dictionary to store mapping from repo name to level in dependency graph
# root repo is level 0 and leaf repo is maximum level
$repo_levels = New-Object -TypeName "System.Collections.Generic.Dictionary[string, int]"
# dictionary to store mapping from repo name to URL
$repo_urls = New-Object -TypeName "System.Collections.Generic.Dictionary[string, string]"
# queue to perform breadth-first search
$queue = New-Object -TypeName "System.Collections.Queue"
# get list of repos to ignore  while building graph from ignores.json
$path_to_ignores = Join-Path $PSScriptRoot "..\ignores.json"
$repos_to_ignore = (Get-Content -Path $path_to_ignores) | ConvertFrom-Json
# counter for progress tracking
$script:repos_processed = 0

# perform breadth-first search on dependency graph
function Build-Graph
{
    # get front of queue
    $repo_url = $queue.Dequeue()
    $repo_name = get-name-from-url -url $repo_url

    # Update progress
    $script:repos_processed++
    Write-Progress -Activity "Building dependency graph" -Status "Processing: $repo_name" -CurrentOperation "Repos discovered: $($repo_levels.Count) | Queue: $($queue.Count)"

    # set repo level to 0 if not seen before
    if(-not $repo_levels.ContainsKey($repo_name))
    {
        $repo_levels[$repo_name] = 0
    }
    else
    {
        # already tracked
    }
    # store repo URL
    if(-not $repo_urls.ContainsKey($repo_name))
    {
        $repo_urls[$repo_name] = $repo_url
    }
    else
    {
        # already stored
    }
    # clone repo if not already present
    if(-not (Test-Path -Path $repo_name))
    {
        # Hide progress bar during clone to avoid output conflicts
        Write-Progress -Activity "Building dependency graph" -Completed
        Write-Host "Cloning: $repo_name" -ForegroundColor Cyan
        git clone $repo_url
        Write-Host ""
    }
    else
    {
        # already cloned
    }
    # $repo_level is the length of the path in the graph from the root to the current repo
    $repo_level = $repo_levels[$repo_name]
    # get list for submodules URLs
    $submodules = get-submodules $repo_url
    # iterate of list of submodules
    foreach($submodule in $submodules)
    {
        $submodule_name = get-name-from-url -url $submodule
        # ignore submodule if it is in $repos_to_ignore
        if ($submodule_name -in $repos_to_ignore)
        {
            continue
        }
        else
        {
            # process this submodule
        }
        # $level is the length of the longest path in the graph from the root to the submodule seen so far
        $level = 0
        [void]$repo_levels.TryGetValue($submodule_name, [ref]$level)
        # update repo level of submodule if path from root to submodule via current repo is longer
        if (($repo_level+1) -gt $level)
        {
            $repo_levels[$submodule_name] = $repo_level+1
        }
        else
        {
            # existing level is sufficient
        }
        # add submodule to queue
        $queue.Enqueue($submodule)
    }
}

# seed queue with given arguments
foreach ($root in $root_list)
{
    $queue.Enqueue($root)
}

# build dependency graph
while ( $queue.Count -ne 0)
{
    Build-Graph
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
Exit 0
