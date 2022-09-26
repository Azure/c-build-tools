# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS

Given the URL to a repository, prints the order in which its submodules should be updated to file order.json

.DESCRIPTION

Performs bottom-up level-order traversal of the dependency graph and prints the order to file order.json

.PARAMETER repo

URL of the repository upto which updates must be propagated.

.INPUTS

None.

.OUTPUTS

Prints order in which repositories must be updated to file order.json

.EXAMPLE

PS> .\build_graph.ps1 https://msazure.visualstudio.com/DefaultCollection/One/_git/Azure-MessagingStore
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
    "clds",
    "sf-c-util",
    "Azure-Messaging-Metrics",
    "zrpc",
    "Azure-MessagingStore"
]
#>

# parse repo URL to extract repo name
# Expected URL format: */<repo_name>[.*]
# Example: https://github.com/Azure/c-build-tools or https://github.com/Azure/c-build-tools.git
function get-name-from-url {
    param (
        [string] $url
   )
   if(!$url.Contains("http"))
   {
        Write-Error("Invalid URL: $url")
        exit -1
   }
   $split_by_slash = $url.Split('/')
   $split_by_dot = $split_by_slash[-1].Split('.') # $split_by_slash[-1] contains [repo_name].git
   return $split_by_dot[0] # $split_by_dot[0] contains [repo_name]
}


# get list of submodule URLs from a given repo URL
function get-submodules {
    param (
        [string] $url
    )
    $name = get-name-from-url $url
    # get raw submodule data, needs to be parsed
    $submodule_data = git config -f $name\.gitmodules --get-regexp url
    # create list for submodule URLs
    $submodules = New-Object -TypeName "System.Collections.ArrayList"
    # return empty list if no submodules
    if (!$submodule_data) {
        return $submodules
    }
    # split raw data to parse
    $submodule_tokens = $submodule_data.Split('')
    # create uri object for base URL
    $base_uri = [System.Uri]::new($url + "/")
    # iterate over tokens
    for($i = 0; $i -lt $submodule_tokens.Length; $i++) {
        # odd tokens contain URLs
        if($i % 2 -ne 0) {
            $submodule_uri = $submodule_tokens[$i]
            # convert relative URLs to absolute
            if(-not $submodule_tokens[$i].StartsWith("http")){
                $submodule_uri = [System.Uri]::new($base_uri, $submodule_tokens[$i]).AbsoluteUri
            }
            # append URL to list
            [void]$submodules.Add($submodule_uri)
        }
    }
    return $submodules
}


# dictionary to store mapping from repo name to level in dependency graph
# root repo is level 0 and leaf repo is maximum level
$repo_levels = New-Object -TypeName "System.Collections.Generic.Dictionary[string, int]"
# queue to perform breadth-first search
$queue = New-Object -TypeName "System.Collections.Queue"
# get list of repos to ignore  while building graph from ignores.json
$path_to_ignores = $PSScriptRoot + "\ignores.json"
$repos_to_ignore = (Get-Content -Path $path_to_ignores) | ConvertFrom-Json
# for spinner animation
$progress = @('|','/','-','\')
$progress_counter = 0

# perform breadth-first search on dependency graph
function Build-Graph {
    # spinner animation
    Write-Host "`b$($progress[$progress_counter++ % $progress.Length])" -NoNewline -ForegroundColor Yellow 
    # get front of queue
    $repo_url = $queue.Dequeue()
    $repo_name = get-name-from-url -url $repo_url
    # set repo level to 0 if not seen before
    if(-not $repo_levels.ContainsKey($repo_name)) {
        $repo_levels[$repo_name] = 0
    }
    # clone repo if not already present
    if(-not (Test-Path -Path $repo_name)) {
        Write-Host "`b" -NoNewline # clear spinner
        git clone $repo_url 
    }
    # $repo_level is the length of the path in the graph from the root to the current repo
    $repo_level = $repo_levels[$repo_name]
    # get list for submodules URLs 
    $submodules = get-submodules $repo_url
    # iterate of list of submodules 
    foreach($submodule in $submodules) {
        $submodule_name = get-name-from-url -url $submodule
        # ignore submodule if it is i $repos_to_ignore
        if ($submodule_name -in $repos_to_ignore) {
            continue
        }
        # $level is the length of the longest path in the graph from the root to the submodule seen so far
        $level = 0
        [void]$repo_levels.TryGetValue($submodule_name, [ref]$level)
        # update repo level of submodule if path from root to submodule via current repo is longer
        if (($repo_level+1) -gt $level) {
            $repo_levels[$submodule_name] = $repo_level+1
        }
        # add submodule to queue
        $queue.Enqueue($submodule)
    }
}


# seed queue with given argument
$queue.Enqueue($args[0])
# build dependency graph
while ( $queue.Count -ne 0) {
    Build-Graph
}
# clear spinner animation
Write-Host "`b"-NoNewLine
# convert dictionary to list of (repo_name, level)
$repo_levels_list = [Linq.Enumerable]::ToList($repo_levels)
# sort list by descending order of level
$repo_levels_list.Sort({$args[1].Value.CompareTo($args[0].Value)})
# create list to hold repos in order to be updated
$repo_order = New-Object -TypeName "System.Collections.ArrayList"
# collect repo names in repo_order
$repo_levels_list.ForEach({$repo_order.Add($args[0].Key)})
Set-Content -Path .\order.json -Value ($repo_order | ConvertTo-Json)
Exit 0
